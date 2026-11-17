import SwiftUI

struct AppDetailView: View {
    @Environment(AppModel.self) private var model
    let scan: ScanResult

    private var userItems: [Residue] { scan.residues.filter { $0.scope == .user } }
    private var systemItems: [Residue] { scan.residues.filter { $0.scope == .system } }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section { header }
                warnings

                if !scan.processes.isEmpty {
                    Section("Procesos en ejecución") {
                        ForEach(scan.processes) { process in
                            LabeledContent {
                                Text("pid \(process.pid)").monospacedDigit().foregroundStyle(.secondary)
                            } label: {
                                Label(process.name, systemImage: process.isApp ? "macwindow" : "gearshape.2")
                            }
                        }
                    }
                }

                Section("Aplicación") {
                    if let bundle = scan.bundle {
                        ItemRow(item: bundle)
                    } else {
                        Label(scan.bundleOmittedReason ?? "No se puede eliminar", systemImage: "nosign")
                            .foregroundStyle(.secondary)
                    }
                }

                if !userItems.isEmpty {
                    Section("Usuario") {
                        ForEach(userItems) { ItemRow(item: $0) }
                    }
                }
                if !systemItems.isEmpty {
                    Section {
                        ForEach(systemItems) { ItemRow(item: $0) }
                    } header: {
                        Label("Sistema", systemImage: "lock.fill")
                    }
                }
                if !scan.packageIDs.isEmpty {
                    Section("Recibos de instalación") {
                        ForEach(scan.packageIDs, id: \.self) { id in
                            Label(id, systemImage: "shippingbox").font(.callout)
                        }
                        Text("Se olvidan con pkgutil solo al eliminar definitivamente. Requiere administrador.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !scan.omitted.isEmpty {
                    Section("Omitidos (no se borran)") {
                        ForEach(scan.omitted) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.path).font(.callout).lineLimit(1).truncationMode(.middle)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            .help(item.path)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIcon(path: scan.app.path, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(scan.app.name).font(.title2).bold()
                Text([scan.app.version.map { "Versión \($0)" }, scan.app.bundleID].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(scan.app.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Mostrar en Finder") { model.revealInFinder(scan.app.path) }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var warnings: some View {
        if scan.homebrewCask != nil || !scan.duplicates.isEmpty || !scan.unreadable.isEmpty {
            Section {
                if let cask = scan.homebrewCask {
                    Label {
                        Text("Instalada con Homebrew. Es preferible `brew uninstall --cask \(cask)`. SinRastro no toca el prefijo de Homebrew.")
                    } icon: {
                        Image(systemName: "mug").foregroundStyle(.orange)
                    }
                }
                if !scan.duplicates.isEmpty {
                    Label {
                        Text("Hay otra copia con el mismo identificador (\(scan.duplicates.joined(separator: ", "))). Sus datos son compartidos, así que solo queda marcada la app.")
                    } icon: {
                        Image(systemName: "doc.on.doc").foregroundStyle(.orange)
                    }
                }
                if !scan.unreadable.isEmpty {
                    Label {
                        Text("Escaneo incompleto, no se pudo leer: \(scan.unreadable.map { PathUtil.name($0) }.joined(separator: ", ")). Concede Acceso total al disco.")
                    } icon: {
                        Image(systemName: "eye.slash").foregroundStyle(.orange)
                    }
                }
            }
            .font(.callout)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let count = model.selectedItems.count
            Text("\(count) \(count == 1 ? "elemento" : "elementos") · \(model.selectedSize.formatted(.byteCount(style: .file)))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Mover a la Papelera") { model.pendingMode = .trash }
            Button("Desinstalar por completo…", role: .destructive) { model.pendingMode = .quarantine }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .disabled(model.selectedItems.isEmpty || model.isUninstalling)
        .padding(12)
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: Residue

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.checked.contains(item.path) },
                set: { _ in model.toggle(item) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PathUtil.name(item.path)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(item.category)
                        if item.confidence == .medium {
                            Text("Coincide solo por nombre").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if item.needsAdmin {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Requiere administrador")
                    .accessibilityLabel("Requiere administrador")
            }
            if let size = model.sizes[item.path] {
                Text(size.formatted(.byteCount(style: .file)))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .help(item.path)
        .contextMenu {
            Button("Mostrar en Finder") { model.revealInFinder(item.path) }
        }
    }
}
