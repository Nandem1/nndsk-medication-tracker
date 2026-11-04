import SwiftUI

struct PatientsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.patientPath) {
            List {
                SyncBanner()
                if model.patients.isEmpty {
                    ContentUnavailableView("Aún no sigues a nadie", systemImage: "person.2", description: Text("Invita a alguien y espera su autorización para ver su agenda."))
                }
                ForEach(model.accesses.filter { model.patients[$0.patientID] != nil }) { access in
                    if let snapshot = model.patients[access.patientID] {
                        NavigationLink(value: access.patientID) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(access.name).font(.headline)
                                if let report = snapshot.report {
                                    Text("\(report.summary.confirmed) de \(report.summary.evaluable) registradas")
                                    Text("\(report.summary.unconfirmed) sin confirmar")
                                    Text("Período: \(DoseText.day(report.from)) a \(DoseText.day(report.to)), fin no incluido").font(.footnote)
                                } else { Text("Resumen sin actualizar") }
                                Text("\(snapshot.inventory.filter { $0.lowStock == true }.count) reposiciones por revisar")
                                if let date = snapshot.lastSyncAt { Text("Datos guardados de: \(DoseText.instant(date))").font(.footnote).foregroundStyle(Semantic.muted) }
                            }.padding(.vertical, 6)
                        }.accessibilityIdentifier("patient-\(access.name)")
                    }
                }
                Section { NavigationLink("Invitar a alguien") { InviteView() }.accessibilityIdentifier("open-invite") }
                Text(DoseText.selfReported).font(.footnote).foregroundStyle(Semantic.muted)
            }.navigationTitle("Pacientes")
                .navigationDestination(for: String.self) { CaregiverPatientView(patient: $0) }
                .refreshable { await model.syncNow() }
        }
    }
}

