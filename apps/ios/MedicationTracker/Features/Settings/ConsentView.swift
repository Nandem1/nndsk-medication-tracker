import SwiftUI

struct ConsentView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var preview: InvitationPreview?
    /// Se conserva si se pierde la respuesta para que el reintento sea la misma operación.
    @State private var acceptOperationID = UUID().uuidString.lowercased()
    @State private var error: String?
    @State private var working = false
    @State private var revoking: CaregiverLink?
    @FocusState private var tokenFocused: Bool

    private var cleanToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                Text("Tus datos de salud son tuyos. Un cuidador sólo puede verlos o editarlos si aceptas su invitación, y puedes revocar ese acceso cuando quieras.")
            }
            Section("Cuidadores con acceso") {
                if model.snapshot.links.isEmpty {
                    Text("Ningún cuidador tiene acceso.").accessibilityIdentifier("links-empty")
                }
                ForEach(model.snapshot.links) { link in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cuidador \(link.caregiverID.prefix(8))")
                            .font(.headline)
                            .accessibilityIdentifier("link-row")
                        ForEach(link.scopes, id: \.self) { Text(DoseText.scope($0)) }
                        Button("Revocar acceso", role: .destructive) { revoking = link }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("revoke-link")
                    }
                }
            }
            Section("Aceptar una invitación") {
                TextField("Código de invitación", text: $token, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($tokenFocused)
                    .accessibilityIdentifier("invitation-token")
                    .onChange(of: token) {
                        preview = nil
                        acceptOperationID = UUID().uuidString.lowercased()
                    }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Semantic.danger)
                        .accessibilityIdentifier("consent-error")
                }
                if let preview {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Este cuidador podrá:").font(.headline)
                        ForEach(preview.scopes, id: \.self) { Text(DoseText.scope($0)) }
                        Text("La invitación vence: \(Instant.parse(preview.expiresAt).map(DoseText.instant) ?? preview.expiresAt)")
                            .font(.footnote)
                    }
                    .accessibilityIdentifier("invitation-preview")
                    Button {
                        Task { await accept() }
                    } label: {
                        ActionLabel(text: "Autorizar a este cuidador")
                    }
                    .largeAction(prominent: true)
                    .disabled(working)
                    .accessibilityIdentifier("invitation-accept")
                } else {
                    Button {
                        Task { await review() }
                    } label: {
                        ActionLabel(text: "Revisar invitación")
                    }
                    .largeAction()
                    .disabled(working || cleanToken.isEmpty)
                    .accessibilityIdentifier("invitation-review")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Cuidadores")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.syncNow() }
        .confirmationDialog("¿Revocar el acceso de este cuidador?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible, presenting: revoking) { link in
            Button("Revocar acceso", role: .destructive) {
                Task { await revoke(link) }
            }
        } message: { _ in
            Text("Dejará de ver y editar tu información. Para volver a darle acceso necesitarás una invitación nueva.")
        }
    }

    private func review() async {
        tokenFocused = false
        working = true
        defer { working = false }
        error = nil
        do {
            preview = try await model.preview(invitation: cleanToken)
        } catch {
            self.error = message(error, invalid: "El código no es válido, ya se usó o venció.")
        }
    }

    private func accept() async {
        working = true
        defer { working = false }
        error = nil
        do {
            try await model.accept(invitation: cleanToken, operationID: acceptOperationID)
            token = ""
            preview = nil
        } catch {
            self.error = message(error, invalid: "El código no es válido, ya se usó o venció.")
        }
    }

    private func revoke(_ link: CaregiverLink) async {
        do {
            try await model.revoke(link)
        } catch {
            self.error = message(error, invalid: "No se pudo revocar el acceso.")
        }
    }

    private func message(_ error: Error, invalid: String) -> String {
        switch error as? APIError {
        case .denied, .conflict, .invalid: invalid
        case let known?: known.message
        case nil: APIError.server.message
        }
    }
}
