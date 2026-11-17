import Foundation

/// Sistema de archivos falso en un directorio temporal: nunca se toca el
/// /Applications ni el home reales.
final class Fixture {
    let root: String
    let layout: FSLayout

    init() {
        let temp = NSTemporaryDirectory() + "sinrastro-tests-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        root = PathUtil.realpath(temp)!
        layout = FSLayout(root: root, home: root + "/Users/tester")
        for directory in [layout.systemApplications, layout.userApplications, layout.trash] {
            mkdir(directory)
        }
        for scope in Scope.allCases {
            for category in LibraryCategory.all {
                mkdir(layout.library(scope) + "/" + category.relativePath)
            }
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func sys(_ relative: String) -> String { layout.systemLibrary + "/" + relative }
    func user(_ relative: String) -> String { layout.userLibrary + "/" + relative }

    func mkdir(_ path: String) {
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "x") -> String {
        mkdir(PathUtil.parent(path))
        FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
        return path
    }

    /// Carpeta con un archivo dentro.
    @discardableResult
    func folder(_ path: String) -> String {
        file(path + "/data.bin")
        return path
    }

    @discardableResult
    func plist(_ path: String, _ dictionary: [String: Any]) -> String {
        mkdir(PathUtil.parent(path))
        let data = try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        FileManager.default.createFile(atPath: path, contents: data)
        return path
    }

    func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    @discardableResult
    func makeApp(_ name: String, bundleID: String, in directory: String? = nil) -> AppInfo {
        let path = (directory ?? layout.systemApplications) + "/" + name + ".app"
        plist(path + "/Contents/Info.plist", [
            "CFBundleName": name,
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": "1.2.3",
        ])
        file(path + "/Contents/MacOS/" + name, "#!/bin/sh\n")
        return AppInfo(path: path, name: name, names: [name], bundleID: bundleID, version: "1.2.3")
    }

    func identity(_ app: AppInfo) -> AppIdentity {
        AppIdentity.load(bundlePath: app.path)!
    }

    func policy(_ app: AppInfo) -> PathPolicy {
        PathPolicy(layout: layout, identity: identity(app))
    }

    func scan(_ app: AppInfo, packages: FakePackages = FakePackages()) -> ScanResult {
        ResidueScanner(layout: layout, packages: packages)
            .scan(app: app, installed: AppCatalog.installedApps(layout: layout))!
    }

    func helperHooks(packages: FakePackages = FakePackages(), log: CallLog = CallLog()) -> HelperHooks {
        HelperHooks(
            packages: packages,
            bootoutDaemon: { log.add("daemon:" + $0) },
            killBundleProcesses: { _ in })
    }

    func uninstaller(packages: FakePackages = FakePackages(), log: CallLog = CallLog()) -> Uninstaller {
        let layout = layout
        let helper = HelperExecutor(layout: layout, hooks: helperHooks(packages: packages, log: log))
        return Uninstaller(layout: layout, hooks: UninstallHooks(
            bootoutAgent: { log.add("agent:" + $0) },
            terminate: { _ in [] },
            trash: { try SafeFS.moveToTrash($0, trash: layout.trash, owner: getuid()) },
            runPrivileged: { manifest in
                log.add("helper")
                return helper.run(manifest)
            }))
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    var all: [String] { lock.withLock { entries } }
}

final class FakePackages: PackageDatabase, @unchecked Sendable {
    private let lock = NSLock()
    private var packages: [String: [String]]
    private var forgottenIDs: [String] = []

    init(_ packages: [String: [String]] = [:]) {
        self.packages = packages
    }

    func packageIDs() -> [String] { lock.withLock { packages.keys.sorted() } }
    func installedPaths(of id: String) -> [String] { lock.withLock { packages[id] ?? [] } }
    func forget(_ id: String) -> Bool {
        lock.withLock { forgottenIDs.append(id) }
        return true
    }

    var forgotten: [String] { lock.withLock { forgottenIDs } }
}
