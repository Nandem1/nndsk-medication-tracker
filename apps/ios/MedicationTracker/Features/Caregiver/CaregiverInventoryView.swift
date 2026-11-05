import SwiftUI

struct CaregiverInventoryView: View {
    let patient: String
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            SyncBanner()
            if let snapshot = model.patientSnapshot(patient) {
                if snapshot.inventory.isEmpty { Text("Sin inventario registrado.") }
                ForEach(snapshot.inventory) { account in
                    NavigationLink {
                        CaregiverInventoryDetail(patient: patient, accountID: account.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(snapshot.treatments.first { $0.id == account.treatmentID }?.name ?? "Medicamento").font(.headline)
                            FamilyStockSummary(account: account, snapshot: snapshot)
                        }
                    }.accessibilityIdentifier("caregiver-inventory-\(account.id)")
                }
            }
        }.refreshable { await model.syncNow() }
    }
}

struct FamilyStockSummary: View {
    let account: InventoryProjection
    let snapshot: LocalSnapshot
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Saldo confirmado").font(.footnote).foregroundStyle(Semantic.muted)
                Text(ExactQuantity.withUnit(account.balance, unit: account.unit)).font(.title2.weight(.semibold))
            }.accessibilityElement(children: .combine).accessibilityIdentifier("family-stock-confirmed")
            if let estimate = StockEstimate.estimated(account: account, doses: snapshot.doses, operations: snapshot.operations) {
                Text("Estimado con registros pendientes: \(ExactQuantity.withUnit(estimate, unit: account.unit))")
                    .padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Semantic.muted, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .accessibilityIdentifier("family-stock-estimated")
            }
            if let uncovered = account.firstUncoveredAt.flatMap(Instant.parse) {
                if let from = account.from.flatMap(Instant.parse) {
                    Text("Cobertura: \(coverageDays(from: from, to: uncovered)) días completos")
                }
                Text("El saldo no alcanza desde: \(DoseText.instant(uncovered))").font(.footnote)
            } else if let through = account.through.flatMap(Instant.parse), let from = account.from.flatMap(Instant.parse) {
                Text("Cobertura: al menos \(coverageDays(from: from, to: through)) días")
            }
            if account.lowStock == true { StatusBadge(text: "Reposición por revisar", systemImage: "shippingbox", tone: .scheduled) }
            if let replenish = account.replenishOn { Text("Fecha de revisión: \(DoseText.day(replenish))").font(.footnote) }
            if (ExactQuantity.parse(account.balance) ?? 0) < 0 { Text("El saldo es negativo. Revisa el conteo físico.") }
            if model.syncProblem == .transport, let last = snapshot.lastSyncAt { Text("Datos guardados de: \(DoseText.instant(last))").font(.footnote).foregroundStyle(Semantic.muted) }
        }
    }
    private func coverageDays(from: Date, to: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: account.timezone ?? snapshot.access?.timezone ?? "America/Santiago") ?? .current
        return max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0)
    }
}

struct CaregiverInventoryDetail: View {
    let patient: String
    let accountID: String
    @Environment(AppModel.self) private var model
    @State private var movements: [InventoryMovement] = []
    @State private var loading = false
    @State private var error: String?
    @State private var form: InventoryFormPresentation?
    @State private var rejection = false
    var body: some View {
        Group {
            if let snapshot = model.patientSnapshot(patient), let account = snapshot.inventory.first(where: { $0.id == accountID }) {
                List {
                    Section {
                        FamilyStockSummary(account: account, snapshot: snapshot)
                        SharedInventoryRows(account: account, canEdit: model.permits("inventory", patient: patient), propose: true)
                    }
                    if model.permits("inventory", patient: patient) {
                        Section {
                            Button("Registrar reposición") { form = InventoryFormPresentation(account: account, kind: .replenishment) }.frame(minHeight: 44).accessibilityIdentifier("inventory-replenish").disabled(model.syncProblem == .transport)
                            Button("Conteo físico") { form = InventoryFormPresentation(account: account, kind: .count) }.frame(minHeight: 44).accessibilityIdentifier("inventory-count").disabled(model.syncProblem == .transport)
                            Text(model.syncProblem == .transport ? "Sin conexión. Actualiza el inventario cuando vuelva internet para registrar una reposición o conteo." : "Estas operaciones requieren internet. No se guardan en la cola sin conexión.").font(.footnote)
                        }
                    } else { Label("Tu acceso no permite modificar el inventario", systemImage: "eye") }
                    Section("Movimientos") {
                        if loading { ProgressView("Cargando movimientos") }
                        if let error {
                            Label(error, systemImage: rejection ? "exclamationmark.triangle" : "info.circle").foregroundStyle(rejection ? Semantic.danger : Semantic.muted)
                            Button("Reintentar") { Task { await load() } }.frame(minHeight: 44)
                        } else if !loading && movements.isEmpty { Text("Sin movimientos registrados.") }
                        // Lo más reciente primero. La API no los entrega por fecha.
                        ForEach(movements.sorted { $0.createdAt > $1.createdAt }) { movement in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(movement.label).font(.headline)
                                Text(ExactQuantity.withUnit(movement.quantity, unit: account.unit))
                                if let name = movement.patientName { Text(name) }
                                Text(movement.sharedDate ?? Instant.parse(movement.createdAt).map(DoseText.instant) ?? movement.createdAt).font(.footnote)
                            }
                        }
                    }
                }
                .navigationTitle(snapshot.treatments.first { $0.id == account.treatmentID }?.name ?? "Inventario")
                .sheet(item: $form, onDismiss: { Task { await load() } }) { presentation in
                    InventoryForm(patient: patient, account: presentation.account, kind: presentation.kind)
                }
                .refreshable { await model.syncNow(); await load() }
            } else { ContentUnavailableView("Inventario no disponible", systemImage: "shippingbox") }
        }.navigationBarTitleDisplayMode(.inline).task { await load() }
    }
    private func load() async {
        loading = true
        defer { loading = false }
        do { movements = try await model.movements(patient: patient, account: accountID); error = nil }
        catch { rejection = [APIError.denied, .invalid, .conflict].contains(where: { $0 == error as? APIError }); self.error = (error as? APIError)?.message ?? APIError.server.message }
    }
}

