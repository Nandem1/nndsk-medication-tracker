import SwiftUI
import UIKit

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
        let plan = TodayPlan(doses: model.snapshot.doses, operations: model.snapshot.operations, now: now)
        return List {
            Text(longDate(now: now))
                .font(Tokens.Typography.patientBody)
                .foregroundStyle(Tokens.Colors.textMuted)
                .plainTodayRow()
                .accessibilityIdentifier("today-date")
            SyncBanner()
            if plan.total > 0 {
                TodayProgress(registered: plan.registeredCount, total: plan.total)
                    .plainTodayRow()
            }
            if !plan.review.isEmpty {
                Section {
                    ForEach(plan.review) { DoseRow(dose: $0, now: now) }
                } header: {
                    TodayHeader(text: "Por revisar")
                }
            }
            if let current = plan.current {
                NowCard(dose: current, now: now)
                    .listRowBackground(Tokens.Colors.surface)
                    .listRowSeparator(.hidden)
            } else if plan.total == 0 {
                Text(model.isSyncing ? "Cargando tu agenda…" : "No hay tomas programadas para hoy.")
                    .font(Tokens.Typography.patientBody)
                    .plainTodayRow()
                    .accessibilityIdentifier("today-empty")
            } else if plan.later.isEmpty, plan.overdue.isEmpty {
                Text("No quedan tomas por registrar hoy.")
                    .font(Tokens.Typography.patientBody)
                    .plainTodayRow()
                    .accessibilityIdentifier("today-done")
            }
            if !plan.later.isEmpty {
                Section {
                    ForEach(plan.later) { DoseRow(dose: $0, now: now) }
                } header: {
                    TodayHeader(text: "Más tarde")
                }
            }
            if !plan.overdue.isEmpty {
                Section {
                    ForEach(plan.overdue) { DoseRow(dose: $0, now: now) }
                } header: {
                    TodayHeader(text: "Pasaron sin registrar")
                } footer: {
                    Text("Abre una toma para registrar lo que ocurrió. Esta app no indica tomarla ahora.")
                        .font(.footnote)
                        .foregroundStyle(Semantic.muted)
                }
            }
            if !plan.registered.isEmpty {
                Section {
                    ForEach(plan.registered) { DoseRow(dose: $0, now: now) }
                } header: {
                    TodayHeader(text: "Ya registradas")
                }
            }
            ReminderPrompt()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.Colors.bg)
        .refreshable { await model.syncNow() }
    }

    private func longDate(now: Date) -> String {
        let zone = model.snapshot.doses.first.flatMap { TimeZone(identifier: $0.timezone) } ?? .current
        return now.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "es_CL"), timeZone: zone))
    }
}

private extension View {
    func plainTodayRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Tokens.Space.xs, leading: 0, bottom: Tokens.Space.xs, trailing: 0))
            .listRowSeparator(.hidden)
    }
}

private struct TodayHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Tokens.Typography.patientLabel)
            .foregroundStyle(Tokens.Colors.text)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Cuenta registros, no tomas: una omisión también suma. Sin rachas ni metas.
private struct TodayProgress: View {
    let registered: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            Text("\(registered) de \(total) registradas")
                .font(Tokens.Typography.patientLabel)
                .foregroundStyle(Tokens.Colors.text)
            ProgressView(value: Double(registered), total: Double(max(total, 1)))
                .tint(Tokens.Colors.action)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-progress")
    }
}

private struct ReminderPrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch model.reminders.permission {
        case .notDetermined:
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                Text("Activa los recordatorios para recibir avisos en este teléfono.")
                Button {
                    Task { await model.requestReminderPermission() }
                } label: {
                    ActionLabel(text: "Activar recordatorios")
                }
                .largeAction()
                .accessibilityIdentifier("enable-reminders")
            }
        case .denied:
            VStack(alignment: .leading, spacing: Tokens.Space.sm) {
                StatusBadge(text: "Recordatorios desactivados", systemImage: "bell.slash", tone: .unconfirmed)
                Text("Este teléfono no te avisará de tus tomas. Puedes activarlos en los ajustes del teléfono.")
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    ActionLabel(text: "Abrir ajustes del teléfono")
                }
                .largeAction()
                .accessibilityIdentifier("open-system-settings")
            }
        default:
            EmptyView()
        }
    }
}

/// La toma que falta registrar, con las tres declaraciones a la vista.
private struct NowCard: View {
    let dose: Dose
    let now: Date
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.md) {
            Text(dose.scheduledInstant <= now ? "Ahora toca" : "Próxima toma")
                .font(Tokens.Typography.patientLabel)
                .foregroundStyle(Tokens.Colors.textMuted)
                .accessibilityAddTraits(.isHeader)
            NavigationLink(value: dose.id) {
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(DoseText.time(dose))
                        .font(Tokens.Typography.patientDisplay)
                        .monospacedDigit()
                    DoseSummary(dose: dose, now: now, showsTime: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dose-\(model.treatment(for: dose)?.name ?? dose.id)")
            DoseActions(dose: dose, now: now)
        }
        .padding(.vertical, Tokens.Space.sm)
    }
}

/// Fila de al menos 64 pt que abre el detalle; crece con Dynamic Type.
private struct DoseRow: View {
    let dose: Dose
    let now: Date
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationLink(value: dose.id) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.md) {
                Text(DoseText.time(dose))
                    .font(Tokens.Typography.patientLabel)
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    Text(model.treatment(for: dose)?.name ?? "Medicamento")
                        .font(Tokens.Typography.patientLabel)
                    DoseStatus(dose: dose, now: now)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Tokens.Size.patientAction)
        }
        .listRowBackground(Tokens.Colors.surface)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dose-\(model.treatment(for: dose)?.name ?? dose.id)")
    }
}

