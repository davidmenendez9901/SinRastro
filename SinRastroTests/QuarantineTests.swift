import Foundation
import Testing

@Suite("Carpetas de fabricante")
struct VendorFolderTests {
    let fx = Fixture()

    private func identity(_ name: String, _ bundleID: String) -> AppIdentity {
        AppIdentity(bundlePath: "/Applications/\(name).app", bundleID: bundleID, names: [name], version: nil, groupContainers: [])
    }

    @Test func fabricanteSaleDelBundleID() {
        #expect(Matcher.vendor(bundleID: "com.google.android.studio") == "google")
        #expect(Matcher.vendor(bundleID: "com.jetbrains.intellij") == "jetbrains")
        #expect(Matcher.vendor(bundleID: "com.acme") == nil)
        #expect(Matcher.vendor(bundleID: "io.ab.app") == nil)
        #expect(Matcher.vendor(bundleID: nil) == nil)
    }

    @Test func nombreConVersionOSinElFabricanteDelante() {
        let studio = identity("Android Studio", "com.google.android.studio")
        #expect(Matcher.vendorChildMatch("AndroidStudio2026.1", identity: studio, vendor: "google") == .medium)
        #expect(Matcher.vendorChildMatch("Android Studio", identity: studio, vendor: "google") == .medium)
        #expect(Matcher.vendorChildMatch("com.google.android.studio", identity: studio, vendor: "google") == .high)
        #expect(Matcher.vendorChildMatch("AndroidStudioPreview2026.1", identity: studio, vendor: "google") == nil)
        #expect(Matcher.vendorChildMatch("Chrome", identity: studio, vendor: "google") == nil)

        let chrome = identity("Google Chrome", "com.google.Chrome")
        #expect(Matcher.vendorChildMatch("Chrome", identity: chrome, vendor: "google") == .medium)
        #expect(Matcher.vendorChildMatch("Chrome Canary", identity: chrome, vendor: "google") == nil)
        #expect(Matcher.vendorChildMatch("GoogleUpdater", identity: chrome, vendor: "google") == nil)
        #expect(Matcher.vendorChildMatch("DriveFS", identity: chrome, vendor: "google") == nil)

        // Lo que queda al quitar el fabricante no puede ser corto ni genérico.
        let editor = identity("Acme Editor", "com.acme.editor")
        #expect(Matcher.vendorChildMatch("Editor", identity: editor, vendor: "acme") == nil)
    }

    @Test func laPoliticaSoloAbreLaCarpetaDelFabricante() {
        let app = fx.makeApp("Android Studio", bundleID: "com.google.android.studio")
        let policy = fx.policy(app)
        let mine = fx.folder(fx.user("Application Support/Google/AndroidStudio2026.1"))
        let cache = fx.folder(fx.user("Caches/Google/AndroidStudio2026.1"))
        let chrome = fx.folder(fx.user("Application Support/Google/Chrome"))
        let otherVendor = fx.folder(fx.user("Application Support/JetBrains/AndroidStudio2026.1"))
        let tooDeep = fx.folder(fx.user("Application Support/Google/Shared/AndroidStudio2026.1"))
        let wrongCategory = fx.folder(fx.user("Preferences/Google/AndroidStudio2026.1"))
        #expect(policy.evaluate(path: mine, kind: .residue) == .allowed(.medium))
        #expect(policy.evaluate(path: cache, kind: .residue) == .allowed(.medium))
        for path in [chrome, otherVendor, tooDeep, wrongCategory, fx.user("Application Support/Google")] {
            if case .allowed = policy.evaluate(path: path, kind: .residue) {
                Issue.record("No debería permitirse \(path)")
            }
        }
    }

    @Test func elEscaneoEncuentraLoDelFabricanteYRespetaAOtrasApps() {
        let app = fx.makeApp("Android Studio", bundleID: "com.google.android.studio")
        fx.makeApp("Google Chrome", bundleID: "com.google.Chrome")
        let support = fx.folder(fx.user("Application Support/Google/AndroidStudio2026.1"))
        let cache = fx.folder(fx.user("Caches/Google/AndroidStudio2026.1"))
        let logs = fx.folder(fx.user("Logs/Google/AndroidStudio2026.1"))
        let chrome = fx.folder(fx.user("Application Support/Google/Chrome"))
        let scan = fx.scan(app)
        #expect(Set(scan.residues.map(\.path)) == [support, cache, logs])
        #expect(scan.residues.allSatisfy { $0.confidence == .medium })
        #expect(scan.residues.first { $0.path == support }?.category == "Application Support/Google")
        #expect(!scan.omitted.contains { $0.path == chrome })
    }

