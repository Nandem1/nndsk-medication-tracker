import Foundation
import XCTest
@testable import MedicationTracker

final class PushRegistrationTests: XCTestCase {
    func testInstallationSeparatesAccountsAndSurvivesRetry() {
        let first = PushInstallation.deviceID(installation: "synthetic-installation", owner: "synthetic-a")
        XCTAssertEqual(first, PushInstallation.deviceID(installation: "synthetic-installation", owner: "synthetic-a"))
        XCTAssertNotEqual(first, PushInstallation.deviceID(installation: "synthetic-installation", owner: "synthetic-b"))
        XCTAssertNotEqual(first, PushInstallation.deviceID(installation: "other-installation", owner: "synthetic-a"))
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertFalse(first.contains("synthetic"))
    }

    func testRegistrationAndLogoutUseAuthenticatedOwnerContract() async throws {
        let transport = ScriptedTransport([.status(200), .status(204)])
        let api = APIClient(baseURL: URL(string: "https://example.invalid")!, transport: transport, tokens: FixedTokens())
        let id = "00000000-0000-4000-a000-000000000001"
        try await api.registerDevice(DeviceRegistration(deviceID: id, platform: "apns", token: "synthetic-token", permission: "granted"))
        try await api.unregisterDevice(id: id)
        let requests = transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "DELETE"])
        XCTAssertEqual(requests[0].url?.path, "/v1/devices")
        XCTAssertEqual(requests[1].url?.path, "/v1/devices/\(id)")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["device_id", "platform", "token", "permission"])
        XCTAssertEqual(body["device_id"], id)
        XCTAssertNil(requests[1].httpBody)
    }
}
