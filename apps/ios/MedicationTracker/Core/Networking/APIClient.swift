import Foundation

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Clasifica los fallos según lo que la cola debe hacer, sin contenido médico.
enum APIError: Error, Equatable {
    case unauthenticated
    case denied
    case conflict
    case invalid
    case rateLimited
    case server
    case transport
    case decoding

    var message: String {
        switch self {
        case .unauthenticated: "La sesión venció. Vuelve a iniciar sesión."
        case .denied: "No tienes permiso para esta información o ya no existe."
        case .conflict: "La información cambió en el servidor. Revísala antes de continuar."
        case .invalid: "El servidor rechazó los datos. Revisa la fecha y la hora."
        case .rateLimited: "Hay demasiadas solicitudes. Se volverá a intentar en un momento."
        case .server, .decoding: "El servidor no pudo completar la solicitud. Se volverá a intentar."
        case .transport: "No hay conexión con el servidor. Se volverá a intentar."
        }
    }
}

protocol TokenProviding: Sendable {
    func token(forceRefresh: Bool) async throws -> String
}

struct APIClient: Sendable {
    let baseURL: URL
    let transport: any HTTPTransport
    let tokens: any TokenProviding

    func registerDevice(_ registration: DeviceRegistration) async throws {
        _ = try await send("/v1/devices", query: [], method: "POST", body: JSONEncoder().encode(registration))
    }

    func unregisterDevice(id: String) async throws {
        _ = try await send("/v1/devices/\(id)", query: [], method: "DELETE", body: nil, timeout: 5)
    }

    func me() async throws -> Me {
        try await request("/v1/me")
    }

    func treatments(patient: String) async throws -> [Treatment] {
        try await all("/v1/patients/\(patient)/treatments")
    }

    func doses(patient: String, from: String, to: String) async throws -> [Dose] {
        try await all("/v1/patients/\(patient)/doses", query: [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)])
    }

    func inventory(patient: String) async throws -> [InventoryProjection] {
        try await all("/v1/patients/\(patient)/inventory")
    }

    func links() async throws -> [CaregiverLink] {
        try await all("/v1/caregiver-links")
    }

    func previewInvitation(token: String) async throws -> InvitationPreview {
        try await request("/v1/invitations/preview", method: "POST", body: JSONEncoder().encode(["token": token]))
    }

    func acceptInvitation(token: String, operationID: String) async throws -> CaregiverLink {
        try await request("/v1/invitations/accept", method: "POST", body: JSONEncoder().encode(["token": token, "client_operation_id": operationID]))
    }

    func revoke(link: String) async throws {
        _ = try await send("/v1/caregiver-links/\(link)", query: [], method: "DELETE", body: nil)
    }

    /// El cuerpo llega ya serializado: un reintento debe enviar los mismos bytes.
    func submit(_ operation: PendingOperation) async throws -> DoseResult {
        try await request(operation.path, method: "POST", body: operation.body)
    }

    private func all<Item: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> [Item] {
        var items: [Item] = []
        var cursor = ""
        var seen = Set<String>()
        repeat {
            var pageQuery = query
            if !cursor.isEmpty { pageQuery.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: Page<Item> = try await request(path, query: pageQuery)
            items += page.items
            cursor = page.nextCursor
            guard cursor.isEmpty || seen.insert(cursor).inserted else { throw APIError.decoding }
        } while !cursor.isEmpty
        return items
    }

    private func request<Output: Decodable>(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> Output {
        let data = try await send(path, query: query, method: method, body: body)
        do {
            return try JSONDecoder().decode(Output.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private func send(_ path: String, query: [URLQueryItem], method: String, body: Data?, timeout: TimeInterval? = nil) async throws -> Data {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        var (data, status) = try await perform(request, forceRefresh: false)
        if status == 401 {
            (data, status) = try await perform(request, forceRefresh: true)
        }
        switch status {
        case 200 ..< 300: return data
        case 401: throw APIError.unauthenticated
        case 403, 404: throw APIError.denied
        case 409: throw APIError.conflict
        case 400, 413, 415, 422: throw APIError.invalid
        case 429: throw APIError.rateLimited
        default: throw APIError.server
        }
    }

    private func perform(_ original: URLRequest, forceRefresh: Bool) async throws -> (Data, Int) {
        var request = original
        request.setValue("Bearer " + (try await tokens.token(forceRefresh: forceRefresh)), forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await transport.send(request)
            return (data, response.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.transport
        }
    }
}