    @Test func laCarpetaDelFabricanteNoSeDejaVacia() async {
        let app = fx.makeApp("Android Studio", bundleID: "com.google.android.studio")
        let support = fx.folder(fx.user("Application Support/Google/AndroidStudio2026.1"))
        let cache = fx.folder(fx.user("Caches/Google/AndroidStudio2026.1"))
        let systemSupport = fx.folder(fx.sys("Application Support/Google/AndroidStudio2026.1"))
        // En Caches el fabricante tiene más cosas; en Application Support solo el .DS_Store.
        let chromeCache = fx.folder(fx.user("Caches/Google/Chrome"))
        fx.file(fx.user("Application Support/Google/.DS_Store"))
        let scan = fx.scan(app)
        let items = scan.allItems.map {
            Residue(path: $0.path, kind: $0.kind, scope: $0.scope, category: $0.category,
                    confidence: $0.confidence, needsAdmin: $0.scope == .system && $0.kind != .bundle)
        }
        let report = await fx.uninstaller().run(UninstallRequest(scan: scan, items: items, mode: .delete))

        #expect(report.failed.isEmpty)
        for path in [support, cache, systemSupport] { #expect(!fx.exists(path)) }
        #expect(!fx.exists(fx.user("Application Support/Google")))
        #expect(!fx.exists(fx.sys("Application Support/Google")))
        #expect(fx.exists(chromeCache))
        #expect(fx.exists(fx.user("Application Support")) && fx.exists(fx.user("Caches/Google")))
        #expect(report.notes.contains { $0.contains(fx.user("Application Support/Google")) })
        #expect(report.notes.contains { $0.contains(fx.sys("Application Support/Google")) })
        #expect(!report.notes.contains { $0.contains(fx.user("Caches/Google")) })
    }

    @Test func enLaPapeleraSeConservaLaCarpetaDelFabricante() async {
        let app = fx.makeApp("Android Studio", bundleID: "com.google.android.studio")
        let support = fx.folder(fx.user("Application Support/Google/AndroidStudio2026.1"))
        let scan = fx.scan(app)
        let report = await fx.uninstaller().run(UninstallRequest(scan: scan, items: scan.allItems, mode: .trash))
        #expect(report.failed.isEmpty && !fx.exists(support))
        #expect(fx.exists(fx.user("Application Support/Google")))
    }

    @Test func dosCopiasDeLaMismaAppNoSeQuitanDatosEntreSi() {
        let app = fx.makeApp("Android Studio", bundleID: "com.google.android.studio")
        fx.makeApp("Android Studio", bundleID: "com.google.android.studio.dev", in: fx.layout.userApplications)
        let shared = fx.folder(fx.user("Application Support/Google/AndroidStudio2026.1"))
        let scan = fx.scan(app)
        #expect(scan.residues.isEmpty)
        #expect(scan.omitted.map(\.path) == [shared])
    }
}

@Suite("Cuarentena")
struct QuarantineTests {
    let fx = Fixture()

    private func install() -> (app: AppInfo, mine: [String]) {
        let app = fx.makeApp("Notas Pro", bundleID: "com.acme.notas")
        let mine = [
            fx.folder(fx.user("Caches/com.acme.notas")),
            fx.file(fx.user("Preferences/com.acme.notas.plist"), "preferencias"),
            fx.folder(fx.user("Application Support/Acme/Notas Pro")),
            fx.plist(fx.sys("LaunchDaemons/com.acme.notas.daemon.plist"), ["Label": "com.acme.notas.daemon"]),
            fx.folder(fx.sys("Application Support/com.acme.notas")),
        ]
        return (app, mine)
    }

