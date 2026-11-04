import SwiftUI

struct CaregiverDoseSummary: View {
    let dose: Dose
    let snapshot: LocalSnapshot
    let now: Date
    var body: some View {
        let treatment = snapshot.treatments.first { $0.id == dose.treatmentID }
        let operation = snapshot.operations.first { $0.doseID == dose.id }
        let state = operation.map(DoseText.operation) ?? DoseText.state(dose.state, scheduledAt: dose.scheduledInstant, now: now)
        VStack(alignment: .leading, spacing: 8) {
            Text(treatment?.name ?? "Medicamento").font(.headline)
            if let treatment { Text(treatment.strengthLabel) }
            Text("\(dose.localTime.prefix(5)) · \(ExactQuantity.withUnit(dose.quantity, unit: treatment?.unit ?? "other"))")
            StatusBadge(text: state.text, systemImage: state.icon, tone: state.tone)
        }.padding(.vertical, 4)
    }
}

struct CaregiverDoseDetail: View {
    let patient: String
    let doseID: String
    @Environment(AppModel.self) private var model
    @State private var late = false
    @State private var correction = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let snapshot = model.patientSnapshot(patient), let dose = snapshot.doses.first(where: { $0.id == doseID }) {
                let operation = snapshot.operations.first { $0.doseID == doseID }
                List {
                    Section(snapshot.access?.name ?? "Paciente sin nombre") {
                        CaregiverDoseSummary(dose: dose, snapshot: snapshot, now: context.date)
                    }
                    if model.permits("doses", patient: patient) {
                        if let operation, operation.status != .pending {
                            Section("Por revisar") { ConflictResolution(caregiver: true, operation: operation, dose: dose) }
                        } else if operation == nil && dose.scheduledInstant <= context.date {
                            if dose.state.isDeclared, dose.eventID != nil {
                                Button("Corregir este registro") { correction = true }.frame(minHeight: 44).accessibilityIdentifier("caregiver-correct")
                            } else if !dose.state.isDeclared {
                                Section("Registrar declaración") {
                                    ForEach(Declaration.allCases) { value in
                                        Button {
                                            if value == .takenLate { late = true }
                                            else { Task { await model.declare(value, dose: dose, patient: patient) } }
                                        } label: { ActionLabel(text: FamilyText.declaration(value)) }
                                            .largeAction(prominent: value == .taken).accessibilityIdentifier("caregiver-action-\(value.rawValue)")
                                    }
                                }
                            }
                        }
                    } else { Label("Tu acceso permite sólo mirar", systemImage: "eye") }
                    if let treatment = snapshot.treatments.first(where: { $0.id == dose.treatmentID }), !treatment.instructions.isEmpty {
                        Section("Instrucciones registradas") { Text(treatment.instructions) }
                    }
                    Section { Text(FamilyText.missedGuidance) }
                }
                .sheet(isPresented: $late) { LateDoseForm(dose: dose, patient: patient) }
                .sheet(isPresented: $correction) { CorrectionForm(dose: dose, patient: patient) }
                .refreshable { await model.syncNow() }
            } else { ContentUnavailableView("Dosis no disponible", systemImage: "calendar.badge.exclamationmark") }
        }.navigationTitle("Detalle de la toma").navigationBarTitleDisplayMode(.inline)
    }
}
