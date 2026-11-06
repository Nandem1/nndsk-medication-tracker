import SwiftUI
import UIKit

/// La familia de la persona: quién está, con qué rol, y cómo entrar o salir.
struct FamilyView: View {
    var incomingToken: String?
    @Environment(AppModel.self) private var model
    @State private var removing: (family: Family, member: FamilyMember)?
    @State private var error: String?

    var body: some View {
        ScrollViewReader { proxy in
        List {
            Section { Text("Quienes están en la familia cuidan juntos. Cada paciente se une una vez y ve siempre quién tiene acceso.") }
            // Quien aún no tiene familia, como un paciente invitado, viene a unirse: va primero.
            let alone = model.families?.isEmpty == true || incomingToken != nil
            if alone { JoinFamilySection(incomingToken: incomingToken, proxy: proxy) }
            if let families = model.families {
                if families.isEmpty { CreateFamilySection() }
                ForEach(families) { family in familySection(family) }
            } else {
                Section { Label("Conéctate para ver tu familia.", systemImage: "wifi.slash").foregroundStyle(Semantic.muted) }
            }
            if !alone { JoinFamilySection(incomingToken: incomingToken, proxy: proxy) }
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Semantic.danger) } }
        }
        }
        .navigationTitle("Familia")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.syncNow() }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { target in
            Button(target.member.you ? "Salir de la familia" : "Quitar", role: .destructive) {
                Task {
                    do { try await model.removeMember(family: target.family.id, user: target.member.userID); error = nil }
                    catch { self.error = (error as? APIError)?.message ?? APIError.server.message }
                }
            }
        } message: { target in
            Text(target.member.you
                 ? (target.member.role == .patient ? "Nadie de la familia podrá seguir viendo tu información." : "Dejarás de ver a los pacientes de la familia.")
                 : "Dejará de ver y de ser visto por la familia.")
        }
    }

    private var removalTitle: String {
        guard let removing else { return "" }
        return removing.member.you ? "¿Salir de \(removing.family.name)?" : "¿Quitar a \(removing.member.name)?"
    }

    @ViewBuilder private func familySection(_ family: Family) -> some View {
        Section {
            ForEach(family.members.filter { $0.role == .patient }) { member in row(member, family: family) }
            if !family.members.contains(where: { $0.role == .patient }) { Text("Todavía no hay pacientes. Invita a quien toma los medicamentos.").foregroundStyle(Semantic.muted) }
            ForEach(family.members.filter { $0.role != .patient }) { member in row(member, family: family) }
            if family.role == .admin {
                NavigationLink { InviteView(family: family) } label: { Label("Invitar a la familia", systemImage: "person.badge.plus") }
                    .frame(minHeight: 44).accessibilityIdentifier("open-invite")
            } else {
                Text("Sólo quien administra puede invitar o quitar personas.").font(.footnote).foregroundStyle(Semantic.muted)
            }
            if let me = family.members.first(where: \.you) {
                Button("Salir de la familia", role: .destructive) { removing = (family, me) }.frame(minHeight: 44).accessibilityIdentifier("leave-family")
            }
        } header: {
            Text(family.name)
        } footer: {
            Text("\(family.members.count == 1 ? "1 persona" : "\(family.members.count) personas") · Tu rol: \(family.role.label)")
        }
    }

    private func row(_ member: FamilyMember, family: Family) -> some View {
        MemberRow(member: member)
            .swipeActions {
                if family.role == .admin, !member.you {
                    Button("Quitar", role: .destructive) { removing = (family, member) }
                }
            }
            .accessibilityIdentifier("member-\(member.name)")
    }
}

struct MemberRow: View {
    let member: FamilyMember
    var body: some View {
        HStack(spacing: 12) {
            Text(FamilyText.initials(member.displayName))
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Tokens.Colors.surfaceRaised))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.you ? "\(member.name) (tú)" : member.name).font(.headline)
                Text(member.role.label).font(.subheadline).foregroundStyle(Semantic.muted)
            }
            Spacer()
            if member.isNew() { StatusBadge(text: "Nuevo", systemImage: "sparkles", tone: .taken) }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

