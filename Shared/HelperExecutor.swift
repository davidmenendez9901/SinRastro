import Foundation

struct HelperHooks: Sendable {
    var packages: any PackageDatabase
    /// `launchctl bootout system/<label>`.
    var bootoutDaemon: @Sendable (String) -> Void
    /// Cierra los procesos que sigan vivos dentro del bundle.
    var killBundleProcesses: @Sendable (String) -> Void
}

/// Lógica del helper root. No confía en el manifiesto: lee la identidad del
/// bundle, vuelve a aplicar la política a cada ruta y borra sin seguir
/// enlaces simbólicos.
struct HelperExecutor: Sendable {
    let layout: FSLayout
    let hooks: HelperHooks

    func run(_ manifest: HelperManifest) -> HelperReport {
        guard manifest.version == HelperManifest.currentVersion else {
            return HelperReport(error: "Versión de manifiesto no compatible")
        }
        switch manifest.operation {
        case .remove: return remove(manifest)
        case .restore: return restore(manifest)
        case .purge: return purge(manifest)
        }
    }

    // MARK: - Quitar

    private func remove(_ manifest: HelperManifest) -> HelperReport {
        var report = HelperReport()
        guard
            PathUtil.isStructurallySafe(manifest.bundlePath),
            let identity = AppIdentity.load(bundlePath: manifest.bundlePath)
        else {
            report.error = "No se pudo leer el bundle de la app"
            return report
        }
        var policy = PathPolicy(layout: layout, identity: identity)
        if case .rejected(let reason) = policy.evaluate(path: identity.bundlePath, kind: .bundle) {
            report.error = "Bundle no permitido: \(reason)"
            return report
        }

        var session: String?
        if manifest.mode == .quarantine {
            guard let directory = sessionDirectory(manifest.sessionID), sessionIsOwnedByUser(directory) else {
                report.error = "Sesión de cuarentena no válida"
                return report
            }
            session = directory
        }

        let needsAllPackages = manifest.items.contains { $0.kind == .packageFile }
        var packages = PackageMatch()
        if needsAllPackages || !manifest.forgetPackages.isEmpty {
            packages = PackageReceipts.resolve(
                identity: identity,
                database: hooks.packages,
                only: needsAllPackages ? nil : manifest.forgetPackages
            )
            policy.packagePaths = packages.paths
        }

        var allowed: [HelperManifest.Item] = []
        for item in manifest.items {
            switch policy.evaluate(path: item.path, kind: item.kind) {
            case .allowed:
                allowed.append(item)
            case .rejected(let reason):
                report.results.append(ItemResult(path: item.path, outcome: .rejected, message: reason))
            }
        }
        // El bundle siempre al final.
        allowed.sort { ($0.kind == .bundle ? 1 : 0) < ($1.kind == .bundle ? 1 : 0) }

        let daemons = layout.systemLibrary + "/LaunchDaemons"
        for item in allowed where PathUtil.parent(item.path) == daemons {
            if let label = LaunchdPlist.label(at: item.path) { hooks.bootoutDaemon(label) }
        }
        if !allowed.isEmpty { hooks.killBundleProcesses(identity.bundlePath) }

        var record = session.map { readRecord($0) ?? QuarantineRootRecord() }
        for item in allowed {
            do {
                switch manifest.mode {
                case .delete:
                    try SafeFS.remove(item.path)
                    report.results.append(ItemResult(path: item.path, outcome: .removed))
                case .trash:
                    try SafeFS.moveToTrash(item.path, trash: layout.trash, owner: homeOwner)
                    report.results.append(ItemResult(path: item.path, outcome: .trashed))
                case .quarantine:
                    guard let session, let slot = item.slot, (0..<100_000).contains(slot) else {
                        throw SafeFSError(code: EINVAL, path: item.path)
                    }
                    let stored = try store(item.path, session: session, slot: slot)
                    record?.entries.append(.init(stored: stored, original: item.path))
                    report.results.append(ItemResult(path: item.path, outcome: .quarantined, stored: stored))
                }
            } catch {
                report.results.append(ItemResult(path: item.path, outcome: .failed, message: "\(error)"))
            }
        }
        if let session, let record, !record.entries.isEmpty, !writeRecord(record, session: session) {
            report.error = "No se pudo guardar el registro de la cuarentena"
        }

        if manifest.mode == .delete {
            // La carpeta del fabricante, si se quedó vacía.
            for item in allowed {
                if let folder = policy.vendorFolder(of: item.path) { PathPolicy.removeIfEmpty(folder) }
            }
            for id in manifest.forgetPackages where packages.ids.contains(id) {
                if hooks.packages.forget(id) { report.forgotten.append(id) }
            }
        }
        return report
    }

