import Foundation
import Testing

/// Flujo completo con un bundle falso y un home temporal.
@Suite("Escaneo y desinstalación")
struct FlowTests {
    let fx = Fixture()

    /// Una app con residuos de usuario y de sistema, más una vecina cuyo
    /// identificador empieza igual.
    private func install() -> (app: AppInfo, mine: [String], foreign: [String]) {
        let app = fx.makeApp("Notas Pro", bundleID: "com.acme.notas")
        fx.makeApp("Notas Pro Beta", bundleID: "com.acme.notas.beta")
        fx.makeApp("Otra", bundleID: "com.acme.notas2")
        let mine = [
            fx.folder(fx.user("Caches/com.acme.notas")),
            fx.file(fx.user("Preferences/com.acme.notas.plist")),
            fx.file(fx.user("Preferences/ByHost/com.acme.notas.ABCD-1234.plist")),
            fx.folder(fx.user("Saved Application State/com.acme.notas.savedState")),
            fx.folder(fx.user("Containers/com.acme.notas")),
            fx.folder(fx.user("Application Support/Notas Pro")),
            fx.plist(fx.user("LaunchAgents/com.acme.notas.agent.plist"), ["Label": "com.acme.notas.agent"]),
            fx.plist(fx.sys("LaunchDaemons/com.acme.notas.daemon.plist"), ["Label": "com.acme.notas.daemon"]),
            fx.file(fx.sys("PrivilegedHelperTools/com.acme.notas.helper")),
            fx.folder(fx.sys("Application Support/com.acme.notas")),
        ]
        let foreign = [
            fx.file(fx.user("Preferences/com.acme.notas.beta.plist")),
            fx.file(fx.user("Preferences/com.acme.notas2.plist")),
            fx.folder(fx.user("Caches/com.acme.notas2")),
            fx.folder(fx.user("Application Support/Notas Pro Beta")),
            fx.folder(fx.user("Group Containers/group.com.acme.notas")),
            fx.file(fx.user("Preferences/com.apple.finder.plist")),
            fx.plist(fx.sys("LaunchDaemons/com.otra.plist"), ["Label": "com.otra"]),
        ]
        return (app, mine, foreign)
    }

    @Test func elEscaneoEncuentraSoloLoDeLaApp() {
        let (app, mine, foreign) = install()
        let scan = fx.scan(app)
        let found = Set(scan.residues.map(\.path))
        #expect(found == Set(mine))
        #expect(found.isDisjoint(with: foreign))
        #expect(scan.bundle?.path == app.path)
        // Lo de la versión beta coincide por prefijo, pero se omite con motivo.
        #expect(scan.omitted.map(\.path) == [fx.user("Preferences/com.acme.notas.beta.plist")])
        let support = scan.residues.first { $0.path == fx.user("Application Support/Notas Pro") }
        #expect(support?.confidence == .medium)
        #expect(scan.residues.first { $0.path == fx.sys("Application Support/com.acme.notas") }?.scope == .system)
    }

    @Test func otraCopiaConElMismoNombreOmiteCoincidenciasPorNombre() {
        let app = fx.makeApp("Notas Pro", bundleID: "com.acme.notas")
        fx.makeApp("Notas Pro", bundleID: "com.acme.notas", in: fx.layout.userApplications)
        let byName = fx.folder(fx.user("Application Support/Notas Pro"))
        let scan = fx.scan(app)
        #expect(scan.duplicates == [fx.layout.userApplications + "/Notas Pro.app"])
        #expect(scan.omitted.map(\.path) == [byName])
        #expect(scan.residues.isEmpty)
    }

    @Test func detectaHomebrew() throws {
        let app = fx.makeApp("Notas Pro", bundleID: "com.acme.notas")
        let caskVersion = fx.root + "/opt/homebrew/Caskroom/notas-pro/1.2.3"
        fx.mkdir(caskVersion)
        try FileManager.default.createSymbolicLink(atPath: caskVersion + "/Notas Pro.app", withDestinationPath: app.path)
        #expect(fx.scan(app).homebrewCask == "notas-pro")
    }

