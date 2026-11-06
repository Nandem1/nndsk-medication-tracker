import SwiftUI

struct SharedInventoryRows: View {
    let account: InventoryProjection
    let canEdit: Bool
    let propose: Bool
    @Environment(AppModel.self) private var model
    @State private var candidates: [PoolCandidate]?
    @State private var leaving = false
    @State private var working = false
    @State private var error: String?
    @State private var leaveOperation = UUID().uuidString.lowercased()
    @State private var proposeOperation = UUID().uuidString.lowercased()
    @State private var partner: PoolCandidate?
    @State private var counted = ""
    var body: some View {
        Group {
            if let pool = account.pool {
                Label("Misma caja que \(pool.others())", systemImage: "person.2").accessibilityIdentifier("pool-shared")
                Text("El saldo es común: suma lo que registra cada persona.").font(.footnote).foregroundStyle(Semantic.muted)
                if canEdit {
                    Button("Dejar de compartir") { leaving = true }.frame(minHeight: 44).disabled(working).accessibilityIdentifier("pool-leave")
                        .confirmationDialog("Dejar de compartir", isPresented: $leaving, titleVisibility: .visible) {
                            Button("Confirmar", role: .destructive) { leave(pool) }
                        } message: { Text("El saldo se queda con \(pool.others()). Esta cuenta quedará en 0: después registra el stock que tengas.") }
                }
            } else if propose && canEdit {
                if let candidates {
                    if candidates.isEmpty { Text("No hay otra persona con el mismo medicamento, concentración, forma y unidad.") }
                    else { Text("Si usan físicamente la misma caja, el saldo será uno solo.").font(.footnote).foregroundStyle(Semantic.muted) }
                    ForEach(candidates) { candidate in
                        Button("Misma caja que \(candidate.name ?? "Paciente sin nombre")") { counted = ""; partner = candidate }.frame(minHeight: 44).disabled(working).accessibilityIdentifier("pool-candidate")
                    }
                } else {
                    Button("¿Usan la misma caja?") { load() }.frame(minHeight: 44).disabled(working).accessibilityIdentifier("pool-propose")
                }
            }
            if let error { Label(error, systemImage: "info.circle").foregroundStyle(Semantic.muted) }
        }
        // Sumar dos saldos de una misma caja la contaría dos veces: el saldo común parte de lo contado.
        .alert("Misma caja que \(partner?.name ?? "otra persona")", isPresented: Binding(get: { partner != nil }, set: { if !$0 { partner = nil } })) {
            TextField("Cantidad en la caja", text: $counted).keyboardType(.decimalPad).accessibilityIdentifier("pool-count")
            Button("Compartir la caja") { if let partner { share(partner) } }.disabled(normalizedCount == nil)
            Button("Volver", role: .cancel) {}
        } message: { Text("¿Cuántos \(ExactQuantity.label(account.unit)) hay en la caja? El saldo común partirá de lo que cuentes.") }
    }
    private var normalizedCount: String? {
        let value = counted.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        return value.wholeMatch(of: /[0-9]{1,9}(\.[0-9]{1,3})?/) != nil ? value : nil
    }
    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do { try await work(); error = nil }
            catch { self.error = (error as? APIError)?.message ?? APIError.server.message }
        }
    }
    private func load() { run { candidates = try await model.poolCandidates(account: account.id) } }
    private func share(_ candidate: PoolCandidate) {
        guard let quantity = normalizedCount else { return }
        run { try await model.sharePool(accounts: [account.id, candidate.accountID], counted: account.id, quantity: quantity, operation: proposeOperation) }
    }
    private func leave(_ pool: InventoryPool) { run { try await model.leavePool(id: pool.id, account: account.id, operation: leaveOperation) } }
}