struct DoseSummary: View {
    let dose: Dose
    let now: Date
    var showsTime = true
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Text(model.treatment(for: dose)?.name ?? "Medicamento")
                .font(Tokens.Typography.patientTitle)
            if let strength = model.treatment(for: dose)?.strengthLabel, !strength.isEmpty {
                Text(strength).font(Tokens.Typography.patientBody).foregroundStyle(Semantic.muted)
            }
            if showsTime {
                Text(DoseText.time(dose)).font(Tokens.Typography.patientBody)
            }
            Text(ExactQuantity.withUnit(dose.quantity, unit: model.treatment(for: dose)?.unit ?? "other"))
                .font(Tokens.Typography.patientBody)
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
                StatusBadge(text: status.text, systemImage: status.icon, tone: status.tone)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dose-status")
        } else {
            let status = DoseText.state(dose.state, scheduledAt: dose.scheduledInstant, now: now)
            StatusBadge(text: status.text, systemImage: status.icon, tone: status.tone)
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
                    .font(Tokens.Typography.patientLabel)
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

/// Pide la hora efectiva. El botón muestra la hora que se guardará y nunca admite una futura.
struct LateDoseForm: View {
    let dose: Dose
    var patient: String? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var occurredAt = LateTime.floorToMinute(.now)
    @State private var showsPicker = false

    private var zone: TimeZone { TimeZone(identifier: dose.timezone) ?? .current }
    private var time: String { LateTime.label(occurredAt, timezone: dose.timezone) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Tokens.Space.lg) {
                    Text(patient == nil ? "¿A qué hora lo tomaste?" : "¿A qué hora se lo tomó?")
                        .font(Tokens.Typography.patientBody)
                    VStack(spacing: Tokens.Space.xs) {
                        Text(time)
                            .font(Tokens.Typography.patientDisplay)
                            .monospacedDigit()
                            .accessibilityLabel("Hora de la toma: \(time)")
                            .accessibilityIdentifier("late-time")
                        Text(occurredAt.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: Locale(identifier: "es_CL"), timeZone: zone)))
                            .font(Tokens.Typography.patientLabel)
                            .foregroundStyle(Semantic.muted)
                        if dose.timezone != TimeZone.current.identifier {
                            Text("Hora de \(dose.timezone)").font(.footnote).foregroundStyle(Semantic.muted)
                        }
                        if LateTime.isRepeated(occurredAt, timezone: dose.timezone) {
                            Text("Esta hora ocurrió dos veces por el cambio de horario. Usa −5 min o +5 min para elegir la correcta.")
                                .font(.footnote)
                                .foregroundStyle(Semantic.muted)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("late-repeated")
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        HStack(spacing: Tokens.Space.sm) {
                            Button {
                                occurredAt = LateTime.stepped(occurredAt, minutes: -5, now: .now)
                            } label: {
                                ActionLabel(text: "−5 min")
                            }
                            .largeAction()
                            .accessibilityLabel("Restar 5 minutos")
                            .accessibilityIdentifier("late-minus")
                            Button {
                                occurredAt = LateTime.stepped(occurredAt, minutes: 5, now: .now)
                            } label: {
                                ActionLabel(text: "+5 min")
                            }
                            .largeAction()
                            .disabled(!LateTime.canAdvance(occurredAt, now: context.date))
                            .accessibilityLabel("Sumar 5 minutos")
                            .accessibilityIdentifier("late-plus")
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Tokens.Space.sm) { shortcuts }
                        VStack(spacing: Tokens.Space.sm) { shortcuts }
                    }
                    DisclosureGroup("Otra fecha u hora", isExpanded: $showsPicker) {
                        DatePicker("Hora de la toma", selection: $occurredAt, in: ...Date.now)
                            .environment(\.timeZone, zone)
                            .accessibilityIdentifier("late-picker")
                    }
                    .font(Tokens.Typography.patientLabel)
                    Button {
                        let chosen = occurredAt
                        Task {
                            await model.declare(.takenLate, dose: dose, occurredAt: chosen, patient: patient)
                            dismiss()
                        }
                    } label: {
                        ActionLabel(text: "Guardar con las \(time)")
                    }
                    .largeAction(prominent: true)
                    .accessibilityIdentifier("late-save")
                    Text(patient == nil ? DoseText.missedGuidance : FamilyText.missedGuidance)
                        .font(Tokens.Typography.patientLabel.weight(.regular))
                        .foregroundStyle(Semantic.muted)
                }
                .padding(Tokens.Space.lg)
            }
            .background(Tokens.Colors.bg)
            .navigationTitle(patient == nil ? DoseText.declaration(.takenLate) : FamilyText.declaration(.takenLate))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var shortcuts: some View {
        shortcut("Recién", minutes: 0, id: "late-now")
        shortcut("Hace 30 min", minutes: 30, id: "late-30")
        shortcut("Hace 1 hora", minutes: 60, id: "late-60")
    }

    private func shortcut(_ text: String, minutes: Int, id: String) -> some View {
        Button {
            occurredAt = LateTime.ago(minutes: minutes, now: .now)
        } label: {
            Text(text)
                .padding(.horizontal, Tokens.Space.sm)
                .frame(maxWidth: .infinity, minHeight: Tokens.Size.minTouchIos)
        }
        .largeAction()
        .accessibilityIdentifier(id)
    }
}
