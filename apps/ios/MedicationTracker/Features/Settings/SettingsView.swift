import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            List {
                remindersSection
                Section("Avisos remotos del cuidador") { Text(model.pushDiagnostic) }
                syncSection
                Section("Inventario") {
                    if model.snapshot.inventory.isEmpty {
                        Text("Sin inventario registrado.")
                    }
                    ForEach(model.snapshot.inventory) { account in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.snapshot.treatments.first { $0.id == account.treatmentID }?.name ?? "Medicamento")
                                .font(.headline)
                            StockSummary(account: account)
                        }
                    }
                }
                Section("Acceso del cuidador") {
                    NavigationLink("Cuidadores e invitaciones") { ConsentView() }
                        .accessibilityIdentifier("open-consent")
                }
                Section("Cuenta") {
                    Text(DoseText.selfReported)
                    Button("Cerrar sesión", role: .destructive) { confirmSignOut = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("sign-out")
                }
            }
            .navigationTitle("Ajustes")
            .refreshable { await model.syncNow() }
            .confirmationDialog(signOutTitle, isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Cerrar sesión y borrar datos locales", role: .destructive) {
                    Task { await model.signOut() }
                }
            } message: {
                Text("Se borrarán la agenda guardada y los recordatorios de este teléfono.")
            }
        }
    }

    private var signOutTitle: String {
        let count = model.snapshot.operations.count
        return count == 0 ? "¿Cerrar sesión?" : "Tienes \(count) registro(s) sin sincronizar que se perderán. ¿Cerrar sesión?"
    }

    @ViewBuilder
    private var remindersSection: some View {
        Section("Recordatorios") {
            reminderStatus
            if model.reminders.permission == .notDetermined {
                Button("Activar recordatorios") {
                    Task { await model.requestReminderPermission() }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings-enable-reminders")
            }
            if model.reminders.permission == .denied || model.reminders.permission == .limited {
                Button("Abrir Ajustes del sistema") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
                .frame(minHeight: 44)
            }
            Text("Recordatorios programados: \(model.reminders.scheduledCount)")
                .accessibilityIdentifier("reminder-count")
            if let through = model.reminders.scheduledThrough {
                Text("Cubren hasta: \(DoseText.instant(through)). Abre la app antes de esa fecha para reponerlos.")
            }
            Text(DoseText.reliability).font(.footnote).foregroundStyle(Semantic.muted)
        }
    }

    @ViewBuilder
    private var reminderStatus: some View {
        switch model.reminders.permission {
        case .enabled:
            if model.waitingOperationsCount > 0 || model.syncProblem != nil {
                StatusBadge(text: "Sincronización pendiente", systemImage: "arrow.triangle.2.circlepath", tone: .sync)
                    .accessibilityIdentifier("reminder-status")
            } else {
                StatusBadge(text: "Recordatorios habilitados", systemImage: "bell.fill", tone: .taken)
                    .accessibilityIdentifier("reminder-status")
            }
        case .denied:
            StatusBadge(text: "Permiso denegado", systemImage: "bell.slash", tone: .unconfirmed)
                .accessibilityIdentifier("reminder-status")
        case .limited:
            StatusBadge(text: "Precisión limitada", systemImage: "bell.badge", tone: .unconfirmed)
                .accessibilityIdentifier("reminder-status")
        case .notDetermined:
            StatusBadge(text: "Recordatorios sin activar", systemImage: "bell", tone: .scheduled)
                .accessibilityIdentifier("reminder-status")
        }
    }

    @ViewBuilder
    private var syncSection: some View {
        Section("Sincronización") {
            SyncBanner()
            Text("Registros por enviar: \(model.waitingOperationsCount)")
                .accessibilityIdentifier("pending-count")
            ForEach(model.unresolvedOperations) { operation in
                UnresolvedOperationRow(operation: operation)
            }
            if let last = model.snapshot.lastSyncAt {
                Text("Última sincronización: \(DoseText.instant(last))")
            }
            Button(model.isSyncing ? "Sincronizando…" : "Sincronizar ahora") {
                Task { await model.syncNow() }
            }
            .frame(minHeight: 44)
            .disabled(model.isSyncing)
            .accessibilityIdentifier("sync-now")
        }
    }
}

/// Toda operación rechazada es visible aquí, también si su dosis ya no está en la agenda.
private struct UnresolvedOperationRow: View {
    let operation: PendingOperation
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = DoseText.operation(operation)
        if model.dose(id: operation.doseID) != nil {
            NavigationLink {
                DoseDetailView(doseID: operation.doseID)
            } label: {
                StatusBadge(text: status.text, systemImage: status.icon, tone: status.tone)
            }
            .accessibilityIdentifier("unresolved-operation")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tu registro «\(DoseText.declaration(operation.declaration))» corresponde a una dosis que ya no está en tu agenda.")
                Button("Descartar registro") {
                    Task { await model.discard(operation) }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier("unresolved-discard")
            }
        }
    }
}