    private func quarantine(_ uninstaller: Uninstaller) -> Quarantine {
        Quarantine(layout: fx.layout, runPrivileged: uninstaller.hooks.runPrivileged)
    }

    @Test func desinstalarGuardaTodoYRestaurarLoDevuelve() async {
        let (app, mine) = install()
        let uninstaller = fx.uninstaller()
        let scan = fx.scan(app)
        let report = await uninstaller.run(UninstallRequest(scan: scan, items: scan.allItems, mode: .quarantine))

        #expect(report.failed.isEmpty)
        #expect(report.results.allSatisfy { $0.outcome == .quarantined })
        for path in mine + [app.path] { #expect(!fx.exists(path), "\(path)") }
        // La carpeta del fabricante se quita vacía y vuelve al restaurar.
        #expect(!fx.exists(fx.user("Application Support/Acme")))

        let quarantine = quarantine(uninstaller)
        let sessions = quarantine.sessions()
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == report.sessionID)
        #expect(sessions.first?.appName == "Notas Pro")
        #expect(Set(sessions.first?.entries.map(\.original) ?? []) == Set(mine + [app.path]))
        #expect(sessions.first?.usesHelper == false)

        let results = await quarantine.restore(sessions[0])
        #expect(results.allSatisfy { $0.outcome == .restored })
        for path in mine + [app.path] { #expect(fx.exists(path), "\(path)") }
        #expect(fx.exists(app.path + "/Contents/Info.plist"))
        let prefs = try? String(contentsOfFile: fx.user("Preferences/com.acme.notas.plist"), encoding: .utf8)
        #expect(prefs == "preferencias")
        #expect(quarantine.sessions().isEmpty)
        #expect(!fx.exists(quarantine.directory(sessions[0].id)))
        // Vuelve a ser una app desinstalable.
        #expect(fx.scan(app).residues.count == mine.count)
    }

    @Test func loDeAdministradorSeGuardaYRestauraConElHelper() async {
        let (app, mine) = install()
        let log = CallLog()
        let packages = FakePackages(["com.acme.notas.pkg": [app.path]])
        let uninstaller = fx.uninstaller(packages: packages, log: log)
        let scan = fx.scan(app, packages: packages)
        let items = scan.allItems.map {
            Residue(path: $0.path, kind: $0.kind, scope: $0.scope, category: $0.category,
                    confidence: $0.confidence, needsAdmin: $0.scope == .system)
        }
        let report = await uninstaller.run(UninstallRequest(scan: scan, items: items, mode: .quarantine))

        #expect(report.failed.isEmpty)
        #expect(log.all.filter { $0 == "helper" }.count == 1)
        // En cuarentena los recibos se conservan: restaurar debe dejarlo todo igual.
        #expect(packages.forgotten.isEmpty)
        for path in mine + [app.path] { #expect(!fx.exists(path), "\(path)") }

        let quarantine = quarantine(uninstaller)
        let session = quarantine.sessions()[0]
        #expect(session.usesHelper)
        #expect(session.entries.filter(\.viaHelper).count == 3)
        #expect(fx.exists(quarantine.directory(session.id) + "/" + QuarantineRootRecord.fileName))

        let results = await quarantine.restore(session)
        #expect(results.count == mine.count + 1)
        #expect(results.allSatisfy { $0.outcome == .restored })
        #expect(log.all.filter { $0 == "helper" }.count == 2)
        for path in mine + [app.path] { #expect(fx.exists(path), "\(path)") }
        #expect(quarantine.sessions().isEmpty)
    }

    @Test func restaurarNoPisaLoQueYaExiste() async {
        let (app, mine) = install()
        let uninstaller = fx.uninstaller()
        let scan = fx.scan(app)
        _ = await uninstaller.run(UninstallRequest(scan: scan, items: scan.allItems, mode: .quarantine))
        // La app se reinstaló y creó preferencias nuevas mientras tanto.
        fx.file(fx.user("Preferences/com.acme.notas.plist"), "nuevas")

        let quarantine = quarantine(uninstaller)
        let results = await quarantine.restore(quarantine.sessions()[0])
        let prefs = results.first { $0.path == fx.user("Preferences/com.acme.notas.plist") }
        #expect(prefs?.outcome == .failed)
        #expect((try? String(contentsOfFile: fx.user("Preferences/com.acme.notas.plist"), encoding: .utf8)) == "nuevas")
        #expect(results.filter { $0.outcome == .restored }.count == mine.count)
        // Lo que no se pudo restaurar sigue guardado.
        let left = quarantine.sessions()
        #expect(left.count == 1)
        #expect(left.first?.entries.map(\.original) == [fx.user("Preferences/com.acme.notas.plist")])
    }

    @Test func eliminarYaYCaducidad() async {
        let (app, _) = install()
        let uninstaller = fx.uninstaller()
        let scan = fx.scan(app)
        _ = await uninstaller.run(UninstallRequest(scan: scan, items: scan.allItems, mode: .quarantine))
        let quarantine = quarantine(uninstaller)
        var session = quarantine.sessions()[0]

        quarantine.purgeExpired()
        #expect(quarantine.sessions().count == 1)

        session.date = Date().addingTimeInterval(-Double(Quarantine.retentionDays + 1) * 86_400)
        quarantine.save(session)
        #expect(quarantine.sessions()[0].isExpired)
        quarantine.purgeExpired()
        #expect(quarantine.sessions().isEmpty)
        #expect(!fx.exists(quarantine.directory(session.id)))
        #expect(!fx.exists(app.path))
    }

    @Test func eliminarYaBorraLaSesion() async {
        let (app, _) = install()
        let uninstaller = fx.uninstaller()
        let scan = fx.scan(app)
        _ = await uninstaller.run(UninstallRequest(scan: scan, items: scan.allItems, mode: .quarantine))
        let quarantine = quarantine(uninstaller)
        let session = quarantine.sessions()[0]
        #expect(await quarantine.purge(session) == nil)
        #expect(quarantine.sessions().isEmpty)
        #expect(!fx.exists(quarantine.directory(session.id)))
    }

    @Test func elHelperNoAceptaSesionesNiRegistrosManipulados() throws {
        let app = fx.makeApp("Notas", bundleID: "com.acme.notas")
        let helper = HelperExecutor(layout: fx.layout, hooks: fx.helperHooks())
        let daemon = fx.plist(fx.sys("LaunchDaemons/com.acme.notas.plist"), ["Label": "com.acme.notas"])

        // Identificador que no es un UUID: no se sale de la cuarentena.
        for id in ["../../../Applications", "", "abc"] {
            let report = helper.run(HelperManifest(
                bundlePath: app.path, mode: .quarantine,
                items: [.init(path: daemon, kind: .residue, slot: 0)], forgetPackages: [], sessionID: id))
            #expect(report.error != nil)
            let purge = helper.run(HelperManifest(
                operation: .purge, bundlePath: "", mode: .quarantine, items: [], forgetPackages: [], sessionID: id))
            #expect(purge.error != nil)
        }
        #expect(fx.exists(daemon) && fx.exists(fx.layout.systemApplications))

        // Registro que intenta sacar un archivo a una zona prohibida o con otro nombre.
        let id = UUID().uuidString
        let session = fx.layout.quarantine + "/" + id
        let payload = fx.file(session + "/s0/evil.plist")
        fx.mkdir(fx.root + "/usr/local")
        let record = QuarantineRootRecord(entries: [
            .init(stored: "s0/evil.plist", original: fx.root + "/usr/local/evil.plist"),
            .init(stored: "s0/evil.plist", original: fx.sys("LaunchDaemons/otro.plist")),
            .init(stored: "s0/../s0/evil.plist", original: fx.sys("LaunchDaemons/evil.plist")),
            .init(stored: "s0/evil.plist", original: fx.root + "/outside/evil.plist"),
        ])
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: session + "/" + QuarantineRootRecord.fileName))
        let report = helper.run(HelperManifest(
            operation: .restore, bundlePath: "", mode: .quarantine, items: [], forgetPackages: [], sessionID: id))
        #expect(report.results.count == 4)
        #expect(report.results.allSatisfy { $0.outcome == .rejected })
        #expect(fx.exists(payload))
        #expect(!fx.exists(fx.root + "/usr/local/evil.plist") && !fx.exists(fx.sys("LaunchDaemons/otro.plist")))
    }
}
