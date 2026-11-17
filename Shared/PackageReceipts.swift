import Foundation

protocol PackageDatabase: Sendable {
    func packageIDs() -> [String]
    /// Rutas absolutas (archivos y carpetas) que instaló el paquete.
    func installedPaths(of id: String) -> [String]
    func forget(_ id: String) -> Bool
}

struct LivePackageDatabase: PackageDatabase {
    private static let pkgutil = "/usr/sbin/pkgutil"

    func packageIDs() -> [String] {
        Shell.run(Self.pkgutil, ["--pkgs"]).stdout
            .split(separator: "\n").map(String.init)
    }

    func installedPaths(of id: String) -> [String] {
        let info = Shell.run(Self.pkgutil, ["--pkg-info-plist", id])
        guard
            info.status == 0,
            let plist = try? PropertyListSerialization.propertyList(from: Data(info.stdout.utf8), format: nil) as? [String: Any]
        else { return [] }
        let base = (plist["volume"] as? String ?? "/") + "/" + (plist["install-location"] as? String ?? "")
        let files = Shell.run(Self.pkgutil, ["--files", id])
        guard files.status == 0 else { return [] }
        return files.stdout.split(separator: "\n").map { line in
            let components = (base + "/" + line).split(separator: "/").filter { $0 != "." }
            return "/" + components.joined(separator: "/")
        }
    }

    func forget(_ id: String) -> Bool {
        Shell.run(Self.pkgutil, ["--forget", id]).status == 0
    }
}

struct PackageMatch: Sendable {
    var ids: [String] = []
    var paths: Set<String> = []
}

enum PackageReceipts {
    /// Paquetes que pertenecen a la app: su id coincide con el bundle id, o
    /// instalaron el propio bundle. `only` limita la búsqueda a esos ids.
    static func resolve(identity: AppIdentity, database: any PackageDatabase, only: [String]? = nil) -> PackageMatch {
        var match = PackageMatch()
        let candidates = (only ?? database.packageIDs()).filter { !$0.lowercased().hasPrefix("com.apple.") }
        for id in candidates {
            let paths = database.installedPaths(of: id)
            let byID = identity.bundleID.map { Matcher.idMatch(id, bundleID: $0) } ?? false
            guard byID || paths.contains(identity.bundlePath) else { continue }
            match.ids.append(id)
            match.paths.formUnion(paths)
        }
        return match
    }
}
