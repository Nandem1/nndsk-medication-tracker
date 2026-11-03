import SwiftUI
import UIKit

/// Colores semánticos con contraste de texto de al menos 4.5:1 en modo claro y oscuro.
/// Los del sistema (verde y naranja) no lo alcanzan sobre blanco.
/// Cada estado se acompaña siempre de texto e icono.
enum Semantic {
    static let success = adaptive(light: (0.08, 0.42, 0.18), dark: (0.45, 0.86, 0.55))
    static let warning = adaptive(light: (0.60, 0.30, 0.00), dark: (1.00, 0.72, 0.35))
    static let danger = adaptive(light: (0.72, 0.07, 0.10), dark: (1.00, 0.55, 0.53))
    /// Fondo de la acción principal, con texto blanco en ambos modos.
    static let action = adaptive(light: (0.00, 0.32, 0.72), dark: (0.04, 0.38, 0.82))
    static let muted = adaptive(light: (0.32, 0.32, 0.35), dark: (0.78, 0.78, 0.80))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
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
struct LargeActionStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).tint(Semantic.action).modifier(LargeActionShape())
        } else {
            // El azul del sistema sobre gris no alcanza el contraste mínimo.
            content.buttonStyle(.bordered).tint(.primary).modifier(LargeActionShape())
        }
    }
}

private struct LargeActionShape: ViewModifier {
    func body(content: Content) -> some View {
        content.controlSize(.large).buttonBorderShape(.roundedRectangle).font(.body.weight(.semibold))
    }
}

extension View {
    func largeAction(prominent: Bool = false) -> some View {
        modifier(LargeActionStyle(prominent: prominent))
    }
}

struct ActionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
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
