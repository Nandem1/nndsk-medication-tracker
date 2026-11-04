import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Group {
                if let profile = model.profile, profile.profileComplete == false {
                    ProfileEditor(patient: profile.userID, name: profile.displayName ?? "", version: profile.profileVersion ?? 1, onboarding: true)
                } else {
                    UsePreferenceView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar sesión") { confirmSignOut = true }
                        .accessibilityIdentifier("onboarding-sign-out")
                }
            }
            .confirmationDialog("¿Cerrar sesión?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Cerrar sesión y borrar datos locales", role: .destructive) { Task { await model.signOut() } }
            } message: {
                Text("Se borrarán los datos de este dispositivo y los \(model.allOperations.count) registros pendientes de sincronizar.")
            }
        }
    }
}

struct UsePreferenceView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Form {
            Section {
                Button { Task { await model.setUse(caregiver: false) } } label: {
                    ActionLabel(text: "Tomo mis medicamentos")
                }.largeAction().accessibilityIdentifier("use-patient")
                Button { Task { await model.setUse(caregiver: true) } } label: {
                    ActionLabel(text: "Cuido a alguien")
                }.largeAction().accessibilityIdentifier("use-caregiver")
            } footer: {
                Text("Puedes cambiar esta elección en Ajustes. Para ver a otra persona necesitas su autorización.")
            }
        }.navigationTitle("¿Cómo usarás la app?")
    }
}

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section("Tu cuenta") {
                Text(model.profile?.displayName ?? "Sin nombre")
                Text(model.email).textSelection(.enabled)
                if let profile = model.profile {
                    NavigationLink("Cambiar nombre") {
                        ProfileEditor(patient: profile.userID, name: profile.displayName ?? "", version: profile.profileVersion ?? 1)
                    }
                }
            }
            Section("Cómo usas la app") {
                Picker("Uso", selection: Binding(get: { model.caregiverPreference ?? false }, set: { value in Task { await model.setUse(caregiver: value) } })) {
                    Text("Tomo mis medicamentos").tag(false)
                    Text("Cuido a alguien").tag(true)
                }.pickerStyle(.inline).labelsHidden().accessibilityIdentifier("profile-use")
            }
        }.navigationTitle("Mi perfil")
    }
}

struct ProfileEditor: View {
    let patient: String
    @State private var version: Int
    var onboarding = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var operation = UUID().uuidString.lowercased()
    @State private var submittedName: String?
    @State private var working = false
    @State private var error: String?
    @State private var errorKind: APIError?
    @State private var canReview = false

    init(patient: String, name: String, version: Int, onboarding: Bool = false) {
        self.patient = patient
        _version = State(initialValue: version)
        self.onboarding = onboarding
        _name = State(initialValue: name)
    }
    private var rejected: Bool { errorKind == .invalid || errorKind == .denied || errorKind == .conflict }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmed.isEmpty && trimmed.count <= 60 && !trimmed.contains(where: \.isNewline) }

    var body: some View {
        Form {
            Section("Nombre visible") {
                TextField("Tu nombre", text: $name).textContentType(.name).accessibilityIdentifier("profile-name")
                    .disabled(submittedName != nil)
                Text("Este nombre será el mismo para todas las personas que tengan acceso.").font(.footnote)
            }
            if let error {
                Section {
                    Label(error, systemImage: rejected ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(rejected ? Semantic.danger : Semantic.muted)
                }
            }
            Section {
                Button { Task { await save() } } label: { ActionLabel(text: working ? "Guardando…" : "Guardar nombre") }
                    .largeAction(prominent: true).disabled(working || !valid || canReview).accessibilityIdentifier("profile-save")
                if canReview {
                    Button("Recargar nombre para revisarlo") { Task { await reloadForReview() } }
                        .frame(minHeight: 44).disabled(working).accessibilityIdentifier("profile-reload")
                    Text("Al recargar verás el nombre actual y podrás preparar un cambio nuevo.").font(.footnote)
                } else if submittedName != nil, !working {
                    Text("Si no llegó la respuesta, vuelve a guardar para comprobar el mismo cambio.").font(.footnote)
                }
            }
        }.navigationTitle(onboarding ? "¿Cómo te llamas?" : "Cambiar nombre")
    }
    private func reloadForReview() async {
        working = true
        defer { working = false }
        await model.syncNow()
        guard model.phase == .signedIn else { return }
        if let problem = model.syncProblem {
            errorKind = problem
            error = problem.message
            return
        }
        if patient == model.profile?.userID, let profile = model.profile, let currentVersion = profile.profileVersion {
            name = profile.displayName ?? ""
            version = currentVersion
        } else if let access = model.patientSnapshot(patient)?.access {
            name = access.displayName ?? ""
            version = access.profileVersion
        } else {
            errorKind = .denied
            error = APIError.denied.message
            return
        }
        submittedName = nil
        operation = UUID().uuidString.lowercased()
        error = nil
        errorKind = nil
        canReview = false
    }

    private func save() async {
        submittedName = submittedName ?? trimmed
        working = true
        defer { working = false }
        do {
            try await model.updateProfile(patient: patient, name: submittedName ?? trimmed, version: version, operation: operation)
            if !onboarding { dismiss() }
        } catch {
            errorKind = error as? APIError ?? .server
            self.error = errorKind?.message
            canReview = errorKind == .invalid || errorKind == .conflict
            if errorKind == .conflict {
                self.error = "El nombre cambió en otro dispositivo. Recarga el nombre actual para revisarlo antes de preparar otro cambio."
            }
        }
    }
}
