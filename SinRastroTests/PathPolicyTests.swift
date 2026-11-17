import Foundation
import Testing

private func isAllowed(_ verdict: PathPolicy.Verdict) -> Bool {
    if case .allowed = verdict { return true }
    return false
}

@Suite("Emparejador")
struct MatcherTests {
    @Test func bundleIDExigeFronteraDePunto() {
        let id = "com.acme.notas"
        #expect(Matcher.idMatch("com.acme.notas", bundleID: id))
        #expect(Matcher.idMatch("com.acme.notas.plist", bundleID: id))
        #expect(Matcher.idMatch("com.acme.notas.helper", bundleID: id))
        #expect(Matcher.idMatch("COM.Acme.Notas.savedState", bundleID: id))
        #expect(!Matcher.idMatch("com.acme.notas2", bundleID: id))
        #expect(!Matcher.idMatch("com.acme.notas2.plist", bundleID: id))
        #expect(!Matcher.idMatch("com.acme.notas-beta.plist", bundleID: id))
        #expect(!Matcher.idMatch("com.acme", bundleID: id))
    }

    @Test func idDeDosComponentesNoArrastraAlFabricante() {
        #expect(Matcher.idMatch("com.apple.plist", bundleID: "com.apple"))
        #expect(!Matcher.idMatch("com.apple.Safari.plist", bundleID: "com.apple"))
        #expect(!Matcher.idMatch("com.apple.finder", bundleID: "com.apple"))
        #expect(!Matcher.idMatch("anything", bundleID: "x"))
        #expect(!Matcher.idMatch("a..b", bundleID: "a..b"))
    }

    @Test func nombreExactoLargoYNoGenerico() {
        #expect(Matcher.nameMatch("Notas Pro", names: ["Notas Pro"]))
        #expect(Matcher.nameMatch("notas pro", names: ["Notas Pro"]))
        #expect(!Matcher.nameMatch("Notas Pro 2", names: ["Notas Pro"]))
        #expect(!Matcher.nameMatch("Notas", names: ["Notas Pro"]))
        #expect(!Matcher.nameMatch("Zed", names: ["Zed"]))
        #expect(!Matcher.nameMatch("Helper", names: ["Helper"]))
        #expect(!Matcher.nameMatch("Update", names: ["Update"]))
    }

    @Test func gruposSoloSiLosNombraElEntitlement() {
        let identity = AppIdentity(
            bundlePath: "/Applications/Notas.app", bundleID: "com.acme.notas", names: ["Notas"],
            version: nil, groupContainers: ["TEAM123.com.acme.shared"])
        #expect(Matcher.match(fileName: "TEAM123.com.acme.shared", rule: .groupContainer, identity: identity) == .high)
        #expect(Matcher.match(fileName: "com.acme.notas", rule: .groupContainer, identity: identity) == nil)
        #expect(Matcher.match(fileName: "group.com.acme.notas", rule: .groupContainer, identity: identity) == nil)
    }

    @Test func nombreSoloEnCategoriasQueLoPermiten() {
        let identity = AppIdentity(
            bundlePath: "/Applications/Notas Pro.app", bundleID: "com.acme.notas", names: ["Notas Pro"],
            version: nil, groupContainers: [])
        #expect(Matcher.match(fileName: "Notas Pro", rule: .named, identity: identity) == .medium)
        #expect(Matcher.match(fileName: "Notas Pro", rule: .standard, identity: identity) == nil)
        #expect(Matcher.match(fileName: "Notas Pro.prefPane", rule: .namedStem, identity: identity) == .medium)
        #expect(Matcher.match(fileName: "com.acme.notas", rule: .standard, identity: identity) == .high)
    }
}

@Suite("Política de rutas")
struct PathPolicyTests {
    let fx = Fixture()

    @Test func rechazaRaicesYCarpetasCompartidas() {
        let app = fx.makeApp("Notas", bundleID: "com.acme.notas")
        let policy = fx.policy(app)
        let layout = fx.layout
        let roots = [
            layout.root, layout.home, layout.systemApplications, layout.userApplications,
            layout.systemLibrary, layout.userLibrary,
            fx.user("Caches"), fx.user("Preferences"), fx.sys("LaunchDaemons"), fx.user("Containers"),
        ]
        for path in roots {
            for kind in [ItemKind.bundle, .residue, .packageFile] {
                #expect(!isAllowed(policy.evaluate(path: path, kind: kind)), "\(path) \(kind)")
            }
        }
    }

