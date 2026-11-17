import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    let layout = FSLayout.live()

    var apps: [AppInfo] = []
    var search = ""
    var selection: AppInfo.ID?

    var scan: ScanResult?
    var isScanning = false
    var checked: Set<String> = []
    var sizes: [String: Int64] = [:]

    var hasFullDiskAccess = true
    var pendingMode: RemovalMode?
    var isUninstalling = false
    var report: UninstallReport?

    var quarantined: [QuarantineSession] = []
    var quarantineSizes: [String: Int64] = [:]
    var showQuarantine = false
    var quarantineBusy = false
    var quarantineMessage: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init() {
        reloadApps()
        let quarantine = quarantine
        Task {
            await Task.detached(priority: .utility) { quarantine.purgeExpired() }.value
            reloadQuarantine()
        }
    }

    private var quarantine: Quarantine {
        Quarantine(layout: layout, runPrivileged: UninstallHooks.live().runPrivileged)
    }

    func reloadQuarantine() {
        let quarantine = quarantine
        Task {
            let sessions = await Task.detached(priority: .userInitiated) { quarantine.sessions() }.value
            quarantined = sessions
            for session in sessions {
                let size = await Task.detached(priority: .utility) { quarantine.size(of: session) }.value
                quarantineSizes[session.id] = size
            }
        }
    }

    func restore(_ session: QuarantineSession) {
        guard !quarantineBusy else { return }
        quarantineBusy = true
        quarantineMessage = nil
        let quarantine = quarantine
        Task {
            let results = await Task.detached(priority: .userInitiated) { await quarantine.restore(session) }.value
            let failed = results.filter { !$0.succeeded }
            quarantineMessage = failed.isEmpty
                ? "\(session.appName) restaurada. Los agentes en segundo plano se cargarán al volver a iniciar sesión."
                : "No se pudieron restaurar \(failed.count) elementos de \(session.appName): \(failed.first?.message ?? "")"
            quarantineBusy = false
            reloadQuarantine()
            reloadApps()
        }
    }

    func purge(_ session: QuarantineSession) {
        guard !quarantineBusy else { return }
        quarantineBusy = true
        quarantineMessage = nil
        let quarantine = quarantine
        Task {
            let error = await Task.detached(priority: .userInitiated) { await quarantine.purge(session) }.value
            quarantineMessage = error.map { "No se pudo eliminar \(session.appName): \($0)" }
            quarantineBusy = false
            reloadQuarantine()
        }
    }

    var filteredApps: [AppInfo] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var selectedItems: [Residue] {
        scan?.allItems.filter { checked.contains($0.path) } ?? []
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + (sizes[$1.path] ?? 0) }
    }

    var selectionNeedsAdmin: Bool {
        selectedItems.contains(where: \.needsAdmin)
    }

    /// Los recibos solo se olvidan (con administrador) en el borrado definitivo.
    var selectionForgetsPackages: Bool {
        scan.map { !$0.packageIDs.isEmpty && checked.contains($0.app.path) } ?? false
    }

    func reloadApps() {
        hasFullDiskAccess = FullDiskAccess.isGranted(layout: layout)
        let layout = layout
        let ownPath = Bundle.main.bundlePath
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                AppCatalog.installedApps(layout: layout, excluding: ownPath)
            }.value
            apps = found
            if let selection, !found.contains(where: { $0.id == selection }) {
                self.selection = nil
                selectionChanged()
            }
        }
    }

    func selectionChanged() {
        scanTask?.cancel()
        scan = nil
        checked = []
        sizes = [:]
        isScanning = false
        guard let app = apps.first(where: { $0.id == selection }) else { return }
        isScanning = true
        let layout = layout
        let installed = apps
        scanTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                ResidueScanner(
                    layout: layout, packages: LivePackageDatabase(),
                    findProcesses: { ProcessFinder.find(bundlePath: $0) }
                ).scan(app: app, installed: installed)
            }.value
            guard !Task.isCancelled else { return }
            isScanning = false
            scan = result
            guard let result else { return }
            // Por defecto: coincidencias seguras. Las de solo nombre, y todo
            // lo compartido con otra copia de la app, quedan sin marcar.
            let shared = !result.duplicates.isEmpty
            checked = Set(result.allItems
                .filter { $0.kind == .bundle || ($0.confidence == .high && !shared) }
                .map(\.path))
            for item in result.allItems {
                let size = await Task.detached(priority: .utility) { DiskUsage.size(of: item.path) }.value
                guard !Task.isCancelled else { return }
                sizes[item.path] = size
            }
        }
    }

    func toggle(_ item: Residue) {
        if checked.contains(item.path) {
            checked.remove(item.path)
        } else {
            checked.insert(item.path)
        }
    }

    /// `permanent` convierte la cuarentena en borrado definitivo.
    func confirmUninstall(permanent: Bool = false) {
        guard let scan, var mode = pendingMode, !isUninstalling else { return }
        if mode == .quarantine, permanent { mode = .delete }
        let request = UninstallRequest(scan: scan, items: selectedItems, mode: mode)
        pendingMode = nil
        isUninstalling = true
        let layout = layout
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await Uninstaller(layout: layout, hooks: .live()).run(request)
            }.value
            isUninstalling = false
            report = result
            reloadApps()
            reloadQuarantine()
            selectionChanged()
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }
}
