import Foundation

/// Pasado este plazo una dosis deja de presentarse como «Ahora toca», para no sugerir tomarla.
/// Es una decisión de presentación, no clínica: sigue sin confirmar y se puede registrar.
let currentWindow: TimeInterval = 4 * 3600

/// Reparte las dosis de la pantalla Hoy. Sólo presenta: no cambia estados ni cola.
struct TodayPlan: Equatable {
    /// Exigen una decisión, también si la dosis no es de hoy.
    let review: [Dose]
    let current: Dose?
    let later: [Dose]
    let overdue: [Dose]
    let registered: [Dose]
    let total: Int

    /// Toda declaración cuenta, incluida la omisión y la guardada sin enviar.
    /// Un conflicto sólo cuenta si el servidor ya tiene una declaración de hoy.
    let registeredCount: Int

    init(doses: [Dose], operations: [PendingOperation], now: Date) {
        let byDose = Dictionary(operations.map { ($0.doseID, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = doses.sorted { ($0.scheduledInstant.timeIntervalSince1970, $0.id) < ($1.scheduledInstant.timeIntervalSince1970, $1.id) }
        let today = sorted.filter { $0.localDate == LocalDay.today(in: $0.timezone, now: now) }
        let needsReview: (Dose) -> Bool = { byDose[$0.id].map { $0.status != .pending } ?? false }
        review = sorted.filter(needsReview)
        let rest = today.filter { !needsReview($0) }
        registered = rest.filter { $0.state.isDeclared || byDose[$0.id] != nil }
        let open = rest.filter { !$0.state.isDeclared && byDose[$0.id] == nil }
        overdue = open.filter { $0.scheduledInstant < now.addingTimeInterval(-currentWindow) }
        let active = open.filter { $0.scheduledInstant >= now.addingTimeInterval(-currentWindow) }
        current = active.first
        later = Array(active.dropFirst())
        total = today.count
        registeredCount = registered.count + today.filter { needsReview($0) && $0.state.isDeclared }.count
    }
}

/// Reglas de la hoja «Me lo tomé tarde». La hora nunca queda en el futuro.
enum LateTime {
    static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    static func stepped(_ value: Date, minutes: Int, now: Date) -> Date {
        min(value.addingTimeInterval(Double(minutes) * 60), floorToMinute(now))
    }

    static func canAdvance(_ value: Date, now: Date) -> Bool {
        value < floorToMinute(now)
    }

    static func ago(minutes: Int, now: Date) -> Date {
        floorToMinute(now).addingTimeInterval(Double(-minutes) * 60)
    }

    static func label(_ date: Date, timezone: String) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: TimeZone(identifier: timezone) ?? .current,
            calendar: Calendar(identifier: .gregorian)
        ))
    }

    /// La misma hora local ocurre dos veces cuando se atrasa el reloj.
    static func isRepeated(_ date: Date, timezone: String) -> Bool {
        let text = label(date, timezone: timezone)
        return [-3600.0, 3600.0].contains { label(date.addingTimeInterval($0), timezone: timezone) == text }
    }
}
