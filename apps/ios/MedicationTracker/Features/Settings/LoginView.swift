import SwiftUI

struct LoginView: View {
    let notice: String?
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var working = false
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Registra tus tomas y revisa tu agenda con tu propia cuenta.")
                    if let notice {
                        Text(notice).accessibilityIdentifier("login-notice")
                    }
                }
                Section("Tu cuenta") {
                    TextField("Correo", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("login-email")
                    SecureField("Contraseña", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("login-password")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Semantic.danger)
                            .accessibilityIdentifier("login-error")
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        ActionLabel(text: working ? "Entrando…" : "Entrar")
                    }
                    .largeAction(prominent: true)
                    .disabled(working || email.isEmpty || password.isEmpty)
                    .accessibilityIdentifier("login-submit")
                    if model.phase == .expired || model.phase == .signedOut {
                        Button("Cerrar sesión y borrar datos locales", role: .destructive) { confirmClear = true }
                            .accessibilityIdentifier("login-clear-local")
                            .disabled(working)
                    }
                } footer: {
                    Text(DoseText.selfReported)
                }
            }
            .navigationTitle("Mis tomas")
            .confirmationDialog("Se borrarán los datos de este dispositivo y los registros pendientes de sincronizar.", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Cerrar y borrar", role: .destructive) { Task { await model.signOut() } }
            }
            .alert("Hay registros de otra cuenta", isPresented: Binding(get: { model.foreignPendingCount > 0 }, set: { _ in })) {
                Button("Volver", role: .cancel) { Task { await model.cancelForeignSignIn() } }
                Button("Descartar y continuar", role: .destructive) { Task { await model.discardForeignPendingAndContinue() } }
            } message: {
                Text("Este teléfono guarda \(model.foreignPendingCount) registro(s) sin sincronizar de otra cuenta. Vuelve para entrar con esa cuenta y sincronizarlos, o descártalos.")
            }
        }
    }

    private func submit() async {
        working = true
        error = await model.signIn(email: email, password: password)
        working = false
        password = ""
    }
}
