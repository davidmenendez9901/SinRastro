import Foundation

struct AppInfo: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let names: [String]
    let bundleID: String?
    let version: String?

    var id: String { path }
}

struct Residue: Identifiable, Hashable, Sendable {
    let path: String
    let kind: ItemKind
    let scope: Scope
    /// Carpeta de Library ("Caches", "LaunchAgents"…) o descripción del origen.
    let category: String
    let confidence: Confidence
    let needsAdmin: Bool

    var id: String { path }
    var isLaunchAgent: Bool { kind == .residue && category == "LaunchAgents" }
}

struct OmittedItem: Identifiable, Hashable, Sendable {
    let path: String
    let reason: String

    var id: String { path }
}

struct RunningProcess: Identifiable, Hashable, Sendable {
    let pid: Int32
    let name: String
    let path: String
    let isApp: Bool

    var id: Int32 { pid }
}

struct ScanResult: Sendable {
    let app: AppInfo
    let identity: AppIdentity
    let bundle: Residue?
    let bundleOmittedReason: String?
    let residues: [Residue]
    let omitted: [OmittedItem]
    let processes: [RunningProcess]
    let packageIDs: [String]
    let packagePaths: Set<String>
    /// Carpetas que no se pudieron leer (falta Acceso total al disco).
    let unreadable: [String]
    let homebrewCask: String?
    /// Otras copias instaladas con el mismo bundle id.
    let duplicates: [String]

    var allItems: [Residue] { (bundle.map { [$0] } ?? []) + residues }
}

struct UninstallRequest: Sendable {
    let scan: ScanResult
    let items: [Residue]
    let mode: RemovalMode
}

struct UninstallReport: Sendable, Identifiable {
    let id = UUID()
    let appName: String
    let mode: RemovalMode
    let date: Date
    var results: [ItemResult]
    var forgotten: [String]
    var notes: [String]
    /// Sesión de cuarentena donde quedó guardado, si la hubo.
    var sessionID: String?

    var succeeded: [ItemResult] { results.filter(\.succeeded) }
    var failed: [ItemResult] { results.filter { !$0.succeeded } }
}
