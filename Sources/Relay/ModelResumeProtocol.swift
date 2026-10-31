import Foundation

/// Header validation only. Transport still enforces actual body bytes and the pinned full SHA-256.
nonisolated enum ModelResumeProtocol {
    static let maximumChunkBytes: Int64 = 32 * 1_024 * 1_024

    enum ValidatedResponse: Sendable, Equatable {
        /// Server ignored Range/If-Range. Never append this body to a partial file.
        case complete
        case chunk(start: Int64, end: Int64, total: Int64, strongETag: String)
    }

    static func strongETag(_ raw: String) throws -> String {
        // RFC opaque-tag ASCII subset: quotes outside, no quotes, space or controls inside.
        // Weak validators cannot bind a byte-range representation.
        guard raw.utf8.count >= 2, raw.utf8.count <= 512,
              raw.first == "\"", raw.last == "\"",
              raw.dropFirst().dropLast().utf8.allSatisfy({ $0 == 0x21 || (0x23...0x7e).contains($0) }) else {
            throw RelayError.message("The model host did not supply a qualified strong ASCII ETag. Restart this transfer rather than appending an unbound range.")
        }
        return raw
    }

    static func validate(response: URLResponse, expectedTotal: Int64, requestedOffset: Int64,
                         requestedEnd: Int64, expectedETag: String?) throws -> ValidatedResponse {
        guard expectedTotal > 0, expectedTotal <= 68_719_476_736,
              requestedOffset >= 0, requestedOffset <= requestedEnd, requestedEnd < expectedTotal,
              requestedEnd - requestedOffset < maximumChunkBytes,
              let http = response as? HTTPURLResponse, let url = http.url,
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else {
            throw RelayError.message("Invalid model range or a non-HTTPS response. No response bytes may be appended.")
        }
        if let expectedETag { _ = try strongETag(expectedETag) }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding") {
            guard try headerToken(encoding).lowercased() == "identity" else {
                throw RelayError.message("Encoded model bodies cannot be resumed by byte offset.")
            }
        }
        if let mime = http.value(forHTTPHeaderField: "Content-Type") {
            let token = try headerToken(mime).lowercased()
            guard !token.hasPrefix("multipart/"), !token.hasPrefix("text/html"),
                  !token.hasPrefix("application/xhtml"), !token.hasPrefix("application/json"),
                  !token.hasPrefix("text/plain") else {
                throw RelayError.message("The model host returned a document/error or multipart response, not a qualified model body.")
            }
        }
        let length = try contentLength(http)
        switch http.statusCode {
        case 200:
            guard length == expectedTotal, http.value(forHTTPHeaderField: "Content-Range") == nil else {
                throw RelayError.message("A complete model response must declare the exact pinned full size without a partial Content-Range.")
            }
            return .complete
        case 206:
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let etag = http.value(forHTTPHeaderField: "ETag") else {
                throw RelayError.message("A resumed model response requires Content-Range and a strong ETag.")
            }
            let parsed = try contentRange(range)
            guard parsed.start == requestedOffset, parsed.end == requestedEnd, parsed.total == expectedTotal,
                  length == nil || length == parsed.end - parsed.start + 1 else {
                throw RelayError.message("The resumed model range or declared byte count differs from the requested pinned range.")
            }
            let tag = try strongETag(etag)
            guard expectedETag == nil || expectedETag == tag else {
                throw RelayError.message("The model ETag changed. Do not append this range; restart the owned partial transfer.")
            }
            return .chunk(start: parsed.start, end: parsed.end, total: parsed.total, strongETag: tag)
        default:
            // Includes 416. A transport with all bytes already present verifies locally before HTTP.
            throw RelayError.message("The model host returned HTTP \(http.statusCode); no range body may be appended.")
        }
    }

    private static func headerToken(_ raw: String) throws -> String {
        guard raw.utf8.count <= 4096, raw.utf8.allSatisfy({ (0x20...0x7e).contains($0) || $0 == 0x09 }) else {
            throw RelayError.message("Malformed model response header.")
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    private static func decimal(_ raw: Substring) -> Int64? {
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(raw)
    }

    private static func contentRange(_ raw: String) throws -> (start: Int64, end: Int64, total: Int64) {
        let value = try headerToken(raw)
        let unit = value.split(separator: " ", omittingEmptySubsequences: false)
        guard unit.count == 2, unit[0].lowercased() == "bytes" else { throw RelayError.message("Malformed model Content-Range.") }
        let rangeAndTotal = unit[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2 else { throw RelayError.message("Malformed model Content-Range.") }
        let endpoints = rangeAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
        guard endpoints.count == 2, let start = decimal(endpoints[0]), let end = decimal(endpoints[1]),
              let total = decimal(rangeAndTotal[1]), start >= 0, end >= start, total > end else {
            throw RelayError.message("Invalid or unbounded model Content-Range.")
        }
        return (start, end, total)
    }

    private static func contentLength(_ response: HTTPURLResponse) throws -> Int64? {
        if let raw = response.value(forHTTPHeaderField: "Content-Length") {
            let token = try headerToken(raw)
            guard let length = decimal(Substring(token)) else { throw RelayError.message("Malformed model Content-Length.") }
            return length
        }
        return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }
}
