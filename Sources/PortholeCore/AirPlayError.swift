import Foundation

public enum AirPlayError: Error, CustomStringConvertible {
    case badRequest(String)
    case unsupported(String)
    case socket(String)
    case crypto(String)

    public var description: String {
        switch self {
        case .badRequest(let message): return "bad request: \(message)"
        case .unsupported(let message): return "unsupported: \(message)"
        case .socket(let message): return "socket error: \(message)"
        case .crypto(let message): return "crypto error: \(message)"
        }
    }
}
