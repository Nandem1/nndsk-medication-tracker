import Foundation

/// Aritmética decimal exacta sobre las cadenas del contrato. Nunca pasa por Double.
enum ExactQuantity {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func parse(_ text: String) -> Decimal? {
        guard text.wholeMatch(of: /-?[0-9]+(\.[0-9]{1,3})?/) != nil else { return nil }
        return Decimal(string: text, locale: posix)
    }

    /// Formato es-CL conservando la cantidad exacta: "0.500" se muestra "0,5".
    static func display(_ text: String) -> String {
        var value = text
        if value.contains(".") {
            while value.hasSuffix("0") { value.removeLast() }
            if value.hasSuffix(".") { value.removeLast() }
        }
        return value.replacingOccurrences(of: ".", with: ",")
    }

    static func string(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: posix)
    }

    static func withUnit(_ text: String, unit: String) -> String {
        let number = display(text)
        return "\(number) \(label(unit, singular: number == "1"))"
    }

    static func label(_ unit: String, singular: Bool = false) -> String {
        switch unit {
        case "tablet": singular ? "comprimido" : "comprimidos"
        case "capsule": singular ? "cápsula" : "cápsulas"
        case "ml": "ml"
        case "dose": "dosis"
        default: singular ? "unidad" : "unidades"
        }
    }
}

enum StockEstimate {
    /// Saldo orientativo: el confirmado por el servidor más el efecto de las operaciones sin confirmar.
    /// Devuelve nil cuando no hay diferencia con el saldo confirmado.
    static func estimated(account: InventoryProjection, doses: [Dose], operations: [PendingOperation]) -> String? {
        guard var value = ExactQuantity.parse(account.balance) else { return nil }
        var changed = false
        for operation in operations where operation.status == .pending && operation.previousStateConsumes != operation.declaration.consumes {
            guard let dose = doses.first(where: { $0.id == operation.doseID }), dose.treatmentID == account.treatmentID,
                  let quantity = ExactQuantity.parse(dose.quantity) else { continue }
            value += operation.declaration.consumes ? -quantity : quantity
            changed = true
        }
        return changed ? ExactQuantity.string(value) : nil
    }
}
