import Foundation

enum ItemKind: String, Codable, Sendable {
    case bundle, residue, packageFile
}

/// Única fuente de verdad sobre qué se puede borrar. La usan el escaneo, la
/// desinstalación sin privilegios y el helper root.
struct PathPolicy: Sendable {
    enum Verdict: Equatable, Sendable {
        case allowed(Confidence)
        case rejected(String)
    }

    static let restrictedFlag: UInt32 = 0x0008_0000 // SF_RESTRICTED (SIP)

    let layout: FSLayout
    let identity: AppIdentity
    /// Rutas que `pkgutil` registró para los paquetes de esta app.
    var packagePaths: Set<String> = []

    static func deniedPrefixes(layout: FSLayout) -> [String] {
        ["/System", "/usr", "/bin", "/sbin", "/opt", "/private", "/etc", "/var", "/tmp", "/dev", "/cores", "/Volumes"]
            .map { layout.root + $0 }
    }

    private var deniedPrefixes: [String] { PathPolicy.deniedPrefixes(layout: layout) }

    private var protectedExact: Set<String> {
        var set: Set<String> = [
            layout.root.isEmpty ? "/" : layout.root,
            layout.root + "/Users",
            layout.home,
            layout.systemApplications, layout.userApplications,
            layout.systemLibrary, layout.userLibrary,
        ]
        for scope in Scope.allCases {
            for category in LibraryCategory.all {
                set.insert(layout.library(scope) + "/" + category.relativePath)
            }
        }
        return set
    }

    func category(forParent parent: String) -> (LibraryCategory, Scope)? {
        for scope in Scope.allCases {
            let library = layout.library(scope)
            for category in LibraryCategory.all where category.scopes.contains(scope) {
                if parent == library + "/" + category.relativePath { return (category, scope) }
            }
        }
        return nil
    }

    func isApplicationsFolder(_ directory: String) -> Bool {
        let roots = [layout.systemApplications, layout.userApplications]
        if roots.contains(directory) { return true }
        return roots.contains(PathUtil.parent(directory)) && !directory.hasSuffix(".app")
    }

    func evaluate(path: String, kind: ItemKind) -> Verdict {
        guard PathUtil.isStructurallySafe(path) else { return .rejected("Ruta no normalizada") }
        if protectedExact.contains(path) { return .rejected("Carpeta protegida") }
        for prefix in deniedPrefixes where path == prefix || PathUtil.isInside(path, prefix) {
            return .rejected("Zona del sistema")
        }
        var st = stat()
        guard lstat(path, &st) == 0 else { return .rejected("Ya no existe") }
        let parent = PathUtil.parent(path)
        guard PathUtil.realpath(parent) == parent else {
            return .rejected("La carpeta contenedora pasa por un enlace simbólico")
        }
        if st.st_flags & PathPolicy.restrictedFlag != 0 {
            return .rejected("Protegido por el sistema (SIP)")
        }
        let name = PathUtil.name(path)
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        let isRegular = (st.st_mode & S_IFMT) == S_IFREG

        switch kind {
        case .bundle:
            guard path == identity.bundlePath, name.hasSuffix(".app"), isDirectory else {
                return .rejected("No es el bundle de la app")
            }
            guard isApplicationsFolder(parent) else { return .rejected("Fuera de las carpetas de Aplicaciones") }
            return .allowed(.high)

        case .residue:
            guard let (category, _) = category(forParent: parent) else {
                // Un nivel más adentro solo en la carpeta del fabricante de la app.
                if let vendor = identity.vendor,
                   let (outer, _) = self.category(forParent: PathUtil.parent(parent)),
                   outer.rule == .named,
                   PathUtil.name(parent).lowercased() == vendor {
                    guard let confidence = Matcher.vendorChildMatch(name, identity: identity, vendor: vendor) else {
                        return .rejected("El nombre no coincide con la app")
                    }
                    return .allowed(confidence)
                }
                return .rejected("Fuera de las carpetas de Library permitidas")
            }
            if category.rule == .launchd {
                guard isRegular, name.hasSuffix(".plist") else { return .rejected("No es un plist de launchd") }
                if let id = identity.bundleID, Matcher.idMatch(name, bundleID: id) { return .allowed(.high) }
                if let plist = LaunchdPlist.read(path), LaunchdPlist.references(plist, identity: identity) {
                    return .allowed(.high)
                }
                return .rejected("El plist no referencia a la app")
            }
            guard let confidence = Matcher.match(fileName: name, rule: category.rule, identity: identity) else {
                return .rejected("El nombre no coincide con la app")
            }
            return .allowed(confidence)

        case .packageFile:
            guard packagePaths.contains(path) else { return .rejected("No está en los recibos de la app") }
            guard !PathUtil.isInside(path, identity.bundlePath), path != identity.bundlePath else {
                return .rejected("Dentro del bundle")
            }
            let libraries = [layout.systemLibrary, layout.userLibrary]
            guard let library = libraries.first(where: { PathUtil.isInside(path, $0) }) else {
                return .rejected("Fuera de Library")
            }
            let depth = path.dropFirst(library.count + 1).split(separator: "/").count
            guard depth >= 2 else { return .rejected("Carpeta compartida de Library") }
            if let id = identity.bundleID, Matcher.idMatch(name, bundleID: id) { return .allowed(.high) }
            if Matcher.nameMatch(PathUtil.stem(name), names: identity.names) { return .allowed(.high) }
            return .rejected("El nombre no coincide con la app")
        }
    }
}