private struct CreateFamilySection: View {
    @Environment(AppModel.self) private var model
    @State private var name = "Mi familia"
    @State private var operation = UUID().uuidString.lowercased()
    @State private var working = false
    @State private var error: String?
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        Section {
            TextField("Nombre de la familia", text: $name).accessibilityIdentifier("family-name")
                .onChange(of: name) { operation = UUID().uuidString.lowercased() }
            Button { Task { await create() } } label: { ActionLabel(text: working ? "Creando…" : "Crear familia") }
                .largeAction(prominent: true).disabled(working || trimmed.isEmpty || trimmed.count > 60).accessibilityIdentifier("create-family")
            if let error { Label(error, systemImage: "info.circle").foregroundStyle(Semantic.muted) }
        } header: { Text("Crea tu familia") } footer: {
            Text("Después invita a tus padres como pacientes y a quienes te ayudan a cuidarlos. Basta una invitación por persona.")
        }
    }
    private func create() async {
        working = true
        defer { working = false }
        do { try await model.createFamily(name: trimmed, operation: operation); error = nil }
        catch { self.error = (error as? APIError)?.message ?? APIError.server.message }
    }
}

/// Ingreso con código o enlace. Pegar revisa de inmediato; un enlace abierto llega ya escrito.
private struct JoinFamilySection: View {
    var incomingToken: String?
    let proxy: ScrollViewProxy
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var preview: FamilyInvitationPreview?
    @State private var reviewedToken: String?
    /// Se conserva si se pierde la respuesta para que el reintento sea la misma operación.
    @State private var acceptOperationID = UUID().uuidString.lowercased()
    @State private var error: String?
    @State private var working = false
    private var cleanToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section("Unirse con un código") {
            TextField("Código de invitación", text: $token, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(working)
                .accessibilityIdentifier("invitation-token")
                .onChange(of: token) { preview = nil; reviewedToken = nil; acceptOperationID = UUID().uuidString.lowercased() }
            Button("Pegar código") {
                token = UIPasteboard.general.string ?? ""
                error = nil
                if cleanToken.isEmpty { error = "No encontramos un código copiado. Vuelve al mensaje, cópialo e intenta de nuevo." }
                else { Task { await review() } }
            }.disabled(working).frame(minHeight: 44).accessibilityIdentifier("invitation-paste")
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Semantic.danger).accessibilityIdentifier("consent-error") }
            if let preview {
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview.familyName).font(.title3.weight(.semibold))
                    Text("\(preview.inviterDisplayName ?? "Alguien") te invita como \(preview.role.label)").font(.headline)
                    if preview.role == .patient {
                        Text("Al unirte, quienes cuidan en esta familia, y quienes se unan después, podrán ver tu agenda y tu inventario. Verás siempre quiénes son y podrás salir cuando quieras.")
                    }
                    if let hint = preview.patientNameHint { Text("Nombre sugerido: \(hint)") }
                    Text("Vence: \(Instant.parse(preview.expiresAt).map(DoseText.instant) ?? preview.expiresAt)").font(.footnote)
                }.accessibilityIdentifier("invitation-preview")
                ForEach(preview.members) { MemberRow(member: $0) }
                Button { Task { await accept() } } label: { ActionLabel(text: "Unirme a la familia") }
                    .largeAction(prominent: true).disabled(working).accessibilityIdentifier("invitation-accept")
                    .id("invitation-accept")
            } else {
                Button { Task { await review() } } label: { ActionLabel(text: "Revisar invitación") }
                    .largeAction().disabled(working || cleanToken.isEmpty).accessibilityIdentifier("invitation-review")
            }
        }
        // La revisión deja «Unirme» bajo la lista de miembros: se muestra sin que la persona lo busque.
        .onChange(of: preview != nil) { _, reviewed in
            guard reviewed else { return }
            Task { @MainActor in withAnimation { proxy.scrollTo("invitation-accept", anchor: .center) } }
        }
        .task(id: incomingToken) {
            guard let incomingToken, !incomingToken.isEmpty else { return }
            token = incomingToken
            await review()
        }
    }

    private func review() async {
        working = true
        defer { working = false }
        error = nil
        do {
            let candidate = cleanToken
            let result = try await model.preview(invitation: candidate)
            guard candidate == cleanToken else { return }
            reviewedToken = candidate
            preview = result
        } catch { self.error = message(error) }
    }

    private func accept() async {
        working = true
        defer { working = false }
        error = nil
        do {
            guard let reviewedToken else { return }
            try await model.accept(invitation: reviewedToken, operationID: acceptOperationID)
            token = ""
            preview = nil
            model.pendingJoinToken = nil
        } catch { self.error = message(error) }
    }

    private func message(_ error: Error) -> String {
        switch error as? APIError {
        case .denied, .conflict, .invalid: "El código no es válido, ya se usó o venció."
        case let known?: known.message
        case nil: APIError.server.message
        }
    }
}
