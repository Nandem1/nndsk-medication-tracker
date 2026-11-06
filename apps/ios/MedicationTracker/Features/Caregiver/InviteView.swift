import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct InviteView: View {
    let family: Family
    @Environment(AppModel.self) private var model
    @State private var hint = ""
    @State private var role = FamilyRole.patient
    @State private var invitation: CreatedInvitation?
    @State private var working = false
    @State private var error: String?
    @State private var rejection = false
    @State private var copied = false

    var body: some View {
        Form {
            if let invitation {
                Section {
                    if let image = QRCodeImage.make(FamilyText.link(invitation.token)) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 240).frame(maxWidth: .infinity)
                            .accessibilityLabel("QR para unirse a \(family.name)")
                            .accessibilityIdentifier("invitation-qr")
                    }
                } header: { Text("Invitación lista · \(role.label)") } footer: {
                    Text("Para configurar un teléfono en persona, abre la cámara del otro teléfono y escanea este código.")
                }
                Section {
                    ShareLink(item: FamilyText.invitation(invitation.token, family: family.name)) { ActionLabel(text: "Compartir invitación") }
                        .largeAction(prominent: true).accessibilityIdentifier("share-invitation")
                    Button(copied ? "Mensaje copiado" : "Copiar mensaje") {
                        UIPasteboard.general.string = FamilyText.invitation(invitation.token, family: family.name)
                        copied = true
                    }.frame(minHeight: 44).accessibilityIdentifier("copy-invitation")
                }
                Section("Qué sigue") {
                    Text("1. Envía el mensaje por WhatsApp u otro medio privado.")
                    Text("2. La persona toca el enlace, o pega el código en Ajustes › Familia.")
                    Text("3. Al unirse aparecerá en la familia, y los pacientes verán que se unió.")
                }
                Section("Código de invitación") {
                    Text(invitation.token).font(.body.monospaced()).textSelection(.enabled).accessibilityIdentifier("created-invitation-code")
                    Text("Vence en 7 días y sirve para una sola persona. No se vuelve a mostrar al cerrar esta pantalla.").font(.footnote)
                }
                Button("Invitar a otra persona") { self.invitation = nil; copied = false }.frame(minHeight: 44)
            } else {
                Section("¿Cómo participará?") {
                    Picker("Rol", selection: $role) {
                        ForEach(FamilyRole.allCases) { option in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                Text(option.summary).font(.footnote).foregroundStyle(Semantic.muted)
                            }.tag(option)
                        }
                    }.pickerStyle(.inline).labelsHidden().accessibilityIdentifier("invite-role")
                }
                if role == .patient {
                    Section("¿Cómo se llama?") {
                        TextField("Nombre del paciente, opcional", text: $hint).accessibilityIdentifier("invite-name")
                        Text("Por ejemplo, Mamá. Se sugiere sólo si la persona todavía no tiene nombre.").font(.footnote)
                    }
                }
                Section {
                    Button { Task { await create() } } label: { ActionLabel(text: working ? "Creando…" : "Crear invitación") }
                        .largeAction(prominent: true).disabled(working || hint.count > 60 || hint.contains(where: \.isNewline)).accessibilityIdentifier("invite-create")
                } footer: {
                    Text("Vence en 7 días y sirve para una sola persona.")
                }
            }
            if let error { Section { Label(error, systemImage: rejection ? "exclamationmark.triangle" : "info.circle").foregroundStyle(rejection ? Semantic.danger : Semantic.muted) } }
        }.navigationTitle("Invitar a \(family.name)")
    }
    private func create() async {
        working = true
        error = nil
        defer { working = false }
        do { invitation = try await model.invite(family: family.id, role: role, hint: hint.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { rejection = [APIError.denied, .conflict, .invalid].contains(where: { $0 == error as? APIError }); self.error = (error as? APIError)?.message ?? APIError.server.message }
    }
}

/// QR del enlace con Core Image: sin dependencias. Siempre negro sobre blanco para que lo lean las cámaras.
enum QRCodeImage {
    static func make(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
