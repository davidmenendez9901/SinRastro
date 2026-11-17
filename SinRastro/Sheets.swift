import SwiftUI

struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let mode: RemovalMode
    @State private var permanent = false

    private var isPermanent: Bool { mode == .delete || (mode == .quarantine && permanent) }

    var body: some View {
        let items = model.selectedItems
        let name = model.scan?.app.name ?? ""
        let size = model.selectedSize.formatted(.byteCount(style: .file))
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .trash ? "¿Mover \(name) a la Papelera?" : "¿Desinstalar \(name) por completo?")
                .font(.title3).bold()

            Group {
                if mode == .trash {
                    Text("Se moverán \(items.count) elementos (\(size)) a la Papelera. Podrás recuperarlos desde ahí.")
                } else if isPermanent {
                    Text("Se eliminarán de forma definitiva \(items.count) elementos (\(size)). No se puede deshacer.")
                } else {
                    Text("Se quitarán \(items.count) elementos (\(size)) y se guardarán en la cuarentena de SinRastro. Podrás restaurarlos durante \(Quarantine.retentionDays) días.")
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        Text(item.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(height: 200)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if model.leftBehindCount > 0 {
                let count = model.leftBehindCount
                Label {
                    Text(count == 1
                        ? "Queda 1 elemento sin marcar. Cuando la app ya no esté, SinRastro no podrá volver a encontrarlo."
                        : "Quedan \(count) elementos sin marcar. Cuando la app ya no esté, SinRastro no podrá volver a encontrarlos.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
            if mode == .quarantine {
                Toggle("Eliminar definitivamente ahora, sin cuarentena", isOn: $permanent)
            }
            if let scan = model.scan, !scan.processes.isEmpty {
                Label("Se cerrarán \(scan.processes.count) procesos de la app.", systemImage: "xmark.app")
                    .font(.callout)
            }
            if model.selectionNeedsAdmin || (isPermanent && model.selectionForgetsPackages) {
                Label("macOS pedirá la contraseña de administrador una vez.", systemImage: "lock.fill")
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { model.pendingMode = nil }
                    .keyboardShortcut(.cancelAction)
                if mode == .trash {
                    Button("Mover a la Papelera") { model.confirmUninstall() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(isPermanent ? "Eliminar definitivamente" : "Desinstalar", role: .destructive) {
                        model.confirmUninstall(permanent: permanent)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: UninstallReport

    private var doneTitle: String {
        switch report.mode {
        case .delete: "desinstalada"
        case .trash: "movida a la Papelera"
        case .quarantine: "desinstalada"
        }
    }

    private var doneSection: String {
        switch report.mode {
        case .delete: "Eliminado"
        case .trash: "En la Papelera"
        case .quarantine: "En cuarentena"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(report.failed.isEmpty ? "\(report.appName): \(doneTitle)" : "\(report.appName): terminado con errores")
                    .font(.title3).bold()
            } icon: {
                Image(systemName: report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.failed.isEmpty ? .green : .orange)
            }
            if report.sessionID != nil {
                Text("Puedes restaurarla durante \(Quarantine.retentionDays) días desde el botón Cuarentena.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            List {
                if !report.failed.isEmpty {
                    Section("No se quitó (\(report.failed.count))") {
                        ForEach(report.failed) { result in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.path).font(.callout).lineLimit(1).truncationMode(.middle)
                                Text(result.message ?? "Error desconocido").font(.caption).foregroundStyle(.red)
                            }
                            .help(result.path)
                        }
                    }
                }
                if !report.notes.isEmpty {
                    Section("Avisos") {
                        ForEach(report.notes, id: \.self) { Text($0).font(.callout) }
                    }
                }
                Section("\(doneSection) (\(report.succeeded.count))") {
                    ForEach(report.succeeded) { result in
                        Text(result.path).font(.callout).lineLimit(1).truncationMode(.middle).help(result.path)
                    }
                    ForEach(report.forgotten, id: \.self) { id in
                        Label("Recibo olvidado: \(id)", systemImage: "shippingbox").font(.callout)
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: 280)

            HStack {
                Text("Registro en ~/Library/Logs/SinRastro/uninstall.log")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
    }
}

struct QuarantineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cuarentena").font(.title3).bold()
            Text("Lo que desinstalas se guarda aquí \(Quarantine.retentionDays) días. Restaurar lo devuelve a su sitio original.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.quarantined.isEmpty {
                ContentUnavailableView("La cuarentena está vacía", systemImage: "archivebox")
                    .frame(height: 260)
            } else {
                List(model.quarantined) { session in
                    QuarantineRow(session: session)
                }
                .listStyle(.inset)
                .frame(height: 260)
            }

            if let message = model.quarantineMessage {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.quarantineBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cerrar") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

struct QuarantineRow: View {
    @Environment(AppModel.self) private var model
    let session: QuarantineSession

    private var detail: String {
        var parts = ["\(session.entries.count) \(session.entries.count == 1 ? "elemento" : "elementos")"]
        if let size = model.quarantineSizes[session.id] {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        parts.append(session.date.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private var expiry: String {
        if session.isExpired { return "Caducada: elimínala cuando quieras" }
        let days = max(1, Int(ceil(session.expires.timeIntervalSinceNow / 86_400)))
        return days == 1 ? "Se elimina en 1 día" : "Se elimina en \(days) días"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.appName).bold()
                    if session.usesHelper {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .help("Restaurarla o eliminarla requiere administrador")
                            .accessibilityLabel("Requiere administrador")
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(expiry).font(.caption).foregroundStyle(session.isExpired ? .orange : .secondary)
            }
            Spacer()
            Button("Restaurar") { model.restore(session) }
            Button("Eliminar ya", role: .destructive) { model.purge(session) }
        }
        .disabled(model.quarantineBusy)
        .padding(.vertical, 2)
        .help(session.entries.map(\.original).joined(separator: "\n"))
    }
}
