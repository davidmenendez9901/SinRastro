import Foundation

struct ResidueScanner: Sendable {
    let layout: FSLayout
    let packages: any PackageDatabase
    var findProcesses: @Sendable (String) -> [RunningProcess] = { _ in [] }

    func scan(app: AppInfo, installed: [AppInfo]) -> ScanResult? {
        guard let identity = AppIdentity.load(bundlePath: app.path) else { return nil }
        let others = installed.filter { $0.path != app.path }
        let ownID = identity.bundleID?.lowercased()
        let duplicates = others.filter { $0.bundleID != nil && $0.bundleID?.lowercased() == ownID }.map(\.path)
        let otherIDs = others.compactMap { $0.bundleID?.lowercased() }.filter { $0 != ownID }
        let otherNames = Set(others.flatMap(\.names).map { $0.lowercased() })
        let nameClash = identity.names.contains { otherNames.contains($0.lowercased()) }

        let packageMatch = PackageReceipts.resolve(identity: identity, database: packages)
        let policy = PathPolicy(layout: layout, identity: identity, packagePaths: packageMatch.paths)

        let otherIdentities = others.map {
            AppIdentity(bundlePath: $0.path, bundleID: $0.bundleID, names: $0.names, version: nil, groupContainers: [])
        }

        func conflict(name: String, confidence: Confidence) -> String? {
            if confidence == .medium, nameClash { return "Otra app instalada tiene el mismo nombre" }
            if let ownID {
                for other in otherIDs where other.count > ownID.count && Matcher.idMatch(name, bundleID: other) {
                    return "Pertenece a otra app instalada (\(other))"
                }
            }
            return nil
        }

        var residues: [Residue] = []
        var omitted: [OmittedItem] = []
        var unreadable: [String] = []

        for scope in Scope.allCases {
            for category in LibraryCategory.all where category.scopes.contains(scope) {
                let directory = layout.library(scope) + "/" + category.relativePath
                let names: [String]
                do {
                    names = try FileManager.default.contentsOfDirectory(atPath: directory)
                } catch let error as CocoaError where error.code == .fileReadNoPermission {
                    unreadable.append(directory)
                    continue
                } catch {
                    continue
                }
                for name in names.sorted() {
                    let path = directory + "/" + name
                    let nameMatches: Bool
                    if category.rule == .launchd {
                        guard name.hasSuffix(".plist") else { continue }
                        nameMatches = identity.bundleID.map { Matcher.idMatch(name, bundleID: $0) } ?? false
                    } else {
                        guard Matcher.match(fileName: name, rule: category.rule, identity: identity) != nil else { continue }
                        nameMatches = true
                    }
                    switch policy.evaluate(path: path, kind: .residue) {
                    case .allowed(let confidence):
                        if let reason = conflict(name: name, confidence: confidence) {
                            omitted.append(OmittedItem(path: path, reason: reason))
                        } else {
                            residues.append(Residue(
                                path: path, kind: .residue, scope: scope, category: category.relativePath,
                                confidence: confidence, needsAdmin: Privilege.needsAdmin(path)))
                        }
                    case .rejected(let reason):
                        if nameMatches { omitted.append(OmittedItem(path: path, reason: reason)) }
                    }
                }

                // Carpeta del fabricante: "Application Support/Google/AndroidStudio2026.1".
                guard category.rule == .named, let vendor = identity.vendor else { continue }
                for vendorFolder in names where vendorFolder.lowercased() == vendor {
                    let vendorPath = directory + "/" + vendorFolder
                    guard !residues.contains(where: { $0.path == vendorPath }) else { continue }
                    for name in ((try? FileManager.default.contentsOfDirectory(atPath: vendorPath)) ?? []).sorted() {
                        guard Matcher.vendorChildMatch(name, identity: identity, vendor: vendor) != nil else { continue }
                        let path = vendorPath + "/" + name
                        switch policy.evaluate(path: path, kind: .residue) {
                        case .allowed(let confidence):
                            let sharedWith = otherIdentities.first {
                                $0.vendor == vendor && Matcher.vendorChildMatch(name, identity: $0, vendor: vendor) != nil
                            }
                            if let sharedWith {
                                omitted.append(OmittedItem(
                                    path: path,
                                    reason: "También coincide con \(PathUtil.name(sharedWith.bundlePath))"))
                            } else if let reason = conflict(name: name, confidence: confidence) {
                                omitted.append(OmittedItem(path: path, reason: reason))
                            } else {
                                residues.append(Residue(
                                    path: path, kind: .residue, scope: scope,
                                    category: category.relativePath + "/" + vendorFolder,
                                    confidence: confidence, needsAdmin: Privilege.needsAdmin(path)))
                            }
                        case .rejected(let reason):
                            omitted.append(OmittedItem(path: path, reason: reason))
                        }
                    }
                }
            }
        }

        // Archivos de los recibos de pkgutil fuera de las carpetas habituales.
        var accepted = residues.map(\.path)
        for path in packageMatch.paths.sorted() {
            guard !accepted.contains(where: { path == $0 || PathUtil.isInside(path, $0) }) else { continue }
            guard case .allowed(let confidence) = policy.evaluate(path: path, kind: .packageFile) else { continue }
            if let reason = conflict(name: PathUtil.name(path), confidence: confidence) {
                omitted.append(OmittedItem(path: path, reason: reason))
                continue
            }
            let scope: Scope = PathUtil.isInside(path, layout.userLibrary) ? .user : .system
            residues.append(Residue(
                path: path, kind: .packageFile, scope: scope, category: "Recibo de instalación",
                confidence: confidence, needsAdmin: Privilege.needsAdmin(path)))
            accepted.append(path)
        }

        var bundle: Residue?
        var bundleOmitted: String?
        switch policy.evaluate(path: app.path, kind: .bundle) {
        case .allowed:
            bundle = Residue(
                path: app.path, kind: .bundle,
                scope: PathUtil.isInside(app.path, layout.home) ? .user : .system,
                category: "Aplicación", confidence: .high, needsAdmin: Privilege.needsAdmin(app.path))
        case .rejected(let reason):
            bundleOmitted = reason
        }

        return ScanResult(
            app: app,
            identity: identity,
            bundle: bundle,
            bundleOmittedReason: bundleOmitted,
            residues: residues,
            omitted: omitted,
            processes: findProcesses(app.path),
            packageIDs: packageMatch.ids,
            packagePaths: packageMatch.paths,
            unreadable: unreadable,
            homebrewCask: homebrewCask(for: app),
            duplicates: duplicates
        )
    }

    /// Nombre del cask si Homebrew instaló esta app.
    private func homebrewCask(for app: AppInfo) -> String? {
        let fileName = PathUtil.name(app.path)
        let fm = FileManager.default
        for caskroom in layout.caskrooms {
            for cask in (try? fm.contentsOfDirectory(atPath: caskroom)) ?? [] where !cask.hasPrefix(".") {
                for version in (try? fm.contentsOfDirectory(atPath: caskroom + "/" + cask)) ?? [] where !version.hasPrefix(".") {
                    var st = stat()
                    if lstat(caskroom + "/" + cask + "/" + version + "/" + fileName, &st) == 0 { return cask }
                }
            }
        }
        return nil
    }
}
