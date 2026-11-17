import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.filteredApps, selection: $model.selection) { app in
                AppRow(app: app)
            }
            .searchable(text: $model.search, placement: .sidebar, prompt: "Buscar apps")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .overlay {
                if model.filteredApps.isEmpty {
                    ContentUnavailableView("Sin resultados", systemImage: "magnifyingglass")
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if !model.hasFullDiskAccess { FullDiskAccessBanner() }
                if model.selection == nil {
                    ContentUnavailableView(
                        "Elige una app",
                        systemImage: "trash.slash",
                        description: Text("SinRastro muestra sus procesos y archivos residuales antes de borrar nada."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let scan = model.scan {
                    AppDetailView(scan: scan)
                } else if model.isScanning {
                    ProgressView("Buscando archivos…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No se pudo leer esta app", systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: model.selection) { model.selectionChanged() }
        .sheet(item: $model.pendingMode) { mode in
            ConfirmSheet(mode: mode)
        }
        .sheet(item: $model.report) { report in
            ReportSheet(report: report)
        }
        .sheet(isPresented: $model.showQuarantine) {
            QuarantineSheet()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.reloadQuarantine()
                    model.showQuarantine = true
                } label: {
                    Label(
                        model.quarantined.isEmpty ? "Cuarentena" : "Cuarentena (\(model.quarantined.count))",
                        systemImage: "archivebox")
                        .labelStyle(.titleAndIcon)
                }
                .help("Apps desinstaladas que aún se pueden restaurar")
            }
        }
        .overlay {
            if model.isUninstalling {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView("Desinstalando…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

extension RemovalMode: Identifiable {
    var id: String { rawValue }
}

struct AppIcon: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AppRow: View {
    let app: AppInfo

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.path, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                if let version = app.version {
                    Text(version).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Falta el Acceso total al disco").font(.headline)
                Text("Sin ese permiso el escaneo queda incompleto: no se pueden leer contenedores ni otras carpetas protegidas.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abrir Ajustes") { model.openFullDiskAccessSettings() }
            Button("Comprobar") { model.reloadApps() }
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }
}
