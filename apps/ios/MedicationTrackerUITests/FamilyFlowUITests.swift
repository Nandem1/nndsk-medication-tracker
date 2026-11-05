import XCTest

final class FamilyFlowUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30

    override func setUp() async throws {
        continueAfterFailure = false
        // Cada escenario conserva el límite real de 120 solicitudes por minuto de la API.
        try await Task.sleep(for: .seconds(61))
        try await E2EBackend.setFault("online")
        await MainActor.run {
            app = XCUIApplication()
            app.launch()
            logout()
        }
    }
    override func tearDown() async throws { try await E2EBackend.setFault("online") }

    @MainActor
    func testCreateAccountOnboardingInvitationAndRecovery() async throws {
        app.buttons["login-register"].tap()
        enterCredentials("familia-ui-\(UUID().uuidString.prefix(8))@example.test")
        app.buttons["login-submit"].tap()
        completeOnboarding(name: "Cuidadora sintética", caregiver: true)
        XCTAssertTrue(app.navigationBars["Pacientes"].waitForExistence(timeout: timeout))
        capture("familia-pacientes-vacio")
        app.buttons["open-invite"].tap()
        let hint = app.textFields["invite-name"]
        XCTAssertTrue(hint.waitForExistence(timeout: timeout))
        hint.tap(); hint.typeText("Mamá sintética")
        dismissKeyboard()
        scrollTap("invite-create")
        XCTAssertTrue(app.staticTexts["created-invitation-code"].waitForExistence(timeout: timeout))
        capture("familia-invitacion-creada")
        app.buttons["share-invitation"].tap()
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: timeout), "La hoja nativa debe abrirse")
        XCTAssertTrue(app.otherElements.matching(NSPredicate(format: "label CONTAINS %@", "pega este código")).firstMatch.exists, "Se comparte el mensaje completo")
        capture("familia-compartir-nativo")
        app.otherElements["PopoverDismissRegion"].tap()
        XCTAssertTrue(shareSheet.waitForNonExistence(timeout: timeout))
        app.navigationBars.buttons.firstMatch.tap()
        tab("Ajustes")
        scrollTap("open-profile")
        XCTAssertTrue(app.staticTexts["Cuidadora sintética"].waitForExistence(timeout: timeout))
        capture("familia-mi-perfil")
        app.navigationBars.buttons.firstMatch.tap()
        logout()
        app.buttons["login-recover"].tap()
        let email = app.textFields["login-email"]
        email.tap(); email.typeText("no-existe-\(UUID().uuidString.prefix(8))@example.test")
        app.buttons["login-submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recovery-message"].waitForExistence(timeout: timeout))
        capture("familia-recuperacion-informativa")
    }

    @MainActor
    func testAcceptFullMessageAndRevokeNamedCaregiver() async throws {
        let caregiver = try await E2EBackend.signUp("familia-invitador")
        let patient = try await E2EBackend.signUp("familia-acepta")
        _ = try await E2EBackend.userID(caregiver)
        try await E2EBackend.profile(caregiver, name: "Cuidador visible")
        let token = try await E2EBackend.invitation(caregiver, scopes: ["read"], hint: "Nombre sugerido")
        login(patient, name: "Paciente visible", caregiver: false)
        tab("Ajustes"); scrollTap("open-consent")
        let field = app.textFields["invitation-token"]
        scroll(field); field.tap()
        field.typeText("Hola, te invito a Mis tomas. Abre la app, entra en Ajustes › Acceso de cuidadores y pega este código: \(token). Vence en 24 horas.")
        dismissKeyboard()
        scrollTap("invitation-review")
        XCTAssertTrue(app.buttons["invitation-accept"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Cuidador visible podrá:"].exists)
        capture("familia-consentimiento-nombres")
        app.buttons["invitation-accept"].tap()
        XCTAssertTrue(app.staticTexts["Cuidador visible"].waitForExistence(timeout: timeout))
        scrollTap("revoke-link")
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Quitar acceso", "revoke-link")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout)); confirm.tap()
        XCTAssertTrue(app.staticTexts["links-empty"].waitForExistence(timeout: timeout))
    }

    @MainActor
    func testCaregiverTwoPatientsPermissionsConflictInventoryAndRevocation() async throws {
        let caregiver = try await E2EBackend.signUp("familia-cuida")
        let one = try await E2EBackend.signUp("familia-uno")
        let two = try await E2EBackend.signUp("familia-dos")
        _ = try await E2EBackend.userID(caregiver)
        let firstID = try await E2EBackend.userID(one)
        let secondID = try await E2EBackend.userID(two)
        try await E2EBackend.profile(caregiver, name: "Cuidador sintético")
        try await E2EBackend.profile(one, name: "Mamá sintética")
        try await E2EBackend.profile(two, name: "Papá sintético")
        let fullToken = try await E2EBackend.invitation(caregiver, scopes: ["read", "doses", "treatments", "inventory"], hint: "Mamá sintética")
        let readToken = try await E2EBackend.invitation(caregiver, scopes: ["read"], hint: "Papá sintético")
        try await E2EBackend.accept(one, token: fullToken)
        try await E2EBackend.accept(two, token: readToken)
        try await E2EBackend.createTreatment(caregiver: one, patient: firstID, name: "Ejemplo mamá")
        try await E2EBackend.createTreatment(caregiver: two, patient: secondID, name: "Ejemplo papá")
        login(caregiver, name: nil, caregiver: true)
        XCTAssertTrue(app.buttons["patient-Mamá sintética"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["patient-Papá sintético"].exists)
        capture("familia-dos-pacientes")
        app.buttons["patient-Papá sintético"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["caregiver-read-only"].waitForExistence(timeout: timeout))
        app.buttons.matching(identifier: "caregiver-dose-Ejemplo papá").firstMatch.tap()
        XCTAssertFalse(app.buttons["caregiver-action-taken"].exists)
        capture("familia-solo-lectura")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["patient-Mamá sintética"].tap()
        app.buttons.matching(identifier: "caregiver-dose-Ejemplo mamá").firstMatch.tap()
        XCTAssertTrue(app.buttons["caregiver-action-taken"].waitForExistence(timeout: timeout))
        capture("familia-declaraciones-tercera-persona")
        app.buttons["caregiver-action-taken_late"].tap()
        XCTAssertTrue(app.staticTexts["¿A qué hora se lo tomó?"].waitForExistence(timeout: timeout))
        capture("familia-hoja-tardia")
        app.buttons["Cancelar"].tap()

        try await E2EBackend.setFault("stall")
        app.buttons["caregiver-action-skipped"].tap()
        XCTAssertTrue(app.staticTexts["Guardada, falta enviar"].waitForExistence(timeout: 5), "Guardar no espera la red")
        app.terminate()
        try await E2EBackend.setFault("offline")
        app.launch()
        XCTAssertTrue(app.buttons["patient-Mamá sintética"].waitForExistence(timeout: timeout))
        app.buttons["patient-Mamá sintética"].tap()
        // La dosis pendiente pasa a «Ya registradas»; la primera fila es ahora la próxima toma.
        let pending = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "caregiver-dose-Ejemplo mamá", "Guardada, falta enviar")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: timeout), "La cola debe sobrevivir al reinicio")
        scroll(pending); pending.tap()
        XCTAssertTrue(app.staticTexts["Guardada, falta enviar"].waitForExistence(timeout: timeout))
        let serverDoses = try await E2EBackend.doses(one, patient: firstID)
        let due = try XCTUnwrap(serverDoses.first { $0.state == "unconfirmed" })
        try await E2EBackend.declare(one, dose: due, type: "taken")
        try await E2EBackend.setFault("online")
        refresh()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Necesita revisión")).firstMatch.waitForExistence(timeout: timeout))
        capture("familia-conflicto")
        try await Task.sleep(for: .seconds(61))
        scrollTap("conflict-discard")
        app.navigationBars.buttons.firstMatch.tap()
        app.segmentedControls["patient-section"].buttons["Inventario"].tap()
        let inventoryLink = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "caregiver-inventory-")).firstMatch
        XCTAssertTrue(inventoryLink.waitForExistence(timeout: timeout)); inventoryLink.tap()
        XCTAssertTrue(app.buttons["inventory-replenish"].waitForExistence(timeout: timeout))
        capture("familia-inventario")
        app.buttons["inventory-replenish"].tap()
        app.textFields["inventory-quantity"].tap(); app.textFields["inventory-quantity"].typeText("2,5")
        dismissKeyboard()
        try await E2EBackend.setFault("lose-responses")
        app.buttons["inventory-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["inventory-error"].waitForExistence(timeout: timeout))
        try await E2EBackend.setFault("online")
        app.buttons["inventory-save"].tap()
        XCTAssertTrue(app.buttons["inventory-count"].waitForExistence(timeout: timeout))
        app.buttons["inventory-count"].tap()
        app.textFields["inventory-quantity"].tap(); app.textFields["inventory-quantity"].typeText("15,25")
        app.textFields["inventory-reason"].tap(); app.textFields["inventory-reason"].typeText("Conteo sintético")
        dismissKeyboard()
        try await E2EBackend.setFault("lose-responses")
        app.buttons["inventory-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["inventory-error"].waitForExistence(timeout: timeout))
        capture("familia-conteo-respuesta-perdida")
        try await E2EBackend.setFault("online")
        app.buttons["inventory-save"].tap()
        XCTAssertTrue(app.buttons["inventory-count"].waitForExistence(timeout: timeout))
        let accounts = try await E2EBackend.inventory(one, patient: firstID)
        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account.balance, "15.250")
        let movements = try await E2EBackend.movements(one, inventory: account.account_id)
        XCTAssertEqual(movements.filter { $0.reason == "replenishment" }.count, 1)
        XCTAssertEqual(movements.filter { $0.reason == "manual_adjustment" }.count, 1)
        capture("familia-inventario-confirmado")
        try await E2EBackend.revoke(one, caregiver: caregiver)
        tab("Pacientes")
        // Tocar la pestaña activa puede volver a la raíz, donde ya no hay botón atrás.
        for _ in 0..<2 where app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        refresh()
        XCTAssertTrue(app.buttons["patient-Papá sintético"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["patient-Mamá sintética"].exists)
        capture("familia-revocacion-selectiva")
    }

    /// Propone el cuidador en este teléfono; cada paciente decide por sí mismo. API y PostgreSQL reales.
    @MainActor
    func testSharedInventoryConsentConsumptionAndLeave() async throws {
        let caregiver = try await E2EBackend.signUp("pool-cuida")
        let mama = try await E2EBackend.signUp("pool-mama")
        let papa = try await E2EBackend.signUp("pool-papa")
        _ = try await E2EBackend.userID(caregiver)
        let mamaID = try await E2EBackend.userID(mama)
        let papaID = try await E2EBackend.userID(papa)
        try await E2EBackend.profile(caregiver, name: "Cuidadora sintética")
        try await E2EBackend.profile(mama, name: "Mamá sintética")
        try await E2EBackend.profile(papa, name: "Papá sintético")
        let scopes = ["read", "doses", "treatments", "inventory"]
        try await E2EBackend.accept(mama, token: E2EBackend.invitation(caregiver, scopes: scopes, hint: "Mamá sintética"))
        try await E2EBackend.accept(papa, token: E2EBackend.invitation(caregiver, scopes: scopes, hint: "Papá sintético"))
        try await E2EBackend.createTreatment(caregiver: caregiver, patient: mamaID, name: "Losartán")
        try await E2EBackend.createTreatment(caregiver: caregiver, patient: papaID, name: "Losartán")

        login(caregiver, name: nil, caregiver: true)
        XCTAssertTrue(app.buttons["patient-Mamá sintética"].waitForExistence(timeout: timeout))
        app.buttons["patient-Mamá sintética"].tap()
        app.segmentedControls["patient-section"].buttons["Inventario"].tap()
        let inventoryLink = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "caregiver-inventory-")).firstMatch
        XCTAssertTrue(inventoryLink.waitForExistence(timeout: timeout)); inventoryLink.tap()
        let propose = app.buttons["pool-propose"]
        XCTAssertTrue(propose.waitForExistence(timeout: timeout)); scroll(propose); propose.tap()
        let candidate = app.buttons["pool-candidate"]
        XCTAssertTrue(candidate.waitForExistence(timeout: timeout))
        XCTAssertEqual(candidate.label, "Compartir con Papá sintético")
        capture("familia-p5-candidatos")
        candidate.tap()
        XCTAssertTrue(labeled("Esperando a Papá sintético").waitForExistence(timeout: timeout))
        capture("familia-p5-esperando")
        let waiting = try await E2EBackend.inventory(mama, patient: mamaID)
        XCTAssertEqual(waiting.first?.balance, "10.000", "Pendiente mantiene saldos separados")
        tab("Ajustes")
        if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        logout()

        try await Task.sleep(for: .seconds(61))
        if app.buttons["login-register"].label == "Volver a entrar" { app.buttons["login-register"].tap() }
        login(mama, name: nil, caregiver: false)
        let proposal = app.staticTexts["pool-proposal"]
        XCTAssertTrue(proposal.waitForExistence(timeout: timeout))
        XCTAssertTrue(proposal.label.contains("Cuidadora sintética propone compartir Losartán 500 mg con Papá sintético"), proposal.label)
        capture("familia-p5-propuesta")
        scroll(app.buttons["pool-accept"]); app.buttons["pool-accept"].tap()
        XCTAssertTrue(proposal.waitForNonExistence(timeout: timeout))
        try await E2EBackend.acceptPendingPool(papa)
        let active = try await E2EBackend.inventory(mama, patient: mamaID)
        XCTAssertEqual(active.first?.balance, "20.000")

        // Cada paciente consume de su propia cuenta y el saldo común baja una vez por dosis.
        let ownDoses = try await E2EBackend.doses(mama, patient: mamaID)
        try await E2EBackend.declare(mama, dose: try XCTUnwrap(ownDoses.first { $0.state == "unconfirmed" }), type: "taken")
        let otherDoses = try await E2EBackend.doses(papa, patient: papaID)
        try await E2EBackend.declare(papa, dose: try XCTUnwrap(otherDoses.first { $0.state == "unconfirmed" }), type: "taken")
        let consumed = try await E2EBackend.inventory(papa, patient: papaID)
        XCTAssertEqual(consumed.first?.balance, "19.000")

        tab("Hoy"); refresh()
        tab("Ajustes"); refresh()
        let leave = app.buttons["pool-leave"]
        scroll(leave)
        XCTAssertTrue(labeled("Inventario compartido con Papá sintético").exists)
        XCTAssertTrue(labeled("Saldo confirmado: 19 comprimidos").exists)
        capture("familia-p5-compartido")
        leave.tap()
        XCTAssertTrue(labeled("El saldo se queda con Papá sintético").waitForExistence(timeout: timeout))
        capture("familia-p5-salir")
        app.buttons["Confirmar"].tap()
        XCTAssertTrue(labeled("Saldo confirmado: 0 comprimidos").waitForExistence(timeout: timeout))
        let remaining = try await E2EBackend.inventory(papa, patient: papaID)
        XCTAssertEqual(remaining.first?.balance, "19.000")
        let ledger = try await E2EBackend.movements(mama, inventory: try XCTUnwrap(active.first).account_id)
        XCTAssertEqual(ledger.filter { $0.reason == "pool_transfer" }.count, 1)
    }

    /// Exporta con la hoja nativa y elimina la cuenta: la historia del otro paciente queda intacta.
    @MainActor
    func testExportAndDeleteAccountKeepOtherHistory() async throws {
        let patient = try await E2EBackend.signUp("borrar-paciente")
        let caregiver = try await E2EBackend.signUp("borrar-cuida")
        let other = try await E2EBackend.signUp("borrar-otro")
        let patientID = try await E2EBackend.userID(patient)
        let otherID = try await E2EBackend.userID(other)
        _ = try await E2EBackend.userID(caregiver)
        try await E2EBackend.profile(patient, name: "Persona que se va")
        try await E2EBackend.profile(caregiver, name: "Cuidadora sintética")
        let scopes = ["read", "doses", "treatments", "inventory"]
        try await E2EBackend.accept(patient, token: E2EBackend.invitation(caregiver, scopes: scopes, hint: "Persona"))
        // Quien se va también cuida a otra persona y registró en su historia.
        try await E2EBackend.accept(other, token: E2EBackend.invitation(patient, scopes: scopes, hint: "Otro"))
        try await E2EBackend.createTreatment(caregiver: patient, patient: patientID, name: "Losartán")
        try await E2EBackend.createTreatment(caregiver: other, patient: otherID, name: "Losartán")
        let doses = try await E2EBackend.doses(other, patient: otherID)
        try await E2EBackend.declare(patient, dose: try XCTUnwrap(doses.first { $0.state == "unconfirmed" }), type: "taken")

        login(patient, name: nil, caregiver: false)
        tab("Ajustes")
        scrollTap("open-profile")
        scrollTap("export-account")
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: timeout), "La hoja nativa debe abrirse")
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(shareSheet.exists, "La hoja debe seguir abierta")
        capture("familia-p6-exportar")
        // Dentro de un sheet no hay región de popover: se cierra como cualquier hoja.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        if !shareSheet.waitForNonExistence(timeout: 3) { shareSheet.swipeDown(velocity: .fast) }
        XCTAssertTrue(shareSheet.waitForNonExistence(timeout: timeout))
        capture("familia-p6-mi-perfil")
        scrollTap("open-delete-account")
        let delete = app.buttons["delete-account"]
        XCTAssertTrue(delete.waitForExistence(timeout: timeout))
        XCTAssertFalse(delete.isEnabled, "Sin escribir BORRAR no se puede eliminar")
        let confirm = app.textFields["delete-confirm"]
        confirm.tap(); confirm.typeText("BORRAR")
        capture("familia-p6-eliminar")
        delete.tap()
        XCTAssertTrue(app.textFields["login-email"].waitForExistence(timeout: timeout))

        do {
            _ = try await E2EBackend.doses(caregiver, patient: patientID)
            XCTFail("El cuidador ya no debe ver a la persona eliminada")
        } catch {}
        let remaining = try await E2EBackend.inventory(other, patient: otherID)
        XCTAssertEqual(remaining.first?.balance, "9.500", "La historia de otro paciente queda intacta")
        let after = try await E2EBackend.doses(other, patient: otherID)
        XCTAssertEqual(after.filter { $0.state == "taken" }.count, 1)
    }

    @MainActor private func labeled(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
    @MainActor private func enterCredentials(_ email: String) {
        let field = app.textFields["login-email"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout)); field.tap(); field.typeText(email)
        let password = app.secureTextFields["login-password"]
        password.tap()
        // Al registrar, iOS puede ofrecer una contraseña segura y esa hoja se lleva lo que se escribe.
        let offer = app.staticTexts["¿Usar contraseña segura?"]
        if offer.waitForExistence(timeout: 3) {
            app.buttons["Cerrar"].firstMatch.tap()
            XCTAssertTrue(offer.waitForNonExistence(timeout: timeout))
            focus(password)
        }
        password.typeText(E2EBackend.password)
        XCTAssertTrue(app.buttons["login-submit"].isEnabled, "La contraseña completa habilita el envío")
    }
    @MainActor private func login(_ account: E2EBackend.Account, name: String?, caregiver: Bool) {
        enterCredentials(account.email); app.buttons["login-submit"].tap()
        completeOnboarding(name: name, caregiver: caregiver)
    }
    @MainActor private func completeOnboarding(name: String?, caregiver: Bool) {
        let profile = app.textFields["profile-name"]
        if let name, profile.waitForExistence(timeout: timeout) {
            dismissPasswordPrompt()
            XCTAssertTrue(profile.isEnabled)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(profile.frame))
            focus(profile)
            profile.typeText(name); dismissKeyboard(); app.buttons["profile-save"].tap()
        }
        let use = app.buttons[caregiver ? "use-caregiver" : "use-patient"]
        XCTAssertTrue(use.waitForExistence(timeout: timeout)); dismissPasswordPrompt()
        for _ in 0..<6 {
            // El aviso de contraseña puede llegar tarde y se lleva el toque.
            dismissPasswordPrompt()
            tapAtFrame(use)
            if app.tabBars.buttons["Ajustes"].waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(app.tabBars.buttons["Ajustes"].waitForExistence(timeout: timeout))
        dismissPasswordPrompt()
    }
    @MainActor private func tapAtFrame(_ element: XCUIElement) {
        let frame = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }
    @MainActor private func focus(_ element: XCUIElement) {
        for _ in 0..<3 {
            dismissPasswordPrompt()
            tapAtFrame(element)
            if app.keyboards.firstMatch.waitForExistence(timeout: 2) { return }
        }
        XCTFail("El campo debe recibir foco antes de escribir")
    }
    @MainActor private func tab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: timeout)); dismissPasswordPrompt(); tab.tap()
    }
    @MainActor private func logout() {
        dismissPasswordPrompt()
        if app.buttons["onboarding-sign-out"].exists {
            app.buttons["onboarding-sign-out"].tap()
            app.buttons["Cerrar sesión y borrar datos locales"].tap()
            XCTAssertTrue(app.textFields["login-email"].waitForExistence(timeout: timeout))
        }
        if app.buttons["login-register"].exists && !app.secureTextFields["login-password"].exists { app.buttons["login-register"].tap() }
        guard app.tabBars.buttons["Ajustes"].waitForExistence(timeout: 3) else { return }
        tab("Ajustes")
        if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        scrollTap("sign-out")
        app.buttons["Cerrar sesión y borrar datos locales"].tap()
        XCTAssertTrue(app.textFields["login-email"].waitForExistence(timeout: timeout))
    }
    @MainActor private func scroll(_ element: XCUIElement) {
        for _ in 0..<10 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func scrollTap(_ id: String) { let element = app.buttons[id]; scroll(element); element.tap() }
    /// La tarjeta de inventario compartido también dice «Ahora no»: ese botón es una decisión del paciente.
    @MainActor private func dismissPasswordPrompt() {
        let prompt = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Ahora no", "pool-decline")).firstMatch
        if prompt.exists { prompt.tap() }
    }
    @MainActor private func dismissKeyboard() {
        if app.buttons["Return"].exists { app.buttons["Return"].tap() }
        app.swipeUp()
    }
    @MainActor private func refresh() {
        let list = app.collectionViews.firstMatch
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)), withVelocity: .slow, thenHoldForDuration: 0.5)
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
