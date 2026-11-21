import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        return (data, http)
    }
}

public enum SourceError: LocalizedError, Equatable {
    case invalidResponse
    case unauthorized
    case notFound(String)
    case rateLimited
    case http(Int, String?)
    case noMatchingAsset(String)
    case noReleases
    case invalidFeed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an unexpected response."
        case .unauthorized: return "Access denied. Check the access token in Settings."
        case .notFound(let what): return "\(what) was not found. For a private repo, make sure the token can read it."
        case .rateLimited: return "GitHub rate limit reached. Add a token or try again later."
        case .http(let code, let message): return "HTTP \(code)\(message.map { ": \($0)" } ?? "")"
        case .noMatchingAsset(let pattern): return "The latest release has no asset matching “\(pattern)”."
        case .noReleases: return "No published releases yet."
        case .invalidFeed(let reason): return "Feed could not be read: \(reason)"
        }
    }
}

extension HTTPURLResponse {
    func ensureSuccess(data: Data, resource: String) throws {
        switch statusCode {
        case 200..<300: return
        case 401: throw SourceError.unauthorized
        case 403:
            if value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" { throw SourceError.rateLimited }
            throw SourceError.unauthorized
        case 404: throw SourceError.notFound(resource)
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw SourceError.http(statusCode, message)
        }
    }
}
