import Foundation
import Security

/// Lo que identifica a una app para decidir qué archivos son suyos. Siempre
/// se lee del propio bundle; el helper root no acepta una identidad ajena.
struct AppIdentity: Sendable, Equatable {
    let bundlePath: String
    let bundleID: String?
    let names: [String]
    let version: String?
    let groupContainers: [String]

    /// Fabricante según el bundle id ("com.google.android.studio" → "google").
    var vendor: String? { Matcher.vendor(bundleID: bundleID) }

    static func load(bundlePath: String, readEntitlements: Bool = true) -> AppIdentity? {
        guard
            let data = FileManager.default.contents(atPath: bundlePath + "/Contents/Info.plist"),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        var names: [String] = []
        let fileStem = PathUtil.stem(PathUtil.name(bundlePath))
        for candidate in [info["CFBundleName"] as? String, info["CFBundleDisplayName"] as? String, fileStem] {
            guard let candidate, !candidate.isEmpty else { continue }
            if !names.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                names.append(candidate)
            }
        }
        let bundleID = (info["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AppIdentity(
            bundlePath: bundlePath,
            bundleID: bundleID,
            names: names,
            version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String,
            groupContainers: readEntitlements ? groupContainers(bundlePath: bundlePath) : []
        )
    }

    private static func groupContainers(bundlePath: String) -> [String] {
        var code: SecStaticCode?
        guard
            SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundlePath) as CFURL, [], &code) == errSecSuccess,
            let code
        else { return [] }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard
            SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
            let dict = info as? [String: Any],
            let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
            let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups.filter { !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." }
    }
}
