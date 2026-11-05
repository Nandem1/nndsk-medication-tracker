import SwiftUI

/// Sólo el propio paciente decide. Un cuidador nunca recibe esta tarjeta por otra persona.
struct PendingPoolCard: View {
    let pool: PendingPool
    @Environment(AppModel.self) private var model
    @State private var accept = UUID().uuidString.lowercased()
    @State private var decline = UUID().uuidString.lowercased()
    @State private var working = false
    @State private var error: String?
    var body: some View {
        Section {
            Text(pool.text).accessibilityIdentifier("pool-proposal")
            if let error { Label(error, systemImage: "info.circle").foregroundStyle(Semantic.muted) }
            Button("Aceptar") { decide(true) }.frame(minHeight: 44).disabled(working).accessibilityIdentifier("pool-accept")
            Button("Ahora no") { decide(false) }.frame(minHeight: 44).disabled(working).accessibilityIdentifier("pool-decline")
        } header: { Text("Inventario compartido") }
    }
    private func decide(_ value: Bool) {
        working = true
        Task {
            defer { working = false }
            do { try await model.decidePool(id: pool.id, accept: value, operation: value ? accept : decline); error = nil }
            catch { self.error = (error as? APIError)?.message ?? APIError.server.message }
        }
    }
}

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
    var body: some View {
        Group {
            if let pool = account.pool, pool.active {
                Label("Inventario compartido con \(pool.others())", systemImage: "person.2").accessibilityIdentifier("pool-shared")
                Text("El saldo es común: suma lo que registra cada persona. Si recién empezaron a compartir, conviene hacer un conteo físico.").font(.footnote).foregroundStyle(Semantic.muted)
                if canEdit {
                    Button("Dejar de compartir") { leaving = true }.frame(minHeight: 44).disabled(working).accessibilityIdentifier("pool-leave")
                        .confirmationDialog("Dejar de compartir", isPresented: $leaving, titleVisibility: .visible) {
                            Button("Confirmar", role: .destructive) { leave(pool) }
                        } message: { Text("El saldo se queda con \(pool.others()). Esta cuenta quedará en 0: después registra el stock que tengas.") }
                }
            } else if let pool = account.pool {
                Label("Esperando a \(pool.others(status: "pending"))", systemImage: "person.2").accessibilityIdentifier("pool-waiting")
                Text("Cada paciente decide por sí mismo. Mientras tanto, los saldos siguen separados.").font(.footnote).foregroundStyle(Semantic.muted)
                if canEdit { Button("Retirar esta cuenta de la propuesta") { leave(pool) }.frame(minHeight: 44).disabled(working).accessibilityIdentifier("pool-withdraw") }
            } else if propose && canEdit {
                if let candidates {
                    if candidates.isEmpty { Text("No hay otra persona con el mismo medicamento, concentración, forma y unidad.") }
                    else { Text("Si usan físicamente la misma caja, pueden compartir el saldo. Cada paciente debe aceptar.").font(.footnote).foregroundStyle(Semantic.muted) }
                    ForEach(candidates) { candidate in
                        Button("Compartir con \(candidate.name ?? "Paciente sin nombre")") { share(candidate) }.frame(minHeight: 44).disabled(working).accessibilityIdentifier("pool-candidate")
                    }
                } else {
                    Button("Compartir con…") { load() }.frame(minHeight: 44).disabled(working).accessibilityIdentifier("pool-propose")
                }
            }
            if let error { Label(error, systemImage: "info.circle").foregroundStyle(Semantic.muted) }
        }
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
    private func share(_ candidate: PoolCandidate) { run { try await model.proposePool(accounts: [account.id, candidate.accountID], operation: proposeOperation) } }
    private func leave(_ pool: InventoryPool) { run { try await model.leavePool(id: pool.id, account: account.id, operation: leaveOperation) } }
}
