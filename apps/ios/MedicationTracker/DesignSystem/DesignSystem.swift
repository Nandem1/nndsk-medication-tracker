import SwiftUI
import UIKit

/// Alias semánticos sobre los tokens generados de `packages/design-tokens`.
/// El contraste de cada par se comprueba al generar los tokens (≥ 4.5:1 en claro y oscuro).
/// Cada estado se acompaña siempre de texto e icono.
enum Semantic {
    static let success = Tokens.Colors.takenFg
    static let warning = Tokens.Colors.unconfirmedFg
    static let danger = Tokens.Colors.dangerFg
    /// Fondo de la acción principal (tinta). El texto usa `onAction`.
    static let action = Tokens.Colors.action
    static let onAction = Tokens.Colors.onAction
    static let muted = Tokens.Colors.textMuted
}

struct StatusBadge: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityElement(children: .combine)
    }
}

/// Botón ancho con área táctil holgada que crece con Dynamic Type.
/// Las tres declaraciones comparten alto y forma; sólo «Me lo tomé» va relleno.
struct LargeActionStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
        configuration.label
            .font(Tokens.Typography.patientLabel)
            .foregroundStyle(prominent ? Semantic.onAction : Tokens.Colors.text)
            .background {
                if prominent {
                    shape.fill(Semantic.action)
                } else {
                    shape.fill(Tokens.Colors.surface)
                    shape.strokeBorder(Tokens.Colors.action, lineWidth: Tokens.Size.borderWidth)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

extension View {
    func largeAction(prominent: Bool = false) -> some View {
        buttonStyle(LargeActionStyle(prominent: prominent))
    }
}

struct ActionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Tokens.Space.md)
            .frame(maxWidth: .infinity, minHeight: Tokens.Size.patientAction)
    }
}

enum DoseText {
    static func declaration(_ value: Declaration) -> String {
        switch value {
        case .taken: "Me lo tomé"
        case .takenLate: "Me lo tomé tarde"
        case .skipped: "No me lo tomé"
        }
    }

    static func state(_ state: DoseState, scheduledAt: Date, now: Date) -> (text: String, icon: String, color: Color) {
        switch state {
        case .taken: ("Tomada", "checkmark.circle.fill", Semantic.success)
        case .takenLate: ("Tomada tarde", "clock.badge.checkmark", Semantic.success)
        case .skipped: ("No tomada", "minus.circle", Semantic.muted)
        case .pending, .unconfirmed:
            // Sin confirmar se deriva del reloj: no es una omisión declarada.
            scheduledAt <= now ? ("Sin confirmar", "questionmark.circle", Semantic.warning) : ("Programada", "clock", Semantic.muted)
        }
    }

    static func operation(_ operation: PendingOperation) -> (text: String, icon: String, color: Color) {
        switch operation.status {
        case .pending: ("Pendiente de sincronizar", "arrow.triangle.2.circlepath", Semantic.warning)
        case .conflict: ("Necesita revisión: cambió en el servidor", "exclamationmark.triangle.fill", Semantic.danger)
        case .rejected: ("Necesita revisión: el servidor rechazó el registro", "exclamationmark.triangle.fill", Semantic.danger)
        case .denied: ("Necesita revisión: la dosis ya no está disponible", "exclamationmark.triangle.fill", Semantic.danger)
        }
    }

    static func time(_ dose: Dose) -> String {
        dose.timezone == TimeZone.current.identifier ? dose.localTime : "\(dose.localTime) (hora de \(dose.timezone))"
    }

    static func instant(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "es_CL")))
    }

    static func day(_ localDate: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = localDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return localDate }
        return date.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: .gmt).locale(Locale(identifier: "es_CL")))
    }

    static func scope(_ scope: String) -> String {
        switch scope {
        case "read": "Consultar información"
        case "treatments": "Administrar tratamientos"
        case "inventory": "Administrar inventario"
        case "doses": "Registrar y corregir declaraciones"
        default: scope
        }
    }

    static let selfReported = "Los registros son declaraciones tuyas o de tu cuidador. No demuestran que el medicamento se haya tomado."
    static let missedGuidance = "Si olvidaste una dosis o la tomaste tarde, sigue las instrucciones de tu profesional de salud o consulta a un profesional o farmacéutico. Esta app no indica cambiar ni compensar dosis."
    static let reliability = "Los recordatorios dependen del sistema, los permisos, la batería y el estado del teléfono. Pueden retrasarse o no llegar."
}

struct SyncBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let problem = model.syncProblem, problem != .unauthenticated {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wifi.exclamationmark").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.message)
                    if let last = model.snapshot.lastSyncAt {
                        Text("Datos guardados de: \(DoseText.instant(last))").font(.footnote).foregroundStyle(Semantic.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sync-banner")
        }
    }
}
