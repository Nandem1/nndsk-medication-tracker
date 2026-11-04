// Generado por packages/design-tokens/build.mjs desde tokens.json. No editar a mano.
import SwiftUI
import UIKit

enum Tokens {
    enum Colors {
        /// Fondo de pantalla
        static let bg = adaptive(light: 0xF7F7F8, dark: 0x0F0F11)
        /// Tarjetas y paneles
        static let surface = adaptive(light: 0xFFFFFF, dark: 0x17171A)
        /// Superficie secundaria, iconos de medicamento, chips neutros
        static let surfaceRaised = adaptive(light: 0xF0F0F2, dark: 0x1E1E22)
        /// Divisores decorativos
        static let border = adaptive(light: 0xE4E4E7, dark: 0x26262B)
        /// Bordes de controles; no decorativos
        static let borderStrong = adaptive(light: 0x7C7C85, dark: 0x7C7C85)
        /// Texto principal
        static let text = adaptive(light: 0x17171A, dark: 0xEDEDF0)
        /// Texto secundario
        static let textMuted = adaptive(light: 0x5E5E66, dark: 0x9A9AA3)
        /// Fondo de la acción principal (tinta)
        static let action = adaptive(light: 0x17171A, dark: 0xEDEDF0)
        /// Texto sobre action
        static let onAction = adaptive(light: 0xFFFFFF, dark: 0x0F0F11)
        /// Enlaces, foco, selección y dato destacado
        static let accent = adaptive(light: 0x4338CA, dark: 0xA5A1FF)
        /// Relleno de selección
        static let accentFill = adaptive(light: 0x4338CA, dark: 0x5B54E8)
        /// Texto sobre accentFill
        static let onAccent = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF)
        /// Programada
        static let scheduledFg = adaptive(light: 0x47474E, dark: 0xC4C4CC)
        /// Programada
        static let scheduledBg = adaptive(light: 0xF0F0F2, dark: 0x26262B)
        /// Sin confirmar: derivado del reloj, no es omisión
        static let unconfirmedFg = adaptive(light: 0x8A4B00, dark: 0xFFB95C)
        /// Sin confirmar
        static let unconfirmedBg = adaptive(light: 0xFFF1D6, dark: 0x33240E)
        /// Declarada tomada
        static let takenFg = adaptive(light: 0x17663A, dark: 0x6EDB98)
        /// Declarada tomada
        static let takenBg = adaptive(light: 0xE3F4EA, dark: 0x10301D)
        /// Declarada tomada tarde; no penalizada
        static let takenLateFg = adaptive(light: 0x0F6874, dark: 0x5FD3E0)
        /// Declarada tomada tarde
        static let takenLateBg = adaptive(light: 0xE0F3F5, dark: 0x0D2A2E)
        /// Declarada omitida; neutra a propósito
        static let skippedFg = adaptive(light: 0x47474E, dark: 0xC4C4CC)
        /// Declarada omitida
        static let skippedBg = adaptive(light: 0xECECEF, dark: 0x26262B)
        /// Guardada localmente, falta enviar
        static let syncFg = adaptive(light: 0x3730A3, dark: 0xC7C4FF)
        /// Guardada localmente, falta enviar
        static let syncBg = adaptive(light: 0xEEEDFE, dark: 0x24224A)
        /// Conflicto o rechazo que exige decidir
        static let dangerFg = adaptive(light: 0xB42318, dark: 0xFF8A80)
        /// Conflicto o rechazo
        static let dangerBg = adaptive(light: 0xFDECEA, dark: 0x3A1512)
        /// Serie tomada
        static let chartTaken = adaptive(light: 0x2E9E5B, dark: 0x4CC37A)
        /// Serie tomada tarde
        static let chartTakenLate = adaptive(light: 0x0B6F96, dark: 0x8FE3EC)
        /// Serie omitida
        static let chartSkipped = adaptive(light: 0x8E8E98, dark: 0x7C7C85)
        /// Serie sin confirmar; dibujar además con trama
        static let chartUnconfirmed = adaptive(light: 0xB86E00, dark: 0xF0A23A)

        private static func adaptive(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(UIColor { traits in
                let value = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1
                )
            })
        }
    }

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let pill: CGFloat = 999
    }

    enum Size {
        static let minTouchIos: CGFloat = 44
        static let minTouchAndroid: CGFloat = 48
        static let patientAction: CGFloat = 64
        static let patientIcon: CGFloat = 64
        static let borderWidth: CGFloat = 2
    }

    enum Typography {
        /// Hora de la siguiente toma. Escala con Dynamic Type desde .largeTitle.
        static let patientDisplay = Font.system(.largeTitle, design: .default, weight: .heavy)
        /// Nombre del medicamento. Escala con Dynamic Type desde .title.
        static let patientTitle = Font.system(.title, design: .default, weight: .bold)
        /// Cantidad e instrucciones. Escala con Dynamic Type desde .title3.
        static let patientBody = Font.system(.title3, design: .default, weight: .regular)
        /// Etiquetas, estados y el mínimo de lectura. Escala con Dynamic Type desde .headline.
        static let patientLabel = Font.system(.headline, design: .default, weight: .semibold)
        /// Cifra de un KPI. Escala con Dynamic Type desde .largeTitle.
        static let caregiverMetric = Font.system(.largeTitle, design: .monospaced, weight: .medium)
        /// Encabezado de sección. Escala con Dynamic Type desde .title2.
        static let caregiverHeading = Font.system(.title2, design: .default, weight: .semibold)
        /// Texto denso del portal. Escala con Dynamic Type desde .subheadline.
        static let caregiverBody = Font.system(.subheadline, design: .default, weight: .regular)
        /// Denominadores, períodos y notas. Escala con Dynamic Type desde .footnote.
        static let caregiverCaption = Font.system(.footnote, design: .default, weight: .regular)
    }
}
