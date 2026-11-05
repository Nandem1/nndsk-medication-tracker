import SwiftUI
import UIKit

struct InviteView: View {
    @Environment(AppModel.self) private var model
    @State private var hint = ""
    @State private var preset = InvitationPreset.administer
    @State private var invitation: CreatedInvitation?
    @State private var working = false
    @State private var error: String?
    @State private var rejection = false
    @State private var copied = false

    var body: some View {
        Form {
            if let invitation {
                Section("Invitación lista") {
                    ShareLink(item: FamilyText.invitation(invitation.token)) { ActionLabel(text: "Compartir invitación") }
                        .largeAction(prominent: true).accessibilityIdentifier("share-invitation")
                    Button(copied ? "Mensaje copiado" : "Copiar mensaje") {
                        UIPasteboard.general.string = FamilyText.invitation(invitation.token)
                        copied = true
                    }.frame(minHeight: 44).accessibilityIdentifier("copy-invitation")
                }
                Section("Qué sigue") {
                    Text("1. Envía el mensaje por WhatsApp u otro medio privado.")
                    Text("2. La persona abre la app, entra en Ajustes › Acceso de cuidadores y pega el código.")
                    Text("3. Cuando autorice, aparecerá en Pacientes.")
                }
                Section("Código de invitación") {
                    Text(invitation.token).font(.body.monospaced()).textSelection(.enabled).accessibilityIdentifier("created-invitation-code")
                    Text("Vence en 24 horas. Comparte este código ahora; no se volverá a mostrar al cerrar esta pantalla.").font(.footnote)
                }
                Button("Crear otra invitación") { self.invitation = nil; copied = false }.frame(minHeight: 44)
            } else {
                Section("¿Cómo se llama?") {
                    TextField("Nombre del paciente, opcional", text: $hint).accessibilityIdentifier("invite-name")
                    Text("Por ejemplo, Mamá. Se sugiere sólo si la persona todavía no tiene nombre.").font(.footnote)
                }
                Section("¿Qué podrás hacer?") {
                    Picker("Permisos", selection: $preset) {
                        ForEach(InvitationPreset.allCases) { option in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.rawValue)
                                Text(option.summary).font(.footnote).foregroundStyle(Semantic.muted)
                            }.tag(option)
                        }
                    }.pickerStyle(.inline).labelsHidden().accessibilityIdentifier("invite-preset")
                }
                Section {
                    Button { Task { await create() } } label: { ActionLabel(text: working ? "Creando…" : "Crear invitación") }
                        .largeAction(prominent: true).disabled(working || hint.count > 60 || hint.contains(where: \.isNewline)).accessibilityIdentifier("invite-create")
                } footer: {
                    Text("La persona revisará estos permisos antes de autorizarte.")
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