    @Test func desinstalarPorCompletoBorraTodoYNadaMas() async {
        let (app, mine, foreign) = install()
        let log = CallLog()
        let scan = fx.scan(app)
        let report = await fx.uninstaller(log: log)
            .run(UninstallRequest(scan: scan, items: scan.allItems, mode: .delete))

        #expect(report.failed.isEmpty)
        #expect(report.succeeded.count == mine.count + 1)
        for path in mine + [app.path] { #expect(!fx.exists(path), "\(path)") }
        for path in foreign { #expect(fx.exists(path), "\(path)") }
        #expect(fx.exists(fx.layout.systemApplications + "/Otra.app"))
        #expect(fx.exists(fx.user("Caches")) && fx.exists(fx.sys("LaunchDaemons")))
        #expect(log.all.contains("agent:com.acme.notas.agent"))
        // El bundle es lo último que se toca.
        #expect(report.results.last?.path == app.path)
        let written = (try? String(contentsOfFile: fx.layout.logFile, encoding: .utf8)) ?? ""
        #expect(written.contains("Notas Pro [delete]"))
        #expect(written.contains("removed\t" + app.path))
    }

    @Test func loDeAdministradorPasaPorElHelperUnaSolaVez() async {
        let (app, mine, _) = install()
        let log = CallLog()
        let packages = FakePackages(["com.acme.notas.pkg": [app.path]])
        let scan = fx.scan(app, packages: packages)
        #expect(scan.packageIDs == ["com.acme.notas.pkg"])
        // En el fixture todo es del usuario; se marca lo de sistema como de administrador.
        let items = scan.allItems.map {
            Residue(path: $0.path, kind: $0.kind, scope: $0.scope, category: $0.category,
                    confidence: $0.confidence, needsAdmin: $0.scope == .system)
        }
        let report = await fx.uninstaller(packages: packages, log: log)
            .run(UninstallRequest(scan: scan, items: items, mode: .delete))

        #expect(report.failed.isEmpty)
        #expect(log.all.filter { $0 == "helper" }.count == 1)
        #expect(log.all.contains("daemon:com.acme.notas.daemon"))
        #expect(report.forgotten == ["com.acme.notas.pkg"])
        #expect(packages.forgotten == ["com.acme.notas.pkg"])
        for path in mine + [app.path] { #expect(!fx.exists(path), "\(path)") }
    }

    @Test func siSeCancelaLaAutorizacionSeConservaElBundle() async {
        let (app, _, _) = install()
        let scan = fx.scan(app)
        let items = scan.allItems.map {
            Residue(path: $0.path, kind: $0.kind, scope: $0.scope, category: $0.category,
                    confidence: $0.confidence, needsAdmin: $0.kind != .bundle && $0.scope == .system)
        }
        var hooks = fx.uninstaller().hooks
        hooks.runPrivileged = { _ in HelperReport(error: "Se canceló la autorización de administrador") }
        let report = await Uninstaller(layout: fx.layout, hooks: hooks)
            .run(UninstallRequest(scan: scan, items: items, mode: .delete))

        #expect(fx.exists(app.path))
        #expect(fx.exists(fx.sys("LaunchDaemons/com.acme.notas.daemon.plist")))
        #expect(!fx.exists(fx.user("Caches/com.acme.notas")))
        #expect(report.failed.contains { $0.path == app.path })
        #expect(report.notes == ["Se canceló la autorización de administrador"])
    }

    @Test func moverALaPapeleraLoDejaRecuperable() async {
        let (app, mine, _) = install()
        let packages = FakePackages(["com.acme.notas.pkg": [app.path]])
        let scan = fx.scan(app, packages: packages)
        let report = await fx.uninstaller(packages: packages)
            .run(UninstallRequest(scan: scan, items: scan.allItems, mode: .trash))

        #expect(report.failed.isEmpty)
        #expect(report.results.allSatisfy { $0.outcome == .trashed })
        for path in mine + [app.path] { #expect(!fx.exists(path)) }
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: fx.layout.trash)) ?? []
        #expect(trashed.count == mine.count + 1)
        #expect(trashed.contains("Notas Pro.app"))
        // Los recibos no se olvidan si todo sigue en la Papelera.
        #expect(packages.forgotten.isEmpty)
    }

    @Test func seRevalidaJustoAntesDeBorrar() async throws {
        let (app, _, _) = install()
        let scan = fx.scan(app)
        // Entre el escaneo y la confirmación, la carpeta pasa a ser un enlace a otro sitio.
        let outside = fx.root + "/outside"
        fx.folder(outside + "/com.acme.notas")
        try FileManager.default.removeItem(atPath: fx.user("Caches"))
        try FileManager.default.createSymbolicLink(atPath: fx.user("Caches"), withDestinationPath: outside)
        let report = await fx.uninstaller().run(UninstallRequest(scan: scan, items: scan.allItems, mode: .delete))
        #expect(fx.exists(outside + "/com.acme.notas/data.bin"))
        #expect(report.results.first { $0.path == fx.user("Caches/com.acme.notas") }?.outcome == .rejected)
    }

    @Test func archivosDeRecibosFueraDeLasCarpetasHabituales() {
        let app = fx.makeApp("Notas Pro", bundleID: "com.acme.notas")
        let framework = fx.folder(fx.sys("Frameworks/Notas Pro.framework"))
        let sparkle = fx.folder(fx.sys("Frameworks/Sparkle.framework"))
        let packages = FakePackages([
            "com.acme.notas.pkg": [app.path, fx.sys("Frameworks"), framework, framework + "/data.bin", sparkle],
            "com.otra.pkg": [fx.sys("Frameworks/Otra.framework")],
            "com.apple.pkg.Core": [app.path],
        ])
        let scan = fx.scan(app, packages: packages)
        #expect(scan.packageIDs == ["com.acme.notas.pkg"])
        #expect(scan.residues.map(\.path) == [framework])
        #expect(scan.residues.first?.kind == .packageFile)
    }
}

@Suite("Helper root")
struct HelperExecutorTests {
    let fx = Fixture()

    private func run(_ manifest: HelperManifest, packages: FakePackages = FakePackages()) -> HelperReport {
        HelperExecutor(layout: fx.layout, hooks: fx.helperHooks(packages: packages)).run(manifest)
    }

    @Test func rechazaRutasQueNoSonDeLaApp() {
        let app = fx.makeApp("Notas", bundleID: "com.acme.notas")
        let other = fx.makeApp("Otra", bundleID: "com.otra.app")
        let mine = fx.folder(fx.sys("Application Support/com.acme.notas"))
        let theirs = fx.folder(fx.sys("Application Support/com.otra.app"))
        let apple = fx.file(fx.sys("Preferences/com.apple.loginwindow.plist"))
        let report = run(HelperManifest(bundlePath: app.path, mode: .delete, items: [
            .init(path: mine, kind: .residue),
            .init(path: theirs, kind: .residue),
            .init(path: apple, kind: .residue),
            .init(path: other.path, kind: .bundle),
            .init(path: fx.layout.systemLibrary, kind: .residue),
            .init(path: fx.sys("Application Support/../../Applications/Otra.app"), kind: .residue),
            .init(path: fx.sys("Frameworks"), kind: .packageFile),
        ], forgetPackages: []))

        #expect(report.error == nil)
        #expect(report.results.filter(\.succeeded).map(\.path) == [mine])
        #expect(report.results.filter { $0.outcome == .rejected }.count == 6)
        #expect(!fx.exists(mine))
        for path in [theirs, apple, other.path, fx.layout.systemLibrary, app.path] { #expect(fx.exists(path)) }
    }

    @Test func laIdentidadSaleDelBundleNoDelManifiesto() {
        // Un manifiesto manipulado que apunta a un bundle fuera de Aplicaciones no hace nada.
        let fake = fx.makeApp("Falsa", bundleID: "com.apple.loginwindow", in: fx.root + "/tmp-attacker")
        let target = fx.file(fx.sys("Preferences/com.apple.loginwindow.plist"))
        let report = run(HelperManifest(
            bundlePath: fake.path, mode: .delete,
            items: [.init(path: target, kind: .residue)], forgetPackages: []))
        #expect(report.error != nil)
        #expect(report.results.isEmpty)
        #expect(fx.exists(target))

        let missing = run(HelperManifest(
            bundlePath: fx.layout.systemApplications + "/NoExiste.app", mode: .delete,
            items: [.init(path: target, kind: .residue)], forgetPackages: []))
        #expect(missing.error != nil)
        #expect(fx.exists(target))
    }

    @Test func soloOlvidaRecibosDeLaApp() {
        let app = fx.makeApp("Notas", bundleID: "com.acme.notas")
        let packages = FakePackages([
            "com.acme.notas.pkg": [app.path],
            "com.otra.pkg": [fx.layout.systemApplications + "/Otra.app"],
        ])
        let report = run(
            HelperManifest(bundlePath: app.path, mode: .delete, items: [],
                           forgetPackages: ["com.acme.notas.pkg", "com.otra.pkg", "com.apple.pkg.Core"]),
            packages: packages)
        #expect(report.forgotten == ["com.acme.notas.pkg"])
        #expect(packages.forgotten == ["com.acme.notas.pkg"])
    }

    @Test func borraElBundleAlFinalYRechazaVersionesDesconocidas() {
        let app = fx.makeApp("Notas", bundleID: "com.acme.notas")
        let daemon = fx.plist(fx.sys("LaunchDaemons/com.acme.notas.plist"), ["Label": "com.acme.notas"])
        var manifest = HelperManifest(bundlePath: app.path, mode: .delete, items: [
            .init(path: app.path, kind: .bundle),
            .init(path: daemon, kind: .residue),
        ], forgetPackages: [])
        manifest.version = 99
        #expect(run(manifest).error != nil)
        #expect(fx.exists(app.path))

        manifest.version = HelperManifest.currentVersion
        let report = run(manifest)
        #expect(report.results.map(\.path) == [daemon, app.path])
        #expect(report.results.allSatisfy { $0.succeeded })
        #expect(!fx.exists(app.path) && !fx.exists(daemon))
    }
}
