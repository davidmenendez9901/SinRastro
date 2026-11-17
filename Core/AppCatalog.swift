import Foundation

enum AppCatalog {
    /// Apps en /Applications y ~/Applications (un nivel, más subcarpetas que
    /// no sean .app). Las de /System no se listan nunca, ni las protegidas
    /// por SIP, ni SinRastro.
    static func installedApps(layout: FSLayout, excluding ownPath: String? = nil) -> [AppInfo] {
        var apps: [AppInfo] = []
        for root in [layout.systemApplications, layout.userApplications] {
            for entry in children(of: root) {
                if entry.hasSuffix(".app") {
                    if let app = load(entry, ownPath: ownPath) { apps.append(app) }
                } else if isRealDirectory(entry) {
                    for nested in children(of: entry) where nested.hasSuffix(".app") {
                        if let app = load(nested, ownPath: ownPath) { apps.append(app) }
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func children(of directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map { directory + "/" + $0 }
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func load(_ path: String, ownPath: String?) -> AppInfo? {
        var st = stat()
        guard
            path != ownPath,
            lstat(path, &st) == 0,
            (st.st_mode & S_IFMT) == S_IFDIR,
            st.st_flags & PathPolicy.restrictedFlag == 0,
            let identity = AppIdentity.load(bundlePath: path, readEntitlements: false)
        else { return nil }
        return AppInfo(
            path: path,
            name: PathUtil.stem(PathUtil.name(path)),
            names: identity.names,
            bundleID: identity.bundleID,
            version: identity.version
        )
    }
}

enum Privilege {
    /// Borrar esta ruta necesita administrador (estimación; si falla por
    /// permisos durante el borrado, se escala igualmente).
    static func needsAdmin(_ path: String) -> Bool {
        let parent = PathUtil.parent(path)
        if access(parent, W_OK) != 0 { return true }
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        if st.st_uid == getuid() { return false }
        if (st.st_mode & S_IFMT) == S_IFDIR { return access(path, W_OK | X_OK) != 0 }
        var parentStat = stat()
        return stat(parent, &parentStat) == 0 && parentStat.st_mode & S_ISVTX != 0
    }
}

enum DiskUsage {
    static func size(of path: String) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        let url = URL(fileURLWithPath: path)
        var total = Int64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return total }
        for case let child as URL in enumerator {
            total += Int64((try? child.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
