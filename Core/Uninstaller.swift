import Foundation

struct UninstallHooks: Sendable {
    /// `launchctl bootout gui/<uid>/<label>`.
    var bootoutAgent: @Sendable (String) -> Void
    /// Cierra los procesos del bundle; devuelve avisos de los que no pudo cerrar.
    var terminate: @Sendable (String) async -> [String]
    /// Mueve una ruta del usuario a la Papelera.
    var trash: @Sendable (String) throws -> Void
    /// Ejecuta el helper root una vez con este manifiesto.
    var runPrivileged: @Sendable (HelperManifest) async -> HelperReport
}

struct Uninstaller: Sendable {
    let layout: FSLayout
    let hooks: UninstallHooks

    func run(_ request: UninstallRequest) async -> UninstallReport {
        let scan = request.scan
        var report = UninstallReport(
            appName: scan.app.name, mode: request.mode, date: Date(),
            results: [], forgotten: [], notes: [], sessionID: nil)
        let quarantine = Quarantine(layout: layout, runPrivileged: hooks.runPrivileged)
        var session: String?
        if request.mode == .quarantine {
            do {
                session = try quarantine.begin()
            } catch {
                report.notes.append("No se pudo crear la cuarentena: \(error.localizedDescription)")
                writeLog(report)
                return report
            }
        }

        // La política se vuelve a aplicar justo antes de tocar nada.
        let policy = PathPolicy(layout: layout, identity: scan.identity, packagePaths: scan.packagePaths)
        var valid: [Residue] = []
        for item in request.items {
            switch policy.evaluate(path: item.path, kind: item.kind) {
            case .allowed: valid.append(item)
            case .rejected(let reason):
                report.results.append(ItemResult(path: item.path, outcome: .rejected, message: reason))
            }
        }

        // 1. Agentes fuera, para que no vuelvan a abrir la app.
        for item in valid where item.isLaunchAgent {
            if let label = LaunchdPlist.label(at: item.path) { hooks.bootoutAgent(label) }
        }
        // 2. Procesos.
        report.notes += await hooks.terminate(scan.identity.bundlePath)

        // 3. Lo que el usuario puede borrar por sí mismo.
        let bundle = valid.first { $0.kind == .bundle }
        var privileged: [HelperManifest.Item] = []
        var viaHelper: Set<String> = []
        // Cada elemento tiene su hueco en la cuarentena: su posición en la lista.
        let slots = Dictionary(uniqueKeysWithValues: valid.enumerated().map { ($1.path, $0) })
        func removeAsUser(_ item: Residue) -> ItemResult? {
            do {
                switch request.mode {
                case .delete:
                    try SafeFS.remove(item.path)
                    return ItemResult(path: item.path, outcome: .removed)
                case .trash:
                    try hooks.trash(item.path)
                    return ItemResult(path: item.path, outcome: .trashed)
                case .quarantine:
                    let stored = try quarantine.store(item.path, session: session ?? "", slot: slots[item.path] ?? 0)
                    return ItemResult(path: item.path, outcome: .quarantined, stored: stored)
                }
            } catch let error as SafeFSError where error.isPermission {
                return nil
            } catch let error as CocoaError where error.code == .fileWriteNoPermission {
                return nil
            } catch let error as SafeFSError where error.code == EXDEV {
                return ItemResult(
                    path: item.path, outcome: .failed,
                    message: "Está en otro volumen; usa la eliminación definitiva")
            } catch {
                return ItemResult(path: item.path, outcome: .failed, message: "\(error.localizedDescription)")
            }
        }
        func helperItem(_ item: Residue) -> HelperManifest.Item {
            // Con hueco propio para no chocar con un intento previo del usuario.
            .init(path: item.path, kind: item.kind, slot: (slots[item.path] ?? 0) + valid.count)
        }
        func runHelper(items: [HelperManifest.Item], forget: [String]) async -> HelperReport {
            let manifest = HelperManifest(
                bundlePath: scan.identity.bundlePath, mode: request.mode,
                items: items, forgetPackages: forget, sessionID: session)
            var outcome = await hooks.runPrivileged(manifest)
            let answered = Set(outcome.results.map(\.path))
            for item in items where !answered.contains(item.path) {
                outcome.results.append(ItemResult(
                    path: item.path, outcome: .failed,
                    message: outcome.error ?? "El helper no respondió sobre esta ruta"))
            }
            viaHelper.formUnion(items.map(\.path))
            return outcome
        }

        for item in valid where item.kind != .bundle {
            if item.needsAdmin {
                privileged.append(helperItem(item))
            } else if let result = removeAsUser(item) {
                report.results.append(result)
            } else {
                privileged.append(helperItem(item))
            }
        }

        // 4-5. Una sola ejecución del helper para todo lo que necesita root.
        var bundlePending = bundle
        if let bundle, bundle.needsAdmin {
            privileged.append(helperItem(bundle))
            bundlePending = nil
        }
        let forget = (bundle != nil && request.mode == .delete) ? scan.packageIDs : []
        var authorizationFailed = false
        if !privileged.isEmpty || !forget.isEmpty {
            let outcome = await runHelper(items: privileged, forget: forget)
            report.results += outcome.results
            report.forgotten += outcome.forgotten
            if let error = outcome.error {
                report.notes.append(error)
                authorizationFailed = true
            }
        }

        // 6. El bundle al final. Si la parte de administrador no se hizo, se
        // conserva: sin él ya no se podrían identificar los residuos.
        if let bundle = bundlePending {
            if authorizationFailed {
                report.results.append(ItemResult(
                    path: bundle.path, outcome: .failed,
                    message: "Se conserva porque no se completó la parte de administrador"))
            } else if let result = removeAsUser(bundle) {
                report.results.append(result)
            } else {
                let outcome = await runHelper(items: [helperItem(bundle)], forget: [])
                report.results += outcome.results
                if let error = outcome.error { report.notes.append(error) }
            }
        }

        // 7. Índice de la cuarentena y registro.
        if let session {
            let entries = report.results.compactMap { result -> QuarantineSession.Entry? in
                guard result.outcome == .quarantined, let stored = result.stored else { return nil }
                return .init(original: result.path, stored: stored, viaHelper: viaHelper.contains(result.path))
            }
            if entries.isEmpty {
                quarantine.discardEmpty(session)
            } else {
                quarantine.save(QuarantineSession(
                    id: session, appName: scan.app.name, bundleID: scan.identity.bundleID,
                    date: report.date, entries: entries))
                report.sessionID = session
            }
        }
        writeLog(report)
        return report
    }

    private func writeLog(_ report: UninstallReport) {
        var lines = ["=== \(ISO8601DateFormatter().string(from: report.date)) \(report.appName) [\(report.mode.rawValue)]"]
        for result in report.results {
            lines.append("\(result.outcome.rawValue)\t\(result.path)" + (result.message.map { "\t\($0)" } ?? ""))
        }
        for id in report.forgotten { lines.append("forgotten\t\(id)") }
        for note in report.notes { lines.append("note\t\(note)") }
        let text = lines.joined(separator: "\n") + "\n"
        let directory = PathUtil.parent(layout.logFile)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: layout.logFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            FileManager.default.createFile(atPath: layout.logFile, contents: Data(text.utf8))
        }
    }
}
