import XCTest

/// Requiere `make test-ios-e2e`. Nada aquí sustituye la prueba manual en iPhone físico.
final class PatientFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 25

    override func setUp() async throws {
        continueAfterFailure = false
        try await E2EBackend.setFault("online")
        await MainActor.run {
            app = XCUIApplication()
            // Cada prueba parte sin sesión ni datos de una ejecución anterior.
            app.launch()
            signOutIfNeeded()
        }
    }

    override func tearDown() async throws {
        try await E2EBackend.setFault("online")
    }

    // MARK: Flujo de la definición de terminado

    /// Cuidador crea → paciente recibe agenda → confirma offline → sincroniza → stock baja una sola vez.
    @MainActor
    func testCaregiverCreatesPatientConfirmsOfflineAndStockDropsOnce() async throws {
        let (caregiver, _, patientID, name) = try await prepareLinkedPatient()

        pullToRefreshToday(until: name)
        XCTAssertTrue(text("Sin confirmar").waitForExistence(timeout: timeout))
        attachScreenshot("hoy-sin-confirmar")

        // Sin conexión real: el proxy cierra el socket.
        try await E2EBackend.setFault("offline")
        tapFirst("action-taken")
        XCTAssertTrue(pendingBadge.waitForExistence(timeout: timeout), "La declaración offline debe verse como pendiente")
        attachScreenshot("hoy-pendiente-offline")

        // La cola sobrevive a cerrar la app, todavía sin conexión.
        app.terminate()
        app.launch()
        XCTAssertTrue(pendingBadge.waitForExistence(timeout: timeout), "La cola debe sobrevivir al reinicio")
        openDetail(name)
        XCTAssertTrue(text("Saldo confirmado: 10 comprimidos").waitForExistence(timeout: timeout))
        XCTAssertTrue(text("Estimado con registros pendientes: 9,5 comprimidos").waitForExistence(timeout: timeout))
        attachScreenshot("detalle-estimado-offline")
        app.navigationBars.buttons.firstMatch.tap()

        // Vuelve la red, pero se pierde la respuesta: la API aplica y el cliente no se entera.
        try await E2EBackend.setFault("lose-responses")
        pullToRefreshToday()
        let settled = await eventually { try await E2EBackend.inventory(caregiver, patient: patientID).first?.balance == "9.500" }
        XCTAssertTrue(settled)
        XCTAssertTrue(pendingBadge.waitForExistence(timeout: timeout), "Sin respuesta, el cliente no puede dar la operación por confirmada")

        // El reintento repite la misma operación.
        try await E2EBackend.setFault("online")
        pullToRefreshToday()
        XCTAssertTrue(text("Tomada").waitForExistence(timeout: timeout))
        XCTAssertFalse(pendingBadge.exists)
        openDetail(name)
        XCTAssertTrue(text("Saldo confirmado: 9,5 comprimidos").waitForExistence(timeout: timeout))
        attachScreenshot("detalle-sincronizado")

        // Verdad del servidor, leída con la cuenta del cuidador.
        let account = try await firstAccount(caregiver, patientID)
        XCTAssertEqual(account.balance, "9.500")
        let movements = try await E2EBackend.movements(caregiver, inventory: account.account_id)
        XCTAssertEqual(movements.filter { $0.reason == "consumption" }.count, 1, "Exactamente un consumo")
        XCTAssertEqual(movements.first { $0.reason == "consumption" }?.quantity_delta, "-0.500")
        let doses = try await E2EBackend.doses(caregiver, patient: patientID)
        XCTAssertEqual(doses.filter { $0.state == "taken" }.count, 1)
    }

    // MARK: Conflictos y corrección

    /// Otra persona registra la misma dosis mientras este teléfono está sin conexión.
    @MainActor
    func testOfflineConflictStaysVisibleUntilResolved() async throws {
        let (caregiver, _, patientID, name) = try await prepareLinkedPatient()
        pullToRefreshToday(until: name)

        try await E2EBackend.setFault("offline")
        tapFirst("action-skipped")
        XCTAssertTrue(pendingBadge.waitForExistence(timeout: timeout))

        let due = try await unconfirmedDose(caregiver, patientID)
        try await E2EBackend.declare(caregiver, dose: due, type: "taken")

        try await E2EBackend.setFault("online")
        pullToRefreshToday()
        let review = text("Necesita revisión")
        XCTAssertTrue(review.waitForExistence(timeout: timeout), "El 409 no puede perderse en silencio")

        // El consumo del cuidador sigue siendo el único: el registro local no tocó el stock.
        let before = try await firstAccount(caregiver, patientID)
        XCTAssertEqual(before.balance, "9.500")

        openDetail(name)
        XCTAssertTrue(text("En el servidor: Tomada").waitForExistence(timeout: timeout))
        attachScreenshot("conflicto-visible")
        let reason = app.textFields["conflict-reason"].firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: timeout))
        reason.tap()
        reason.typeText("Olvide que no la tome")
        app.buttons["conflict-correct"].firstMatch.tap()

        // La corrección compensa el consumo: el saldo vuelve y queda auditada.
        let settled = await eventually { try await E2EBackend.inventory(caregiver, patient: patientID).first?.balance == "10.000" }
        XCTAssertTrue(settled)
        let movements = try await E2EBackend.movements(caregiver, inventory: before.account_id)
        XCTAssertEqual(movements.filter { $0.reason == "consumption" }.count, 1)
        XCTAssertEqual(movements.filter { $0.reason == "reversal" }.count, 1)
        XCTAssertTrue(text("No tomada").waitForExistence(timeout: timeout))
    }

    /// «Me lo tomé tarde» descuenta una vez y «No me lo tomé» no descuenta; la corrección queda en el ledger.
    @MainActor
    func testLateDeclarationAndCorrectionFromHistory() async throws {
        let (caregiver, _, patientID, name) = try await prepareLinkedPatient()
        pullToRefreshToday(until: name)

        tapFirst("action-taken-late")
        let save = app.buttons["late-save"]
        XCTAssertTrue(save.waitForExistence(timeout: timeout))
        // Hora futura imposible: +5 sigue desactivado hasta retroceder.
        XCTAssertFalse(app.buttons["late-plus"].isEnabled)
        XCTAssertTrue(save.label.hasPrefix("Guardar con las "))
        let initialLabel = save.label
        app.buttons["late-minus"].tap()
        XCTAssertNotEqual(save.label, initialLabel)
        XCTAssertTrue(app.buttons["late-plus"].isEnabled)
        app.buttons["late-60"].tap()
        attachScreenshot("hoja-tarde")
        app.buttons["late-now"].tap()
        save.tap()
        XCTAssertTrue(text("Tomada tarde").waitForExistence(timeout: timeout))
        let account = try await firstAccount(caregiver, patientID)
        XCTAssertEqual(account.balance, "9.500")

        openTab("Historial")
        let row = app.buttons["history-\(name)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        attachScreenshot("historial")
        row.tap()
        let correct = app.buttons["action-correct"]
        XCTAssertTrue(scrollTo(correct))
        correct.tap()
        let skippedOption = app.buttons["No me lo tomé"].firstMatch
        XCTAssertTrue(skippedOption.waitForExistence(timeout: timeout))
        skippedOption.tap()
        let reason = app.textFields["correction-reason"]
        XCTAssertTrue(reason.waitForExistence(timeout: timeout))
        reason.tap()
        reason.typeText("Registro equivocado")
        app.buttons["correction-save"].tap()

        let settled = await eventually { try await E2EBackend.inventory(caregiver, patient: patientID).first?.balance == "10.000" }
        XCTAssertTrue(settled)
        let movements = try await E2EBackend.movements(caregiver, inventory: account.account_id)
        XCTAssertEqual(movements.filter { $0.reason == "consumption" }.count, 1)
        XCTAssertEqual(movements.filter { $0.reason == "reversal" }.count, 1)
        XCTAssertEqual(movements.count, 3, "Inicial, consumo y reversa: nada se borra")
    }

    // MARK: Consentimiento

    @MainActor
    func testPatientRevokesCaregiverAndBackendDeniesAccess() async throws {
        let (caregiver, _, patientID, _) = try await prepareLinkedPatient()
        openTab("Ajustes")
        tapScrolling("open-consent")
        tapScrolling("revoke-link")
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Quitar acceso", "revoke-link")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["links-empty"].waitForExistence(timeout: timeout))
        do {
            _ = try await E2EBackend.doses(caregiver, patient: patientID)
            XCTFail("El cuidador revocado no debe consultar la agenda")
        } catch {}
    }

    // MARK: Notificaciones

    /// Entrega real en el simulador: el aviso abre la dosis y no registra ninguna declaración.
    @MainActor
    func testLocalReminderIsDeliveredAndOpensTheDoseWithoutDeclaring() async throws {
        let (caregiver, _, patientID, name) = try await prepareLinkedPatient(futureMinutes: 2)
        pullToRefreshToday(until: name)
        allowNotifications()

        openTab("Ajustes")
        app.collectionViews.firstMatch.swipeDown()
        app.collectionViews.firstMatch.swipeDown()
        XCTAssertTrue(element("reminder-status", containing: "Recordatorios habilitados").waitForExistence(timeout: timeout))
        XCTAssertTrue(element("reminder-count", containing: "Recordatorios programados: 1").waitForExistence(timeout: timeout))

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Recordatorio de medicamento")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 200), "El aviso debe llegar a la hora prevista")
        XCTAssertFalse(banner.label.contains(name), "El aviso no muestra el nombre del medicamento")
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: timeout))
        XCTAssertTrue(app.navigationBars["Detalle de la toma"].waitForExistence(timeout: timeout))
        let doses = try await E2EBackend.doses(caregiver, patient: patientID)
        XCTAssertTrue(doses.allSatisfy { !["taken", "taken_late", "skipped"].contains($0.state) }, "Abrir el aviso no declara")
    }

    // MARK: Accesibilidad

    /// El texto más grande de accesibilidad no debe ocultar las tres acciones.
    @MainActor
    func testLargestDynamicTypeKeepsActionsReachable() async throws {
        let (_, _, _, name) = try await prepareLinkedPatient()
        pullToRefreshToday(until: name)
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        for id in ["action-taken", "action-taken-late", "action-skipped"] {
            let button = app.buttons[id].firstMatch
            XCTAssertTrue(scrollTo(button), "\(id) debe alcanzarse")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        attachScreenshot("hoy-texto-maximo")
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.tabBars.firstMatch.frame.minY
        let visible = CGRect(x: 0, y: top, width: app.frame.width, height: bottom - top)
        try app.performAccessibilityAudit(for: [.contrast, .dynamicType, .sufficientElementDescription, .hitRegion]) { issue in
            guard let element = issue.element else { return true }
            // Lo que pasa bajo las barras translúcidas del sistema se mide mezclado con ellas.
            // Todo elemento visible por completo se sigue exigiendo.
            let ignored = issue.auditType == .contrast && !visible.contains(element.frame)
            print("AUDIT ignored=\(ignored) \(issue.compactDescription) | \(element.label) \(element.frame)")
            return ignored
        }
    }

    // MARK: Ayudas

    private var pendingBadge: XCUIElement {
        text("Guardada, falta enviar")
    }

    /// Los resúmenes combinan sus textos en un solo elemento accesible.
    private func text(_ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func element(_ id: String, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", id, text)).firstMatch
    }

    @MainActor
    private func prepareLinkedPatient(futureMinutes: Int = 180) async throws -> (caregiver: E2EBackend.Account, patient: E2EBackend.Account, patientID: String, name: String) {
        let caregiver = try await E2EBackend.signUp("cuidador")
        let patient = try await E2EBackend.signUp("paciente")
        let patientID = try await E2EBackend.userID(patient)
        let token = try await E2EBackend.invite(caregiver: caregiver)

        signIn(patient)
        acceptInvitation(token)

        let name = "Sintetico \(UUID().uuidString.prefix(6))"
        try await E2EBackend.createTreatment(caregiver: caregiver, patient: patientID, name: name, futureMinutes: futureMinutes)
        openTab("Hoy")
        return (caregiver, patient, patientID, name)
    }

    @MainActor
    private func signIn(_ account: E2EBackend.Account) {
        let email = app.textFields["login-email"]
        XCTAssertTrue(email.waitForExistence(timeout: timeout))
        email.tap()
        email.typeText(account.email)
        let password = app.secureTextFields["login-password"]
        password.tap()
        password.typeText(E2EBackend.password)
        app.buttons["login-submit"].tap()
        let profile = app.textFields["profile-name"]
        if profile.waitForExistence(timeout: timeout) {
            dismissPasswordPrompt()
            focus(profile)
            profile.typeText("Paciente sintético")
            app.buttons["profile-save"].tap()
        }
        let patientUse = app.buttons["use-patient"]
        if patientUse.waitForExistence(timeout: timeout) {
            dismissPasswordPrompt()
            for _ in 0 ..< 6 {
                // El aviso de contraseña puede llegar tarde y se lleva el toque.
                dismissPasswordPrompt()
                tapAtFrame(patientUse)
                if app.tabBars.buttons["Hoy"].waitForExistence(timeout: 2) { break }
            }
        }
        XCTAssertTrue(app.tabBars.buttons["Hoy"].waitForExistence(timeout: timeout))
        // iOS ofrece guardar la contraseña: una persona también debe responder esa hoja.
        // Llega con retraso variable y bloquea toda la pantalla.
        let notNow = app.buttons["Ahora no"]
        if notNow.waitForExistence(timeout: 60) { notNow.tap() }
    }

    /// Tras cerrar el aviso de contraseña, XCTest informa un `isHittable` falso aunque UIKit ya entrega el toque.
    @MainActor
    private func tapAtFrame(_ element: XCUIElement) {
        let frame = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    /// El teclado visible comprueba el foco. Sólo se repite el toque que enfoca; nunca una mutación.
    @MainActor
    private func focus(_ element: XCUIElement) {
        for _ in 0 ..< 3 {
            dismissPasswordPrompt()
            tapAtFrame(element)
            if app.keyboards.firstMatch.waitForExistence(timeout: 2) { return }
        }
        XCTFail("El campo debe recibir foco antes de escribir")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// La hoja de contraseña puede absorber un toque: la pestaña se confirma seleccionada.
    @MainActor
    private func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: timeout))
        for _ in 0 ..< 6 {
            dismissPasswordPrompt()
            tab.tap()
            // El título de cada pestaña coincide con su nombre.
            if app.navigationBars[name].waitForExistence(timeout: 2) { return }
        }
        XCTFail("No se pudo abrir la pestaña \(name)")
    }

    @MainActor
    private func dismissPasswordPrompt() {
        let notNow = app.buttons["Ahora no"]
        if notNow.exists { notNow.tap() }
    }

    @MainActor
    private func signOutIfNeeded() {
        dismissPasswordPrompt()
        if app.buttons["onboarding-sign-out"].exists {
            app.buttons["onboarding-sign-out"].tap()
            app.buttons["Cerrar sesión y borrar datos locales"].tap()
            XCTAssertTrue(app.textFields["login-email"].waitForExistence(timeout: timeout))
        }
        guard app.tabBars.buttons["Ajustes"].waitForExistence(timeout: 5) else { return }
        openTab("Ajustes")
        tapScrolling("sign-out")
        let confirm = app.buttons["Cerrar sesión y borrar datos locales"]
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(app.textFields["login-email"].waitForExistence(timeout: timeout))
    }

    @MainActor
    private func acceptInvitation(_ token: String) {
        openTab("Ajustes")
        tapScrolling("open-consent")
        let field = app.textFields["invitation-token"]
        XCTAssertTrue(scrollTo(field))
        field.tap()
        field.typeText(token)
        app.buttons["invitation-review"].tap()
        XCTAssertTrue(app.buttons["invitation-accept"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitAbove(app.buttons["invitation-accept"], app.tabBars.firstMatch), "«Autorizar» no puede quedar bajo las pestañas")
        app.buttons["invitation-accept"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["link-row"].waitForExistence(timeout: timeout))
    }

    @MainActor
    private func waitAbove(_ element: XCUIElement, _ bar: XCUIElement) -> Bool {
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if element.frame.maxY <= bar.frame.minY { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        return false
    }

    @MainActor
    private func pullToRefreshToday(until name: String? = nil) {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            dismissPasswordPrompt()
            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: timeout))
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)), withVelocity: .slow, thenHoldForDuration: 0.5)
            guard let name else { return }
            if doseLink(name).waitForExistence(timeout: 4) { return }
        } while Date.now < deadline
        XCTFail("La dosis no llegó a la agenda")
    }

    private func doseLink(_ name: String) -> XCUIElement {
        app.buttons["dose-\(name)"].firstMatch
    }

    @MainActor
    private func openDetail(_ name: String) {
        let link = doseLink(name)
        XCTAssertTrue(link.waitForExistence(timeout: timeout))
        link.tap()
        XCTAssertTrue(app.navigationBars["Detalle de la toma"].waitForExistence(timeout: timeout))
    }

    @MainActor
    private func tapFirst(_ id: String) {
        dismissPasswordPrompt()
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), id)
        button.tap()
    }

    @MainActor
    private func tapScrolling(_ id: String) {
        dismissPasswordPrompt()
        let target = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(scrollTo(target), id)
        target.tap()
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement) -> Bool {
        for _ in 0 ..< 10 {
            if element.waitForExistence(timeout: 1), element.isHittable { return true }
            app.collectionViews.firstMatch.swipeUp()
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func allowNotifications() {
        let enable = app.buttons["enable-reminders"]
        XCTAssertTrue(scrollTo(enable))
        enable.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons.element(boundBy: 1)
        if allow.waitForExistence(timeout: 10) { allow.tap() }
    }

    private func eventually(_ condition: () async throws -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func firstAccount(_ account: E2EBackend.Account, _ patient: String) async throws -> E2EBackend.InventoryView {
        let items = try await E2EBackend.inventory(account, patient: patient)
        return try XCTUnwrap(items.first)
    }

    private func unconfirmedDose(_ account: E2EBackend.Account, _ patient: String) async throws -> E2EBackend.DoseView {
        let items = try await E2EBackend.doses(account, patient: patient)
        return try XCTUnwrap(items.first { $0.state == "unconfirmed" })
    }
}
