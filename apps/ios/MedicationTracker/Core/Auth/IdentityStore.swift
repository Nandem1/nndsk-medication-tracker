import Foundation

enum IdentityError: Error, Equatable {
    case invalidCredentials
    case sessionExpired
    case transport
    case storage

    var message: String {
        switch self {
        case .invalidCredentials: "Correo o contraseña incorrectos."
        case .sessionExpired: "La sesión venció. Vuelve a iniciar sesión."
        case .transport: "No se pudo conectar. Revisa la red e intenta nuevamente."
        case .storage: "No se pudo guardar la sesión en este dispositivo."
        }
    }
}

struct Credentials: Codable, Sendable, Equatable {
    let uid: String
    var idToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// Firebase Authentication sólo como proveedor de identidad, mediante su API REST oficial.
/// Ver docs/decisions/0005-f4-ios-patient-app.md.
struct FirebaseIdentityClient: Sendable {
    let config: AppConfig
    let transport: any HTTPTransport

    private struct SignInResponse: Decodable {
        let localId: String
        let idToken: String
        let refreshToken: String
        let expiresIn: String
    }

    private struct RefreshResponse: Decodable {
        let id_token: String
        let refresh_token: String
        let expires_in: String
    }

    func signIn(email: String, password: String, now: Date = .now) async throws -> Credentials {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password, "returnSecureToken": true])
        let (data, status) = try await post(endpoint("identitytoolkit.googleapis.com", "v1/accounts:signInWithPassword"), body: body, contentType: "application/json")
        guard (200 ..< 300).contains(status) else {
            throw status >= 500 || status == 429 ? IdentityError.transport : IdentityError.invalidCredentials
        }
        guard let response = try? JSONDecoder().decode(SignInResponse.self, from: data) else { throw IdentityError.transport }
        return Credentials(uid: response.localId, idToken: response.idToken, refreshToken: response.refreshToken, expiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn) ?? 0))
    }

    func refresh(_ credentials: Credentials, now: Date = .now) async throws -> Credentials {
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: credentials.refreshToken)]
        let (data, status) = try await post(endpoint("securetoken.googleapis.com", "v1/token"), body: Data((form.percentEncodedQuery ?? "").utf8), contentType: "application/x-www-form-urlencoded")
        guard (200 ..< 300).contains(status) else {
            throw status >= 500 || status == 429 ? IdentityError.transport : IdentityError.sessionExpired
        }
        guard let response = try? JSONDecoder().decode(RefreshResponse.self, from: data) else { throw IdentityError.transport }
        return Credentials(uid: credentials.uid, idToken: response.id_token, refreshToken: response.refresh_token, expiresAt: now.addingTimeInterval(TimeInterval(response.expires_in) ?? 0))
    }

    private func endpoint(_ host: String, _ path: String) -> URL {
        var url: URL
        if let emulator = config.firebaseEmulatorOrigin {
            url = emulator.appending(path: host).appending(path: path)
        } else {
            url = URL(string: "https://\(host)")!.appending(path: path)
        }
        url.append(queryItems: [URLQueryItem(name: "key", value: config.firebaseAPIKey)])
        return url
    }

    private func post(_ url: URL, body: Data, contentType: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await transport.send(request)
            return (data, response.statusCode)
        } catch {
            throw IdentityError.transport
        }
    }
}

/// Dueño único de las credenciales. Serializa la renovación para no gastar dos veces el refresh token.
actor IdentityStore: TokenProviding {
    private let client: FirebaseIdentityClient
    private let secrets: any SecretStore
    private var credentials: Credentials?
    private var refreshing: Task<Credentials, Error>?

    init(client: FirebaseIdentityClient, secrets: any SecretStore) {
        self.client = client
        self.secrets = secrets
        credentials = secrets.read().flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
    }

    var uid: String? { credentials?.uid }

    func signIn(email: String, password: String) async throws -> String {
        let signedIn = try await client.signIn(email: email, password: password)
        try save(signedIn)
        return signedIn.uid
    }

    func signOut() {
        refreshing?.cancel()
        refreshing = nil
        credentials = nil
        secrets.delete()
    }

    func token(forceRefresh: Bool) async throws -> String {
        guard let current = credentials else { throw APIError.unauthenticated }
        // Un minuto de margen evita enviar un token que venza en tránsito.
        if !forceRefresh, current.expiresAt > Date.now.addingTimeInterval(60) { return current.idToken }
        do {
            return try await renewed(current).idToken
        } catch IdentityError.sessionExpired {
            throw APIError.unauthenticated
        } catch {
            throw APIError.transport
        }
    }

    private func renewed(_ current: Credentials) async throws -> Credentials {
        if let refreshing { return try await refreshing.value }
        let client = client
        let task = Task { try await client.refresh(current) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        // Si la sesión se cerró durante la renovación, no se reescriben credenciales.
        if credentials?.uid == fresh.uid { try save(fresh) }
        return fresh
    }

    private func save(_ value: Credentials) throws {
        let data = try JSONEncoder().encode(value)
        try secrets.write(data)
        credentials = value
    }
}
