import Foundation

/// Una desinstalación guardada en cuarentena: todo lo que se quitó, con su
/// ruta original, para poder devolverlo a su sitio.
struct QuarantineSession: Codable, Identifiable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var original: String
        /// Ruta relativa dentro de la sesión ("s3/Nombre.app").
        var stored: String
        /// Lo movió el helper root; restaurarlo o borrarlo necesita administrador.
        var viaHelper: Bool
    }

    static let fileName = "session.json"

    var id: String
    var appName: String
    var bundleID: String?
    var date: Date
    var entries: [Entry]

    var usesHelper: Bool { entries.contains(where: \.viaHelper) }
    var expires: Date { date.addingTimeInterval(Double(Quarantine.retentionDays) * 86_400) }
    var isExpired: Bool { expires < Date() }
}

struct Quarantine: Sendable {
    static let retentionDays = 7

    let layout: FSLayout
    let runPrivileged: @Sendable (HelperManifest) async -> HelperReport

    func directory(_ id: String) -> String { layout.quarantine + "/" + id }

    // MARK: - Guardar

    /// Crea la carpeta de una sesión nueva y devuelve su identificador.
    func begin() throws -> String {
        let id = UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: directory(id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return id
    }

    /// Mueve `path` al hueco `slot` de la sesión. Devuelve la ruta relativa.
    func store(_ path: String, session id: String, slot: Int) throws -> String {
        let slotName = "s\(slot)"
        try FileManager.default.createDirectory(atPath: directory(id) + "/" + slotName, withIntermediateDirectories: false)
        try SafeFS.move(path, intoDirectory: directory(id) + "/" + slotName)
        return slotName + "/" + PathUtil.name(path)
    }

    func save(_ session: QuarantineSession) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: URL(fileURLWithPath: directory(session.id) + "/" + QuarantineSession.fileName), options: .atomic)
    }

    /// Descarta una sesión en la que no llegó a guardarse nada.
    func discardEmpty(_ id: String) {
        try? SafeFS.remove(directory(id))
    }

    // MARK: - Consultar

    func sessions() -> [QuarantineSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: layout.quarantine)) ?? []
        return ids.compactMap { id -> QuarantineSession? in
            guard
                UUID(uuidString: id) != nil,
                let data = FileManager.default.contents(atPath: directory(id) + "/" + QuarantineSession.fileName),
                let session = try? decoder.decode(QuarantineSession.self, from: data),
                session.id == id, !session.entries.isEmpty
            else { return nil }
            return session
        }
        .sorted { $0.date > $1.date }
    }

    func size(of session: QuarantineSession) -> Int64 {
        DiskUsage.size(of: directory(session.id))
    }

    // MARK: - Restaurar y vaciar

    /// Devuelve cada elemento a su ruta original. Lo que no se pueda restaurar
    /// se queda en la cuarentena.
    func restore(_ session: QuarantineSession) async -> [ItemResult] {
        var results: [ItemResult] = []
        let base = directory(session.id)
        for entry in session.entries where !entry.viaHelper {
            results.append(restoreAsUser(entry, base: base))
        }
        if session.usesHelper {
            let report = await runPrivileged(HelperManifest(
                operation: .restore, bundlePath: "", mode: .quarantine,
                items: [], forgetPackages: [], sessionID: session.id))
            results += report.results
            let answered = Set(report.results.map(\.path))
            for entry in session.entries where entry.viaHelper && !answered.contains(entry.original) {
                results.append(ItemResult(
                    path: entry.original, outcome: .failed,
                    message: report.error ?? "El helper no respondió sobre esta ruta"))
            }
        }

        let restored = Set(results.filter { $0.outcome == .restored }.map(\.path))
        var remaining = session
        remaining.entries.removeAll { restored.contains($0.original) }
        if remaining.entries.isEmpty {
            _ = await purge(session)
        } else {
            save(remaining)
        }
        return results
    }

    private func restoreAsUser(_ entry: QuarantineSession.Entry, base: String) -> ItemResult {
        let original = entry.original
        let parts = entry.stored.split(separator: "/", omittingEmptySubsequences: false)
        guard
            PathUtil.isStructurallySafe(original), parts.count == 2,
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            String(parts[1]) == PathUtil.name(original)
        else {
            return ItemResult(path: original, outcome: .rejected, message: "Registro de cuarentena no válido")
        }
        var st = stat()
        if lstat(original, &st) == 0 {
            return ItemResult(path: original, outcome: .failed, message: "Ya existe algo en esa ruta")
        }
        do {
            let parent = PathUtil.parent(original)
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try SafeFS.move(base + "/" + entry.stored, intoDirectory: parent)
            return ItemResult(path: original, outcome: .restored)
        } catch {
            return ItemResult(path: original, outcome: .failed, message: "\(error)")
        }
    }

    /// Borra la sesión de forma definitiva. Devuelve el error, si lo hubo.
    func purge(_ session: QuarantineSession) async -> String? {
        do {
            try SafeFS.remove(directory(session.id))
            return nil
        } catch let error as SafeFSError where error.isPermission {
            let report = await runPrivileged(HelperManifest(
                operation: .purge, bundlePath: "", mode: .quarantine,
                items: [], forgetPackages: [], sessionID: session.id))
            return report.error ?? report.results.first { !$0.succeeded }?.message
        } catch {
            return "\(error)"
        }
    }

    /// Vacía lo caducado que no necesita administrador. Lo que sí lo necesita
    /// se queda marcado como caducado, para no pedir la contraseña al abrir.
    func purgeExpired() {
        for session in sessions() where session.isExpired && !session.usesHelper {
            try? SafeFS.remove(directory(session.id))
        }
    }
}