struct InventoryFormPresentation: Identifiable {
    let id = UUID()
    let account: InventoryProjection
    let kind: InventoryFormKind
}

enum InventoryFormKind: String, Identifiable { case replenishment, count; var id: String { rawValue } }

struct InventoryForm: View {
    let patient: String
    let account: InventoryProjection
    let kind: InventoryFormKind
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var quantity = ""
    @State private var reason = ""
    @State private var operation = UUID().uuidString.lowercased()
    @State private var sentQuantity: String?
    @State private var sentReason: String?
    @State private var expectedBalance: String?
    @State private var rejection = false
    @State private var working = false
    @State private var error: String?
    private var normalized: String { quantity.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".") }
    private var valid: Bool {
        guard normalized.wholeMatch(of: /[0-9]{1,9}(\.[0-9]{1,3})?/) != nil,
              let amount = ExactQuantity.parse(normalized), amount >= 0 else { return false }
        return (kind == .count || amount > 0) && (kind != .count || !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Saldo confirmado: \(ExactQuantity.withUnit(account.balance, unit: account.unit))")
                    TextField(kind == .count ? "Cantidad contada" : "Cantidad a reponer", text: $quantity).keyboardType(.decimalPad).accessibilityIdentifier("inventory-quantity")
                        .disabled(sentQuantity != nil)
                    if kind == .count { TextField("Motivo del conteo", text: $reason, axis: .vertical).accessibilityIdentifier("inventory-reason").disabled(sentQuantity != nil) }
                }
                if let error { Section { Label(error, systemImage: rejection ? "exclamationmark.triangle" : "info.circle").foregroundStyle(rejection ? Semantic.danger : Semantic.muted).accessibilityIdentifier("inventory-error") } }
                Section {
                    Button { Task { await save() } } label: { ActionLabel(text: working ? "Guardando…" : sentQuantity == nil ? "Guardar" : "Reintentar el mismo registro") }
                        .largeAction(prominent: true).disabled(working || !valid).accessibilityIdentifier("inventory-save")
                } footer: {
                    Text(sentQuantity == nil ? "Requiere internet. El conteo registra un ajuste auditable; no cambia la pauta." : "Si se perdió la respuesta, el reintento comprueba la misma operación sin duplicarla. Conserva esta pantalla hasta comprobar el resultado.")
                }
            }.navigationTitle(kind == .count ? "Conteo físico" : "Registrar reposición")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() }.disabled(working) } }
        }.interactiveDismissDisabled(working)
    }
    private func save() async {
        expectedBalance = expectedBalance ?? account.balance
        sentQuantity = sentQuantity ?? normalized
        sentReason = sentReason ?? reason.trimmingCharacters(in: .whitespacesAndNewlines)
        working = true
        defer { working = false }
        do {
            try await model.inventoryMutation(patient: patient, account: account.id, quantity: sentQuantity ?? normalized, count: kind == .count, reason: sentReason ?? "", expected: expectedBalance ?? account.balance, operation: operation)
            dismiss()
        } catch {
            rejection = [APIError.denied, .invalid, .conflict].contains(where: { $0 == error as? APIError })
            self.error = error as? APIError == .conflict ? "El saldo cambió. Cierra esta pantalla, actualiza el inventario y revisa el conteo antes de registrarlo otra vez." : (error as? APIError)?.message ?? APIError.server.message
        }
    }
}
