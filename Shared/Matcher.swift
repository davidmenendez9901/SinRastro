import Foundation

enum Confidence: String, Codable, Sendable {
    case high, medium
}

enum Matcher {
    static let minimumNameLength = 4

    static let genericNames: Set<String> = [
        "helper", "update", "updater", "updates", "cache", "caches", "support", "agent",
        "daemon", "launcher", "installer", "plugins", "plugin", "tools", "data", "logs",
        "temp", "common", "shared", "default", "application", "applications", "electron",
        "java", "python", "player", "viewer", "editor", "service", "services", "utilities",
        "mozilla", "google", "microsoft", "adobe", "apple",
    ]

    /// Sufijos que se aceptan tras un bundle id de solo dos componentes.
    private static let knownSuffixes: Set<String> = [
        "plist", "savedstate", "binarycookies", "plist.lockfile",
    ]

    /// `name` es el bundle id, o empieza por él seguido de un punto. Con un id
    /// de dos componentes ("com.acme") solo vale el nombre exacto o una
    /// extensión conocida, para no arrastrar a todo un fabricante.
    static func idMatch(_ name: String, bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        let components = id.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2, components.allSatisfy({ !$0.isEmpty }), id.count >= 6 else {
            return false
        }
        let candidate = name.lowercased()
        if candidate == id { return true }
        guard candidate.hasPrefix(id + ".") else { return false }
        if components.count >= 3 { return true }
        return knownSuffixes.contains(String(candidate.dropFirst(id.count + 1)))
    }

    static func nameMatch(_ candidate: String, names: [String]) -> Bool {
        let lowered = candidate.lowercased()
        guard lowered.count >= minimumNameLength, !genericNames.contains(lowered) else { return false }
        return names.contains { $0.lowercased() == lowered }
    }

    static func vendor(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let components = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3 else { return nil }
        let vendor = components[1].lowercased()
        return vendor.count >= 3 ? vendor : nil
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Elemento dentro de la carpeta del fabricante ("Application Support/Google/…").
    /// Vale el bundle id, o el nombre de la app (con o sin el fabricante delante)
    /// seguido como mucho de un número de versión: "AndroidStudio2026.1", "Chrome".
    static func vendorChildMatch(_ fileName: String, identity: AppIdentity, vendor: String) -> Confidence? {
        if let id = identity.bundleID, idMatch(fileName, bundleID: id) { return .high }
        let compact = fileName.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        let vendorKey = normalized(vendor)
        for name in identity.names {
            let full = normalized(name)
            var candidates = [full]
            if full.hasPrefix(vendorKey), full.count > vendorKey.count {
                candidates.append(String(full.dropFirst(vendorKey.count)))
            }
            for candidate in candidates where candidate.count >= minimumNameLength && !genericNames.contains(candidate) {
                guard compact.hasPrefix(candidate) else { continue }
                if compact.dropFirst(candidate.count).allSatisfy({ $0.isNumber || $0 == "." }) { return .medium }
            }
        }
        return nil
    }

    static func match(fileName: String, rule: LibraryCategory.Rule, identity: AppIdentity) -> Confidence? {
        if rule == .groupContainer {
            return identity.groupContainers.contains(fileName) ? .high : nil
        }
        if let id = identity.bundleID, idMatch(fileName, bundleID: id) { return .high }
        switch rule {
        case .named:
            return nameMatch(fileName, names: identity.names) ? .medium : nil
        case .namedStem:
            return nameMatch(PathUtil.stem(fileName), names: identity.names) ? .medium : nil
        case .standard, .launchd, .groupContainer:
            return nil
        }
    }
}

enum LaunchdPlist {
    static func read(_ path: String) -> [String: Any]? {
        guard
            let data = FileManager.default.contents(atPath: path),
            data.count < 1_000_000,
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

    /// Etiqueta del job, solo si es segura para pasarla a launchctl.
    static func label(at path: String) -> String? {
        guard let label = read(path)?["Label"] as? String, !label.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return label.unicodeScalars.allSatisfy(allowed.contains) ? label : nil
    }

    /// El plist apunta a la app por etiqueta, bundle asociado o ejecutable.
    static func references(_ plist: [String: Any], identity: AppIdentity) -> Bool {
        if let id = identity.bundleID {
            if let label = plist["Label"] as? String, Matcher.idMatch(label, bundleID: id) { return true }
            var associated: [String] = []
            if let single = plist["AssociatedBundleIdentifiers"] as? String { associated = [single] }
            if let many = plist["AssociatedBundleIdentifiers"] as? [String] { associated = many }
            if associated.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) { return true }
        }
        var executables: [String] = []
        if let program = plist["Program"] as? String { executables.append(program) }
        if let first = (plist["ProgramArguments"] as? [String])?.first { executables.append(first) }
        return executables.contains { PathUtil.isInside($0, identity.bundlePath) }
    }
}