    @Test func rechazaZonasDelSistema() {
        let app = fx.makeApp("Notas", bundleID: "com.acme.notas")
        var policy = fx.policy(app)
        let paths = ["/System/Library/com.acme.notas", "/usr/local/com.acme.notas", "/bin/com.acme.notas",
                     "/sbin/com.acme.notas", "/opt/homebrew/com.acme.notas", "/private/var/db/com.acme.notas"]
            .map { fx.file(fx.root + $0) }
        policy.packagePaths = Set(paths)
        for path in paths {
            #expect(policy.evaluate(path: path, kind: .residue) == .rejected("Zona del sistema"))
            #expect(policy.evaluate(path: path, kind: .packageFile) == .rejected("Zona del sistema"))
        }
    }

    @Test func rechazaRutasNoNormalizadas() {
        let app = fx.makeApp("Notas", bundleID: "com.acme.notas")
        let policy = fx.policy(app)
        fx.folder(fx.user("Caches/com.acme.notas"))
        let bad = [
            fx.user("Caches/../Caches/com.acme.notas"),
            fx.user("Caches/./com.acme.notas"),
            fx.user("Caches//com.acme.notas"),
            fx.user("Caches/com.acme.notas/"),
            "Library/Caches/com.acme.notas",
            "",
        ]
        for path in bad {
            #expect(policy.evaluate(path: path, kind: .residue) == .rejected("Ruta no normalizada"), "\(path)")
        }
        #expect(isAllowed(policy.evaluate(path: fx.user("Caches/com.acme.notas"), kind: .residue)))
    }

    @Test func rechazaContenedorQuePasaPorSymlink() throws {
        let app = fx.makeApp("Notas", bundleID: "com.acme.notas")
        let policy = fx.policy(app)
        // ~/Library/Logs es un enlace a otra carpeta que contiene algo con el nombre correcto.
        let outside = fx.root + "/outside"
        fx.folder(outside + "/com.acme.notas")
        try FileManager.default.removeItem(atPath: fx.user("Logs"))
        try FileManager.default.createSymbolicLink(atPath: fx.user("Logs"), withDestinationPath: outside)
        let verdict = policy.evaluate(path: fx.user("Logs/com.acme.notas"), kind: .residue)
        #expect(verdict == .rejected("La carpeta contenedora pasa por un enlace simbólico"))
    }

    @Test func soloAceptaLoQueCoincideConLaApp() {
        let app = fx.makeApp("Notas Pro", bundleID: "com.acme.notas")
        let policy = fx.policy(app)
        #expect(policy.evaluate(path: fx.folder(fx.user("Caches/com.acme.notas")), kind: .residue) == .allowed(.high))
        #expect(policy.evaluate(path: fx.file(fx.user("Preferences/com.acme.notas.plist")), kind: .residue) == .allowed(.high))
        #expect(policy.evaluate(path: fx.folder(fx.user("Application Support/Notas Pro")), kind: .residue) == .allowed(.medium))
        #expect(!isAllowed(policy.evaluate(path: fx.file(fx.user("Preferences/com.acme.notas2.plist")), kind: .residue)))
        #expect(!isAllowed(policy.evaluate(path: fx.folder(fx.user("Caches/com.otra.app")), kind: .residue)))
        #expect(!isAllowed(policy.evaluate(path: fx.folder(fx.user("Preferences/Notas Pro")), kind: .residue)))
        // Coincide el nombre pero no está en una carpeta de Library permitida.
        #expect(!isAllowed(policy.evaluate(path: fx.folder(fx.user("Mail/com.acme.notas")), kind: .residue)))
        #expect(!isAllowed(policy.evaluate(path: fx.folder(fx.layout.home + "/Documents/com.acme.notas"), kind: .residue)))
        // Dentro de un residuo válido no se aceptan rutas sueltas.
        #expect(!isAllowed(policy.evaluate(path: fx.user("Caches/com.acme.notas/data.bin"), kind: .residue)))
    }

    @Test func bundleSoloElDeLaAppYEnAplicaciones() {
        let app = fx.makeApp("Notas", bundleID: "com.acme.notas")
        let other = fx.makeApp("Otra", bundleID: "com.acme.otra")
        let nested = fx.makeApp("Suite", bundleID: "com.acme.suite", in: fx.layout.systemApplications + "/Acme")
        let stray = fx.makeApp("Fuera", bundleID: "com.acme.fuera", in: fx.layout.home + "/Desktop")
        #expect(fx.policy(app).evaluate(path: app.path, kind: .bundle) == .allowed(.high))
        #expect(!isAllowed(fx.policy(app).evaluate(path: other.path, kind: .bundle)))
        #expect(fx.policy(nested).evaluate(path: nested.path, kind: .bundle) == .allowed(.high))
        #expect(!isAllowed(fx.policy(stray).evaluate(path: stray.path, kind: .bundle)))
    }