struct CaregiverPatientView: View {
    let patient: String
    @Environment(AppModel.self) private var model
    @State private var section = "Hoy"
    @State private var leave = false
    @State private var error: String?
    var body: some View {
        Group {
            if let snapshot = model.patientSnapshot(patient), let access = snapshot.access {
                VStack(spacing: 0) {
                    Picker("Sección", selection: $section) {
                        ForEach(["Hoy", "Historial", "Inventario"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).padding().accessibilityIdentifier("patient-section")
                    if section == "Inventario" { CaregiverInventoryView(patient: patient) }
                    else { CaregiverAgendaView(patient: patient, history: section == "Historial") }
                }
                .navigationTitle(access.name)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if model.permits("treatments", patient: patient) {
                                NavigationLink("Cambiar nombre") { ProfileEditor(patient: patient, name: access.displayName ?? "", version: access.profileVersion) }
                            }
                            Button("Dejar de seguir", role: .destructive) { leave = true }
                        } label: { Label("Opciones del paciente", systemImage: "ellipsis.circle") }
                        .accessibilityIdentifier("patient-menu")
                    }
                }
            } else {
                ContentUnavailableView("Acceso no disponible", systemImage: "person.crop.circle.badge.xmark", description: Text("Actualiza Pacientes para revisar tus accesos."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("¿Dejar de seguir a esta persona?", isPresented: $leave, titleVisibility: .visible) {
            Button("Dejar de seguir", role: .destructive) {
                Task { do { try await model.leave(patient: patient) } catch { self.error = (error as? APIError)?.message ?? APIError.server.message } }
            }
        } message: { Text("Perderás el acceso a su información. Necesitarás otra invitación y su autorización para volver a verla.") }
        .alert("No se pudo completar", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Entendido", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}

struct CaregiverAgendaView: View {
    let patient: String
    let history: Bool
    @Environment(AppModel.self) private var model
    @State private var daysBack = SyncEngine.daysBack
    @State private var loading = false
    @State private var error: String?
    @State private var rejected = false
    @State private var lateDose: Dose?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let snapshot = model.patientSnapshot(patient) {
                List {
                    SyncBanner()
                    if !model.permits("doses", patient: patient) { Label("Tu acceso permite sólo mirar", systemImage: "eye").accessibilityIdentifier("caregiver-read-only") }
                    if history {
                        let days = Dictionary(grouping: snapshot.doses.filter { $0.scheduledInstant <= context.date }, by: \.localDate).sorted { $0.key > $1.key }
                        if days.isEmpty { Text("Todavía no hay tomas anteriores.") }
                        ForEach(days, id: \.key) { day, doses in
                            Section(DoseText.day(day)) { rows(doses, snapshot: snapshot, now: context.date) }
                        }
                        Section {
                            if let error { Label(error, systemImage: rejected ? "exclamationmark.triangle" : "info.circle").foregroundStyle(rejected ? Semantic.danger : Semantic.muted) }
                            Button(loading ? "Cargando…" : "Ver 30 días anteriores") { Task { await loadMore(snapshot) } }
                                .frame(minHeight: 44).disabled(loading).accessibilityIdentifier("caregiver-history-more")
                        }
                    } else {
                        let plan = TodayPlan(doses: snapshot.doses, operations: snapshot.operations, now: context.date)
                        if plan.total == 0 { Text("No hay tomas programadas para hoy.") }
                        if !plan.review.isEmpty { Section("Por revisar") { rows(plan.review, snapshot: snapshot, now: context.date) } }
                        if let current = plan.current {
                            Section(current.scheduledInstant <= context.date ? "Falta registrar" : "Próxima toma") {
                                rows([current], snapshot: snapshot, now: context.date)
                                if model.permits("doses", patient: patient),
                                   current.scheduledInstant <= context.date,
                                   !current.state.isDeclared,
                                   !snapshot.operations.contains(where: { $0.doseID == current.id }) {
                                    ForEach(Declaration.allCases) { declaration in
                                        Button {
                                            if declaration == .takenLate { lateDose = current }
                                            else { Task { await model.declare(declaration, dose: current, patient: patient) } }
                                        } label: {
                                            ActionLabel(text: FamilyText.declaration(declaration))
                                        }
                                        .largeAction(prominent: declaration == .taken)
                                        .accessibilityIdentifier("caregiver-current-\(declaration.rawValue)")
                                    }
                                }
                            }
                        }
                        if !plan.later.isEmpty { Section("Más tarde") { rows(plan.later, snapshot: snapshot, now: context.date) } }
                        if !plan.overdue.isEmpty { Section("Pasaron sin registrar") { rows(plan.overdue, snapshot: snapshot, now: context.date) } }
                        if !plan.registered.isEmpty { Section("Ya registradas") { rows(plan.registered, snapshot: snapshot, now: context.date) } }
                    }
                    Text(DoseText.selfReported).font(.footnote).foregroundStyle(Semantic.muted)
                }
                .refreshable { await model.syncNow() }
                .sheet(item: $lateDose) { dose in LateDoseForm(dose: dose, patient: patient) }
            }
        }
    }
    private func rows(_ doses: [Dose], snapshot: LocalSnapshot, now: Date) -> some View {
        ForEach(doses) { dose in
            NavigationLink { CaregiverDoseDetail(patient: patient, doseID: dose.id) } label: {
                CaregiverDoseSummary(dose: dose, snapshot: snapshot, now: now)
            }.accessibilityIdentifier("caregiver-dose-\(snapshot.treatments.first { $0.id == dose.treatmentID }?.name ?? "Medicamento")")
        }
    }
    private func loadMore(_ snapshot: LocalSnapshot) async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: snapshot.access?.timezone ?? "America/Santiago") ?? .current
        let today = calendar.startOfDay(for: .now)
        guard let from = calendar.date(byAdding: .day, value: -(daysBack + 30), to: today),
              let to = calendar.date(byAdding: .day, value: -daysBack, to: today) else { return }
        loading = true
        error = await model.loadHistory(from: from, to: to, patient: patient)
        rejected = error != nil && (model.syncProblem == .invalid || model.syncProblem == .denied || model.syncProblem == .conflict)
        if error == nil { daysBack += 30 }
        loading = false
    }
}
