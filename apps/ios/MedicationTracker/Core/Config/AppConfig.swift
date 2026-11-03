import Foundation

struct AppConfig: Sendable, Equatable {
    let apiBaseURL: URL
    let firebaseAPIKey: String
    let firebaseEmulatorOrigin: URL?

    enum Failure: Error, Equatable {
        case missingValue
        case insecureEndpoint
    }

    static func load(from bundle: Bundle = .main) throws -> AppConfig {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespaces)
        }
        #if DEBUG
        let allowsLoopback = true
        #else
        let allowsLoopback = false
        #endif
        return try make(
            apiBaseURL: value("APIBaseURL"),
            firebaseAPIKey: value("FirebaseAPIKey"),
            firebaseEmulatorOrigin: value("FirebaseAuthEmulatorOrigin"),
            allowsLoopback: allowsLoopback
        )
    }

    static func make(apiBaseURL: String, firebaseAPIKey: String, firebaseEmulatorOrigin: String, allowsLoopback: Bool) throws -> AppConfig {
        guard let api = URL(string: apiBaseURL), api.host() != nil, !firebaseAPIKey.isEmpty else { throw Failure.missingValue }
        guard isAllowed(api, allowsLoopback: allowsLoopback) else { throw Failure.insecureEndpoint }
        var emulator: URL?
        if !firebaseEmulatorOrigin.isEmpty {
            guard allowsLoopback, let origin = URL(string: firebaseEmulatorOrigin), isLoopback(origin) else { throw Failure.insecureEndpoint }
            emulator = origin
        }
        return AppConfig(apiBaseURL: api, firebaseAPIKey: firebaseAPIKey, firebaseEmulatorOrigin: emulator)
    }

    private static func isAllowed(_ url: URL, allowsLoopback: Bool) -> Bool {
        url.scheme == "https" || (allowsLoopback && url.scheme == "http" && (isLoopback(url) || isLocalNetworkName(url)))
    }

    /// Un iPhone físico alcanza el Mac de desarrollo por su nombre `.local`. Sólo en Debug.
    private static func isLocalNetworkName(_ url: URL) -> Bool {
        url.host()?.hasSuffix(".local") == true
    }

    private static func isLoopback(_ url: URL) -> Bool {
        url.host() == "127.0.0.1" || url.host() == "localhost"
    }
}
