import Foundation

nonisolated enum LocalMCPHTTP {
    static let maximumHeaderBytes = 8_192
    static let maximumBodyBytes = 16_384
    static let maximumRequestBytes = maximumHeaderBytes + maximumBodyBytes + 4
    private static let headerEnd = Data([13, 10, 13, 10])

    struct Request: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        let status: Int
        let body: Data

        init(_ status: Int, json: JSONValue? = nil) {
            self.status = status
            self.body = json.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        }

        var bytes: Data {
            let reason = switch status {
            case 200: "OK"
            case 202: "Accepted"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 403: "Forbidden"
            case 404: "Not Found"
            case 405: "Method Not Allowed"
            case 413: "Content Too Large"
            case 415: "Unsupported Media Type"
            case 417: "Expectation Failed"
            case 431: "Request Header Fields Too Large"
            default: "Service Unavailable"
            }
            var headers = [
                "HTTP/1.1 \(status) \(reason)", "Connection: close", "Cache-Control: no-store",
                "X-Content-Type-Options: nosniff", "Content-Length: \(body.count)"
            ]
            if !body.isEmpty { headers.append("Content-Type: application/json; charset=utf-8") }
            if status == 401 { headers.append("WWW-Authenticate: Bearer") }
            if status == 405 { headers.append("Allow: POST") }
            var bytes = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            bytes.append(body)
            return bytes
        }
    }

    enum Parse {
        case incomplete
        case rejected(Response)
        case complete(Request)
    }

    static func parse(_ bytes: Data) -> Parse {
        guard bytes.count <= maximumRequestBytes else { return .rejected(Response(413)) }
        guard let separator = bytes.range(of: headerEnd) else {
            return bytes.count > maximumHeaderBytes + 3 ? .rejected(Response(431)) : .incomplete
        }
        let headerBytes = bytes[..<separator.lowerBound]
        guard headerBytes.count <= maximumHeaderBytes else { return .rejected(Response(431)) }
        guard let header = String(data: headerBytes, encoding: .ascii) else { return .rejected(Response(400)) }
        let lines = header.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return .rejected(Response(400)) }
        let requestLine = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1", !requestLine[0].isEmpty,
              requestLine[0].utf8.allSatisfy({ (65...90).contains($0) }), !requestLine[1].isEmpty else {
            return .rejected(Response(400))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .rejected(Response(400)) }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
                  headers[name] == nil else { return .rejected(Response(400)) }
            headers[name] = value.trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["upgrade"] == nil else { return .rejected(Response(400)) }
        if headers["expect"] != nil { return .rejected(Response(417)) }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(rawLength) else { return .rejected(Response(400)) }
        guard length <= maximumBodyBytes else { return .rejected(Response(413)) }
        let body = bytes[separator.upperBound...]
        if body.count < length { return .incomplete }
        guard body.count == length else { return .rejected(Response(400)) }
        return .complete(Request(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: Data(body)))
    }

    static func authorized(_ header: String?, token: String) -> Bool {
        guard let header, header.count > 7, header.prefix(7).lowercased() == "bearer " else { return false }
        let supplied = header.dropFirst(7).utf8
        let expected = token.utf8
        guard supplied.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(supplied, expected) { difference |= a ^ b }
        return difference == 0
    }
}
