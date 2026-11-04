import SwiftUI

struct InviteView: View {
    @Environment(AppModel.self) private var model
    @State private var hint = ""
    @State private var preset = InvitationPreset.administer
    @State private var invitation: CreatedInvitation?
    @State private var working = false
    @State private var error: String?
    @State private var rejection = false

    var body: some View {
        Form {
            if let invitation {
                Section("Código de invitación") {
                    Text(invitation.token).font(.body.monospaced()).textSelection(.enabled).accessibilityIdentifier("created-invitation-code")
                    Text("Vence en 24 horas. Comparte este código ahora; no se volverá a mostrar al cerrar esta pantalla.")
                    ShareLink(item: FamilyText.invitation(invitation.token)) { Label("Compartir", systemImage: "square.and.arrow.up") }
                        .frame(minHeight: 44).accessibilityIdentifier("share-invitation")
                }
                Button("Crear otra invitación") { self.invitation = nil }.frame(minHeight: 44)
            } else {
                Section("¿Cómo se llama?") {
                    TextField("Nombre del paciente, opcional", text: $hint).accessibilityIdentifier("invite-name")
                    Text("Por ejemplo, Mamá. Se sugiere sólo si la persona todavía no tiene nombre.").font(.footnote)
                }
                Section("Qué podrás hacer") {
                    Picker("Permisos", selection: $preset) {
                        ForEach(InvitationPreset.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.inline).accessibilityIdentifier("invite-preset")
                    ForEach(preset.scopes, id: \.self) { Text(DoseText.scope($0)) }
                }
                Section {
                    Button { Task { await create() } } label: { ActionLabel(text: working ? "Creando…" : "Crear invitación") }
                        .largeAction(prominent: true).disabled(working || hint.count > 60 || hint.contains(where: \.isNewline)).accessibilityIdentifier("invite-create")
                }
            }
            if let error { Section { Label(error, systemImage: rejection ? "exclamationmark.triangle" : "info.circle").foregroundStyle(rejection ? Semantic.danger : Semantic.muted) } }
        }.navigationTitle("Invitar a alguien")
    }
    private func create() async {
        working = true
        error = nil
        defer { working = false }
        do { invitation = try await model.createInvitation(preset: preset, hint: hint.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { rejection = [APIError.denied, .conflict, .invalid].contains(where: { $0 == error as? APIError }); self.error = (error as? APIError)?.message ?? APIError.server.message }
    }
}
