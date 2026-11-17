import Foundation

/// One RTSP (or HTTP-shaped) request from the phone's control connection.
struct RTSPRequest {
    let method: String
    let uri: String
    let proto: String
    let headers: [String: String]  // keys lowercased
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var cseq: String? { header("CSeq") }

    /// The URI's path: "rtsp://host/1234" becomes "/1234"; "/info?txtAirPlay" becomes "/info".
    var path: String {
        var rest = Substring(uri)
        if let scheme = rest.range(of: "://") {
            rest = rest[scheme.upperBound...]
            rest = rest.firstIndex(of: "/").map { rest[$0...] } ?? "/"
        }
        if let query = rest.firstIndex(of: "?") { rest = rest[..<query] }
        return String(rest)
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 16 * 1024 * 1024

    /// Parses one request from the front of `buffer`. Returns nil while more bytes are needed,
    /// otherwise the request and how many bytes it used.
    static func parse(_ buffer: Data) throws -> (request: RTSPRequest, consumed: Int)? {
        guard let terminator = buffer.range(of: headerTerminator) else {
            if buffer.count > maxHeaderBytes { throw AirPlayError.badRequest("request header longer than \(maxHeaderBytes) bytes") }
            return nil
        }
        let headerBytes = buffer[buffer.startIndex..<terminator.lowerBound]
        guard let headerText = String(data: headerBytes, encoding: .utf8) ?? String(data: headerBytes, encoding: .isoLatin1) else {
            throw AirPlayError.badRequest("unreadable request header")
        }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { throw AirPlayError.badRequest("malformed request line \"\(requestLine.joined(separator: " "))\"") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyLength = Int(headers["content-length"] ?? "0") ?? -1
        guard bodyLength >= 0, bodyLength <= maxBodyBytes else {
            throw AirPlayError.badRequest("bad Content-Length \(headers["content-length"] ?? "")")
        }
        let bodyStart = terminator.upperBound
        guard buffer.endIndex - bodyStart >= bodyLength else { return nil }

        let request = RTSPRequest(method: String(requestLine[0]), uri: String(requestLine[1]), proto: String(requestLine[2]),
                                  headers: headers, body: Data(buffer[bodyStart..<(bodyStart + bodyLength)]))
        return (request, bodyStart + bodyLength - buffer.startIndex)
    }
}

struct RTSPResponse {
    var proto: String
    private(set) var status = 200
    private(set) var reason = "OK"
    private(set) var headers: [(String, String)] = []
    var body = Data()
    /// Close the control connection after sending this response.
    var closeConnection = false

    init(proto: String) {
        self.proto = proto
    }

    mutating func setStatus(_ status: Int, _ reason: String) {
        self.status = status
        self.reason = reason
    }

    mutating func addHeader(_ name: String, _ value: String) {
        headers.append((name, value))
    }

    mutating func setPlistBody(_ plist: [String: Any]) throws {
        body = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        addHeader("Content-Type", "application/x-apple-binary-plist")
    }

    func serialized() -> Data {
        var text = "\(proto) \(status) \(reason)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if !body.isEmpty {
            text += "Content-Length: \(body.count)\r\n"
        } else if headers.contains(where: { $0.0 == "Content-Type" }) {
            text += "Content-Length: 0\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}
