import AppKit
import Foundation

enum ProcessFinder {
    static func find(bundlePath: String) -> [RunningProcess] {
        let guiPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleURL?.standardizedFileURL.path == bundlePath }
                .map(\.processIdentifier))
        let own = getpid()
        return ProcessLister.processes(inside: bundlePath)
            .filter { $0.pid != own }
            .map { RunningProcess(pid: $0.pid, name: PathUtil.name($0.path), path: $0.path, isApp: guiPIDs.contains($0.pid)) }
    }
}

enum FullDiskAccess {
    /// Sin Acceso total al disco, macOS deniega leer estas carpetas del home.
    static func isGranted(layout: FSLayout) -> Bool {
        guard layout.isLive else { return true }
        let probes = [
            "Application Support/com.apple.TCC", "Safari", "Mail", "Cookies", "HTTPStorages",
        ]
        for probe in probes {
            let path = layout.userLibrary + "/" + probe
            guard let dir = opendir(path) else {
                if errno == EPERM || errno == EACCES { return false }
                continue
            }
            closedir(dir)
        }
        return true
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

extension UninstallHooks {
    static func live() -> UninstallHooks {
        UninstallHooks(
            bootoutAgent: { label in
                _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            },
            terminate: { bundlePath in await terminateProcesses(bundlePath: bundlePath) },
            trash: { path in
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            },
            runPrivileged: { manifest in runHelper(manifest) }
        )
    }

    private static func waitUntilGone(_ pids: [pid_t], seconds: Double) async -> [pid_t] {
        var remaining = pids
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            remaining = remaining.filter(ProcessLister.isAlive)
            if remaining.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return remaining.filter(ProcessLister.isAlive)
    }

    private static func terminateProcesses(bundlePath: String) async -> [String] {
        let processes = ProcessFinder.find(bundlePath: bundlePath)
        guard !processes.isEmpty else { return [] }
        for process in processes {
            if process.isApp, let app = NSRunningApplication(processIdentifier: process.pid) {
                app.terminate()
            } else {
                kill(process.pid, SIGTERM)
            }
        }
        var remaining = await waitUntilGone(processes.map(\.pid), seconds: 3)
        for pid in remaining {
            if let app = NSRunningApplication(processIdentifier: pid) { app.forceTerminate() }
            kill(pid, SIGKILL)
        }
        remaining = await waitUntilGone(remaining, seconds: 2)
        return processes.filter { remaining.contains($0.pid) }.map {
            "No se pudo cerrar \($0.name) (pid \($0.pid)); puede necesitar administrador"
        }
    }

    /// Lanza el helper con `do shell script … with administrator privileges`.
    /// A AppleScript solo le llegan dos rutas, como argumentos y con
    /// `quoted form of`; nunca se concatena un comando con rutas.
    private static func runHelper(_ manifest: HelperManifest) -> HelperReport {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "SinRastroHelper")?.path else {
            return HelperReport(error: "No se encontró el helper dentro de la app")
        }
        let manifestPath = NSTemporaryDirectory() + "sinrastro-\(UUID().uuidString).json"
        guard
            let data = try? JSONEncoder().encode(manifest),
            FileManager.default.createFile(atPath: manifestPath, contents: data, attributes: [.posixPermissions: 0o600])
        else {
            return HelperReport(error: "No se pudo escribir el manifiesto")
        }
        defer { try? FileManager.default.removeItem(atPath: manifestPath) }

        let script = [
            "on run argv",
            "do shell script (quoted form of (item 1 of argv)) & \" \" & (quoted form of (item 2 of argv)) "
                + "with prompt \"SinRastro necesita permiso de administrador para eliminar archivos del sistema.\" "
                + "with administrator privileges",
            "end run",
        ]
        let output = Shell.run("/usr/bin/osascript", script.flatMap { ["-e", $0] } + [helper, manifestPath])
        guard output.status == 0 else {
            let cancelled = output.stderr.contains("-128")
            return HelperReport(error: cancelled
                ? "Se canceló la autorización de administrador"
                : "El helper falló: \(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard let report = try? JSONDecoder().decode(HelperReport.self, from: Data(output.stdout.utf8)) else {
            return HelperReport(error: "Respuesta del helper no reconocida")
        }
        return report
    }
}
