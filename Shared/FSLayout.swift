import Foundation

enum Scope: String, Codable, Sendable, CaseIterable {
    case user, system
}

/// Raíces del sistema de archivos. En producción `root` es "" y `home` es el
/// home real. Los tests usan un directorio temporal como raíz. El helper root
/// siempre se construye con `root: ""`; el manifiesto no puede cambiarlo.
struct FSLayout: Sendable, Equatable {
    let root: String
    let home: String

    init(root: String, home: String) {
        self.root = FSLayout.trimmed(root)
        self.home = FSLayout.trimmed(home)
    }

    static func live() -> FSLayout {
        FSLayout(root: "", home: NSHomeDirectory())
    }

    private static func trimmed(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    var isLive: Bool { root.isEmpty }
    var systemLibrary: String { root + "/Library" }
    var userLibrary: String { home + "/Library" }
    var systemApplications: String { root + "/Applications" }
    var userApplications: String { home + "/Applications" }
    var trash: String { home + "/.Trash" }
    /// Cuarentena de SinRastro. ".noindex" evita que Spotlight indexe las apps guardadas.
    var quarantine: String { userLibrary + "/Application Support/SinRastro/Quarantine.noindex" }
    var logFile: String { userLibrary + "/Logs/SinRastro/uninstall.log" }
    var caskrooms: [String] { [root + "/opt/homebrew/Caskroom", root + "/usr/local/Caskroom"] }

    func library(_ scope: Scope) -> String {
        scope == .user ? userLibrary : systemLibrary
    }
}

/// Carpetas de Library donde se buscan residuos.
struct LibraryCategory: Sendable, Hashable {
    enum Rule: Sendable {
        /// Solo coincidencia por bundle id.
        case standard
        /// Bundle id, o nombre exacto de la app.
        case named
        /// Bundle id, o nombre de la app con cualquier extensión.
        case namedStem
        /// Solo los grupos que nombra el entitlement de la app.
        case groupContainer
        /// Plist de launchd: por nombre o por contenido.
        case launchd
    }

    let relativePath: String
    let scopes: [Scope]
    let rule: Rule

    static let all: [LibraryCategory] = [
        .init(relativePath: "Application Support", scopes: [.user, .system], rule: .named),
        .init(relativePath: "Caches", scopes: [.user, .system], rule: .named),
        .init(relativePath: "Logs", scopes: [.user, .system], rule: .named),
        .init(relativePath: "Preferences", scopes: [.user, .system], rule: .standard),
        .init(relativePath: "Preferences/ByHost", scopes: [.user], rule: .standard),
        .init(relativePath: "Saved Application State", scopes: [.user], rule: .standard),
        .init(relativePath: "HTTPStorages", scopes: [.user], rule: .standard),
        .init(relativePath: "WebKit", scopes: [.user], rule: .standard),
        .init(relativePath: "Cookies", scopes: [.user], rule: .standard),
        .init(relativePath: "Containers", scopes: [.user], rule: .standard),
        .init(relativePath: "Group Containers", scopes: [.user], rule: .groupContainer),
        .init(relativePath: "Application Scripts", scopes: [.user], rule: .standard),
        .init(relativePath: "LaunchAgents", scopes: [.user, .system], rule: .launchd),
        .init(relativePath: "LaunchDaemons", scopes: [.system], rule: .launchd),
        .init(relativePath: "PrivilegedHelperTools", scopes: [.system], rule: .standard),
        .init(relativePath: "PreferencePanes", scopes: [.user, .system], rule: .namedStem),
        .init(relativePath: "Internet Plug-Ins", scopes: [.user, .system], rule: .namedStem),
        .init(relativePath: "Input Methods", scopes: [.user, .system], rule: .namedStem),
    ]
}
