import Foundation

enum RemovalMode: String, Codable, Sendable {
    /// Borrado definitivo.
    case delete
    /// A la Papelera del usuario.
    case trash
    /// A la cuarentena de SinRastro, restaurable durante unos días.
    case quarantine
}

/// Lo que la app le pide al helper root. Solo lleva rutas: la identidad de la
/// app la lee el helper del bundle y vuelve a aplicar la política.
struct HelperManifest: Codable, Sendable {
    static let currentVersion = 2

    enum Operation: String, Codable, Sendable {
        /// Quitar `items` según `mode`.
        case remove
        /// Devolver a su sitio lo que el helper guardó en la sesión de cuarentena.
        case restore
        /// Borrar la sesión de cuarentena entera.
        case purge
    }

    struct Item: Codable, Sendable, Equatable {
        var path: String
        var kind: ItemKind
        /// Hueco dentro de la sesión de cuarentena ("s<slot>").
        var slot: Int?

        init(path: String, kind: ItemKind, slot: Int? = nil) {
            self.path = path
            self.kind = kind
            self.slot = slot
        }
    }

    var version = HelperManifest.currentVersion
    var operation: Operation
    var bundlePath: String
    var mode: RemovalMode
    var items: [Item]
    var forgetPackages: [String]
    /// Identificador (UUID) de la sesión de cuarentena.
    var sessionID: String?

    init(
        operation: Operation = .remove, bundlePath: String, mode: RemovalMode,
        items: [Item], forgetPackages: [String], sessionID: String? = nil
    ) {
        self.operation = operation
        self.bundlePath = bundlePath
        self.mode = mode
        self.items = items
        self.forgetPackages = forgetPackages
        self.sessionID = sessionID
    }
}

struct ItemResult: Codable, Sendable, Identifiable, Equatable {
    enum Outcome: String, Codable, Sendable {
        case removed, trashed, quarantined, restored, failed, rejected
    }

    var path: String
    var outcome: Outcome
    var message: String?
    /// Ruta dentro de la sesión de cuarentena ("s3/Nombre.app").
    var stored: String?

    var id: String { path }
    var succeeded: Bool { outcome != .failed && outcome != .rejected }
}

struct HelperReport: Codable, Sendable {
    var results: [ItemResult] = []
    var forgotten: [String] = []
    var error: String?
}

/// Lo que el helper guardó en una sesión de cuarentena. Lo escribe él y solo
/// se fía de este archivo si sigue siendo suyo.
struct QuarantineRootRecord: Codable, Sendable {
    static let fileName = "root-record.json"

    struct Entry: Codable, Sendable, Equatable {
        var stored: String
        var original: String
    }

    var entries: [Entry] = []
}
