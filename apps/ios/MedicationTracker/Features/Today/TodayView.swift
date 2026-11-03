import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.todayPath) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                list(now: context.date)
            }
            .navigationTitle("Hoy")
            .navigationDestination(for: String.self) { id in
                DoseDetailView(doseID: id)
            }
        }
    }

    private func list(now: Date) -> some View {
        let doses = model.snapshot.doses.filter { $0.localDate == LocalDay.today(in: $0.timezone, now: now) }
        let next = doses.first { !$0.state.isDeclared && model.operation(for: $0) == nil }
        // Lo que exige una decisión va primero, también si la dosis no es de hoy.
        let unresolved = model.snapshot.doses.filter { model.operation(for: $0).map { $0.status != .pending } ?? false }
        return List {
            SyncBanner()
            if model.reminders.permission == .notDetermined {
                ReminderPrompt()
            }
            if !unresolved.isEmpty {
                Section("Por revisar") {
                    ForEach(unresolved) { DoseCard(dose: $0, now: now) }
                }
            }
            if let next {
                Section("Siguiente toma") {
                    DoseCard(dose: next, now: now)
                }
            }
            Section("Tomas de hoy") {
                if doses.isEmpty {
                    Text(model.isSyncing ? "Cargando tu agenda…" : "No hay tomas programadas para hoy.")
                        .accessibilityIdentifier("today-empty")
                }
                ForEach(doses.filter { dose in dose.id != next?.id && !unresolved.contains { $0.id == dose.id } }) { dose in
                    DoseCard(dose: dose, now: now)
                }
            }
        }
        .refreshable { await model.syncNow() }
    }
}

private struct ReminderPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activa los recordatorios para recibir avisos en este teléfono.")
            Button {
                Task { await model.requestReminderPermission() }
            } label: {
                ActionLabel(text: "Activar recordatorios")
            }
            .largeAction()
            .accessibilityIdentifier("enable-reminders")
        }
    }
}

struct DoseCard: View {
    let dose: Dose
    let now: Date
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: dose.id) {
                DoseSummary(dose: dose, now: now)
            }
            .accessibilityIdentifier("dose-\(treatmentName)")
            DoseActions(dose: dose, now: now)
        }
        .padding(.vertical, 4)
    }

    private var treatmentName: String { model.treatment(for: dose)?.name ?? dose.id }
}

struct DoseSummary: View {
    let dose: Dose
    let now: Date
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.treatment(for: dose)?.name ?? "Medicamento")
                .font(.title3.weight(.semibold))
            if let strength = model.treatment(for: dose)?.strengthLabel, !strength.isEmpty {
                Text(strength).foregroundStyle(Semantic.muted)
            }
            Text(DoseText.time(dose)).font(.title3)
            Text(ExactQuantity.withUnit(dose.quantity, unit: model.treatment(for: dose)?.unit ?? "other"))
            if dose.dstAdjusted {
                Text("Hora ajustada por el cambio de horario").font(.footnote).foregroundStyle(Semantic.muted)
            }
            DoseStatus(dose: dose, now: now)
        }
        .accessibilityElement(children: .combine)
    }
}

/// La operación local se muestra por sobre el estado del servidor, sin ocultar que falta confirmarla.
struct DoseStatus: View {
    let dose: Dose
    let now: Date
    @Environment(AppModel.self) private var model

    var body: some View {
        if let operation = model.operation(for: dose) {
            let status = DoseText.operation(operation)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tu registro: \(DoseText.declaration(operation.declaration))")
                StatusBadge(text: status.text, systemImage: status.icon, color: status.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dose-status")
        } else {
            let status = DoseText.state(dose.state, scheduledAt: dose.scheduledInstant, now: now)
            StatusBadge(text: status.text, systemImage: status.icon, color: status.color)
                .accessibilityIdentifier("dose-status")
        }
    }
}

struct DoseActions: View {
    let dose: Dose
    let now: Date
    @Environment(AppModel.self) private var model
    @State private var lateForm = false

    var body: some View {
        if model.operation(for: dose) == nil, !dose.state.isDeclared {
            if dose.scheduledInstant > now {
                Text("Podrás registrarla desde las \(dose.localTime).")
                    .font(.footnote)
                    .foregroundStyle(Semantic.muted)
            } else {
                VStack(spacing: 8) {
                    Button {
                        Task { await model.declare(.taken, dose: dose) }
                    } label: {
                        ActionLabel(text: DoseText.declaration(.taken))
                    }
                    .largeAction(prominent: true)
                    .accessibilityIdentifier("action-taken")
                    Button {
                        lateForm = true
                    } label: {
                        ActionLabel(text: DoseText.declaration(.takenLate))
                    }
                    .largeAction()
                    .accessibilityIdentifier("action-taken-late")
                    Button {
                        Task { await model.declare(.skipped, dose: dose) }
                    } label: {
                        ActionLabel(text: DoseText.declaration(.skipped))
                    }
                    .largeAction()
                    .accessibilityIdentifier("action-skipped")
                }
                .sheet(isPresented: $lateForm) {
                    LateDoseForm(dose: dose)
                }
            }
        }
    }
}

/// Pide la hora efectiva. Guardar exige confirmar la hora que se ve en pantalla.
struct LateDoseForm: View {
    let dose: Dose
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var occurredAt = Date.now

    var body: some View {
        NavigationStack {
            Form {
                Section("¿A qué hora lo tomaste?") {
                    DatePicker("Hora de la toma", selection: $occurredAt, in: ...Date.now)
                        .accessibilityIdentifier("late-time")
                }
                Section {
                    Button {
                        let chosen = occurredAt
                        Task {
                            await model.declare(.takenLate, dose: dose, occurredAt: chosen)
                            dismiss()
                        }
                    } label: {
                        ActionLabel(text: "Guardar con esta hora")
                    }
                    .largeAction(prominent: true)
                    .accessibilityIdentifier("late-save")
                } footer: {
                    Text(DoseText.missedGuidance)
                }
            }
            .navigationTitle(DoseText.declaration(.takenLate))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}