    // MARK: - Cuarentena

    private var homeOwner: uid_t {
        var st = stat()
        return lstat(layout.home, &st) == 0 ? st.st_uid : getuid()
    }

    /// Solo sesiones con nombre de UUID dentro de la cuarentena del usuario.
    private func sessionDirectory(_ id: String?) -> String? {
        guard let id, UUID(uuidString: id) != nil else { return nil }
        return layout.quarantine + "/" + id
    }

    private func sessionIsOwnedByUser(_ directory: String) -> Bool {
        guard let fd = try? SafeFS.openDirectoryNoFollow(directory) else { return false }
        defer { close(fd) }
        var st = stat()
        return fstat(fd, &st) == 0 && st.st_uid == homeOwner
    }

    private func store(_ path: String, session: String, slot: Int) throws -> String {
        let slotName = "s\(slot)"
        let fd = try SafeFS.openDirectoryNoFollow(session)
        let made = mkdirat(fd, slotName, 0o755)
        let code = errno
        close(fd)
        guard made == 0 else { throw SafeFSError(code: code, path: session + "/" + slotName) }
        try SafeFS.move(path, intoDirectory: session + "/" + slotName)
        return slotName + "/" + PathUtil.name(path)
    }

    /// El registro solo vale si es un archivo normal del propio helper: el
    /// usuario puede sustituirlo, pero no crear uno con este dueño.
    private func readRecord(_ session: String) -> QuarantineRootRecord? {
        guard let directory = try? SafeFS.openDirectoryNoFollow(session) else { return nil }
        defer { close(directory) }
        let fd = openat(directory, QuarantineRootRecord.fileName, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard
            fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
            st.st_uid == geteuid(), st.st_size < 4_000_000,
            let data = try? handle.readToEnd()
        else { return nil }
        return try? JSONDecoder().decode(QuarantineRootRecord.self, from: data)
    }

    private func writeRecord(_ record: QuarantineRootRecord, session: String) -> Bool {
        guard
            let data = try? JSONEncoder().encode(record),
            let directory = try? SafeFS.openDirectoryNoFollow(session)
        else { return false }
        defer { close(directory) }
        unlinkat(directory, QuarantineRootRecord.fileName, 0)
        guard record.entries.isEmpty == false else { return true }
        let fd = openat(directory, QuarantineRootRecord.fileName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return (try? handle.write(contentsOf: data)) != nil
    }

    private func restore(_ manifest: HelperManifest) -> HelperReport {
        var report = HelperReport()
        guard
            let session = sessionDirectory(manifest.sessionID), sessionIsOwnedByUser(session),
            let record = readRecord(session)
        else {
            report.error = "No hay nada que el administrador deba restaurar en esta sesión"
            return report
        }
        let denied = PathPolicy.deniedPrefixes(layout: layout)
        let areas = [layout.systemLibrary, layout.systemApplications, layout.home]
        var remaining = QuarantineRootRecord()
        for entry in record.entries {
            let parts = entry.stored.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let original = entry.original
            let valid = parts.count == 2
                && parts[0].hasPrefix("s") && Int(parts[0].dropFirst()) != nil
                && parts[1] == PathUtil.name(original) && parts[1] != "." && parts[1] != ".."
                && PathUtil.isStructurallySafe(original)
                && areas.contains { PathUtil.isInside(original, $0) }
                && !denied.contains { original == $0 || PathUtil.isInside(original, $0) }
            guard valid else {
                report.results.append(ItemResult(path: original, outcome: .rejected, message: "Registro de cuarentena no válido"))
                continue
            }
            do {
                try SafeFS.move(session + "/" + entry.stored, intoDirectory: PathUtil.parent(original))
                report.results.append(ItemResult(path: original, outcome: .restored))
            } catch {
                remaining.entries.append(entry)
                report.results.append(ItemResult(path: original, outcome: .failed, message: "\(error)"))
            }
        }
        _ = writeRecord(remaining, session: session)
        return report
    }

    private func purge(_ manifest: HelperManifest) -> HelperReport {
        var report = HelperReport()
        guard let session = sessionDirectory(manifest.sessionID), sessionIsOwnedByUser(session) else {
            report.error = "Sesión de cuarentena no válida"
            return report
        }
        do {
            try SafeFS.remove(session)
            report.results.append(ItemResult(path: session, outcome: .removed))
        } catch {
            report.results.append(ItemResult(path: session, outcome: .failed, message: "\(error)"))
        }
        return report
    }
}
