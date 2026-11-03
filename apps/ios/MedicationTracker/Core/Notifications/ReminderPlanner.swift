import Foundation

struct PlannedReminder: Sendable, Equatable {
    let doseID: String
    let fireAt: Date

    /// La identidad incluye el instante: si la pauta cambia la hora, la solicitud antigua queda obsoleta.
    var identifier: String { "\(ReminderPlanner.prefix)\(doseID).\(Int(fireAt.timeIntervalSince1970))" }
}

enum ReminderPlanner {
    static let prefix = "dose."
    /// iOS conserva 64 solicitudes pendientes por app. Se deja margen y se repone en cada sincronización.
    static let limit = 60

    static func plan(doses: [Dose], operations: [PendingOperation], now: Date, limit: Int = limit) -> [PlannedReminder] {
        let queued = Set(operations.map(\.doseID))
        return doses
            .filter { !$0.state.isDeclared && !queued.contains($0.id) && $0.scheduledInstant > now }
            .sorted { ($0.scheduledInstant, $0.id) < ($1.scheduledInstant, $1.id) }
            .prefix(limit)
            .map { PlannedReminder(doseID: $0.id, fireAt: $0.scheduledInstant) }
    }

    static func reconcile(pending: Set<String>, plan: [PlannedReminder]) -> (remove: [String], add: [PlannedReminder]) {
        let wanted = Set(plan.map(\.identifier))
        return (
            pending.filter { $0.hasPrefix(prefix) && !wanted.contains($0) }.sorted(),
            plan.filter { !pending.contains($0.identifier) }
        )
    }
}
