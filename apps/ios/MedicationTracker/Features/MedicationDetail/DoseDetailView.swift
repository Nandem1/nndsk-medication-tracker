import SwiftUI

struct DoseDetailView: View {
    let doseID: String
    @Environment(AppModel.self) private var model
    @State private var correcting = false
    @State private var earlierForm = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let dose = model.dose(id: doseID) {
                content(dose: dose, now: context.date)
            } else {
                ContentUnavailableView("Esta dosis ya no está en tu agenda", systemImage: "calendar.badge.exclamationmark", description: Text("Puede haber cambiado la pauta. Actualiza la pantalla Hoy."))
            }
        }
        .navigationTitle("Detalle de la toma")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(dose: Dose, now: Date) -> some View {
        let treatment = model.treatment(for: dose)
        let operation = model.operation(for: dose)
        return List {
            Section {
                DoseSummary(dose: dose, now: now)
                DoseActions(dose: dose, now: now)
                if operation == nil, !dose.state.isDeclared, dose.scheduledInstant <= now {
                    Button("Me lo tomé a otra hora") { earlierForm = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("action-taken-earlier")
                }
            }
            if let operation, operation.status != .pending {
                Section("Revisar registro") {
                    ConflictResolution(operation: operation, dose: dose)
                }
            }
            if let account = treatment.flatMap({ model.account(for: $0.id) }) {
                Section("Inventario") {
                    StockSummary(account: account)
                }
            }
            if let treatment, !treatment.instructions.isEmpty {
                Section("Instrucciones registradas") {
                    Text(treatment.instructions)
                }
            }
            Section {
                Text(DoseText.missedGuidance)
            }
            if dose.state.isDeclared, operation == nil, dose.eventID != nil {
                Section {
                    Button("Corregir este registro") { correcting = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("action-correct")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.Colors.bg)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $correcting) { CorrectionForm(dose: dose) }
        .sheet(isPresented: $earlierForm) { EarlierDoseForm(dose: dose) }
    }
}

struct StockSummary: View {
    let account: InventoryProjection
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saldo confirmado: \(ExactQuantity.withUnit(account.balance, unit: account.unit))")
                .accessibilityIdentifier("stock-confirmed")
            if let estimate = StockEstimate.estimated(account: account, doses: model.snapshot.doses, operations: model.snapshot.operations) {
                Text("Estimado con registros pendientes: \(ExactQuantity.withUnit(estimate, unit: account.unit))")
                    .foregroundStyle(Semantic.muted)
                    .accessibilityIdentifier("stock-estimated")
            }
            if let uncovered = account.firstUncoveredAt.flatMap(Instant.parse) {
                Text("Según la agenda, el saldo no alcanza desde: \(DoseText.instant(uncovered))")
            }
            if (ExactQuantity.parse(account.balance) ?? 0) < 0 {
                Text("El saldo es negativo. Conviene revisar el conteo físico con tu cuidador.")
            }
        }
    }
}

/// Registro de «Me lo tomé» con una hora anterior elegida por la persona.
private struct EarlierDoseForm: View {
    let dose: Dose
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var occurredAt = Date.now

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Hora de la toma", selection: $occurredAt, in: ...Date.now)
                Button {
                    let chosen = occurredAt
                    Task {
                        await model.declare(.taken, dose: dose, occurredAt: chosen)
                        dismiss()
                    }
                } label: {
                    ActionLabel(text: "Guardar con esta hora")
                }
                .largeAction(prominent: true)
            }
            .navigationTitle(DoseText.declaration(.taken))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}

struct CorrectionForm: View {
    let dose: Dose
    var patient: String? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var declaration: Declaration = .skipped
    @State private var occurredAt = Date.now
    @State private var reason = ""

    private var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("El registro correcto es") {
                    Picker("Registro", selection: $declaration) {
                        ForEach(Declaration.allCases) { Text(patient == nil ? DoseText.declaration($0) : FamilyText.declaration($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("correction-declaration")
                    if declaration.consumes {
                        DatePicker("Hora de la toma", selection: $occurredAt, in: ...Date.now)
                    }
                }
                Section("Motivo") {
                    TextField("Explica brevemente la corrección", text: $reason, axis: .vertical)
                        .accessibilityIdentifier("correction-reason")
                }
                Section {
                    Button {
                        let chosen = occurredAt
                        let value = declaration
                        let why = trimmedReason
                        Task {
                            await model.correct(dose: dose, to: value, occurredAt: value.consumes ? chosen : nil, reason: why, patient: patient)
                            dismiss()
                        }
                    } label: {
                        ActionLabel(text: "Guardar corrección")
                    }
                    .largeAction(prominent: true)
                    .disabled(trimmedReason.isEmpty || trimmedReason.count > 1000)
                    .accessibilityIdentifier("correction-save")
                } footer: {
                    Text("El registro anterior se conserva en el historial. Si cambia el consumo, el inventario se ajusta con un movimiento compensatorio.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Corregir registro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}

/// Una operación que el servidor no aceptó queda aquí hasta que la persona decida.
struct ConflictResolution: View {
    var caregiver = false
    let operation: PendingOperation
    let dose: Dose
    @Environment(AppModel.self) private var model
    @State private var reason = ""

    private var serverState: (text: String, icon: String, tone: StatusTone) {
        DoseText.state(dose.state, scheduledAt: dose.scheduledInstant, now: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tu registro: \(caregiver ? FamilyText.declaration(operation.declaration) : DoseText.declaration(operation.declaration))")
            StatusBadge(text: "En el servidor: \(serverState.text)", systemImage: serverState.icon, tone: serverState.tone)
                .accessibilityIdentifier("conflict-server-state")
            if dose.state.isDeclared {
                if dose.state != operation.declaration.asState {
                    TextField("Motivo para corregir", text: $reason, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("conflict-reason")
                    Button {
                        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await model.convertToCorrection(operation, dose: dose, reason: why) }
                    } label: {
                        ActionLabel(text: "Guardar mi registro como corrección")
                    }
                    .largeAction(prominent: true)
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("conflict-correct")
                }
            } else {
                Button {
                    Task { await model.redeclare(operation, dose: dose, occurredAt: operation.occurredAt.flatMap(Instant.parse)) }
                } label: {
                    ActionLabel(text: "Volver a enviar mi registro")
                }
                .largeAction(prominent: true)
                .accessibilityIdentifier("conflict-resend")
            }
            Button {
                Task { await model.discard(operation) }
            } label: {
                ActionLabel(text: "Descartar mi registro y conservar el del servidor")
            }
            .largeAction()
            .accessibilityIdentifier("conflict-discard")
        }
        .buttonStyle(.bordered)
    }
}
