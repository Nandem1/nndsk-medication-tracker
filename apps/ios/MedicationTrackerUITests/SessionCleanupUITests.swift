import XCTest

final class SessionCleanupUITests: XCTestCase {
    @MainActor
    func testSignedOutCanClearLocalDataAndReturnToLogin() {
        let app = XCUIApplication()
        app.launch()
        if app.tabBars.buttons["Ajustes"].waitForExistence(timeout: 5) {
            app.tabBars.buttons["Ajustes"].tap()
            let signOut = app.buttons["sign-out"]
            for _ in 0 ..< 8 {
                if signOut.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(signOut.waitForExistence(timeout: 15))
            signOut.tap()
            let confirm = app.buttons["Cerrar sesión y borrar datos locales"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 15))
            confirm.tap()
        }
        let clear = app.buttons["login-clear-local"]
        XCTAssertTrue(clear.waitForExistence(timeout: 15))
        clear.tap()
        app.buttons["Cerrar y borrar"].tap()
        XCTAssertTrue(clear.waitForExistence(timeout: 15))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["login-clear-local"].waitForExistence(timeout: 15))
    }
}