    @Test func plistDeLaunchdPorNombreOContenido() {
        let app = fx.makeApp("Notas", bundleID: "com.acme.notas")
        let policy = fx.policy(app)
        let byName = fx.plist(fx.user("LaunchAgents/com.acme.notas.agent.plist"), ["Label": "x"])
        let byLabel = fx.plist(fx.sys("LaunchDaemons/raro.plist"), ["Label": "com.acme.notas.daemon"])
        let byProgram = fx.plist(fx.sys("LaunchAgents/updater.plist"), [
            "Label": "updater", "ProgramArguments": [app.path + "/Contents/MacOS/Notas", "--bg"],
        ])
        let byAssociated = fx.plist(fx.sys("LaunchDaemons/vendor.plist"), [
            "Label": "vendor", "AssociatedBundleIdentifiers": ["com.acme.notas"],
        ])
        let unrelated = fx.plist(fx.sys("LaunchDaemons/com.otra.plist"), [
            "Label": "com.otra", "Program": "/Applications/Notas.app.evil/bin",
        ])
        for path in [byName, byLabel, byProgram, byAssociated] {
            #expect(policy.evaluate(path: path, kind: .residue) == .allowed(.high), "\(path)")
        }
        #expect(!isAllowed(policy.evaluate(path: unrelated, kind: .residue)))
    }

    @Test func archivosDeRecibosSoloConNombreDeLaAppYDentroDeLibrary() {
        let app = fx.makeApp("Notas Pro", bundleID: "com.acme.notas")
        var policy = fx.policy(app)
        let framework = fx.folder(fx.sys("Frameworks/Notas Pro.framework"))
        let sharedDir = fx.sys("Frameworks")
        let unrelated = fx.folder(fx.sys("Frameworks/Sparkle.framework"))
        let topLevel = fx.folder(fx.sys("Notas Pro"))
        policy.packagePaths = [framework, sharedDir, unrelated, topLevel, app.path]
        #expect(policy.evaluate(path: framework, kind: .packageFile) == .allowed(.high))
        #expect(!isAllowed(policy.evaluate(path: sharedDir, kind: .packageFile)))
        #expect(!isAllowed(policy.evaluate(path: unrelated, kind: .packageFile)))
        #expect(!isAllowed(policy.evaluate(path: topLevel, kind: .packageFile)))
        #expect(!isAllowed(policy.evaluate(path: app.path, kind: .packageFile)))
        policy.packagePaths = []
        #expect(!isAllowed(policy.evaluate(path: framework, kind: .packageFile)))
    }
}

@Suite("Borrado seguro")
struct SafeFSTests {
    let fx = Fixture()

    @Test func noSigueEnlacesSimbolicos() throws {
        let keep = fx.folder(fx.root + "/keep")
        let victim = fx.folder(fx.user("Caches/com.acme.notas"))
        try FileManager.default.createSymbolicLink(atPath: victim + "/link", withDestinationPath: keep)
        try SafeFS.remove(victim)
        #expect(!fx.exists(victim))
        #expect(fx.exists(keep + "/data.bin"))
    }

    @Test func fallaSiUnComponenteEsUnEnlace() throws {
        let real = fx.folder(fx.root + "/real/com.acme.notas")
        try FileManager.default.createSymbolicLink(atPath: fx.root + "/alias", withDestinationPath: fx.root + "/real")
        #expect(throws: SafeFSError.self) { try SafeFS.remove(fx.root + "/alias/com.acme.notas") }
        #expect(fx.exists(real))
    }

    @Test func papeleraNoSobrescribe() throws {
        let first = fx.file(fx.user("Caches/a/dato.txt"), "uno")
        let second = fx.file(fx.user("Caches/b/dato.txt"), "dos")
        let one = try SafeFS.moveToTrash(first, trash: fx.layout.trash, owner: getuid())
        let two = try SafeFS.moveToTrash(second, trash: fx.layout.trash, owner: getuid())
        #expect(one != two)
        #expect(fx.exists(one) && fx.exists(two))
        #expect(!fx.exists(first) && !fx.exists(second))
    }
}
