import Foundation
import Testing
@testable import Relay

struct ModelResumeProtocolTests {
    private func response(_ status: Int = 206, range: String? = "bytes 32-63/100", etag: String? = "\"stable\"",
                          length: String? = "32", encoding: String? = nil,
                          mime: String? = "application/octet-stream", url: String = "https://cdn.example.test/model") throws -> HTTPURLResponse {
        var headers: [String: String] = [:]
        headers["Content-Range"] = range; headers["ETag"] = etag; headers["Content-Length"] = length
        headers["Content-Encoding"] = encoding; headers["Content-Type"] = mime
        let responseURL = try #require(URL(string: url))
        return try #require(HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }
    private func validate(_ response: URLResponse, offset: Int64 = 32, end: Int64 = 63, tag: String? = "\"stable\"") throws -> ModelResumeProtocol.ValidatedResponse {
        try ModelResumeProtocol.validate(response: response, expectedTotal: 100,
                                         requestedOffset: offset, requestedEnd: end, expectedETag: tag)
    }

    @Test func qualifiedChunkBindsExactRangeTotalAndStrongValidator() throws {
        #expect(try validate(response()) == .chunk(start: 32, end: 63, total: 100, strongETag: "\"stable\""))
        #expect(try validate(response(length: nil), tag: nil) == .chunk(start: 32, end: 63, total: 100, strongETag: "\"stable\""))
        #expect(try validate(response(range: "bytes 99-99/100", length: "1"), offset: 99, end: 99) == .chunk(start: 99, end: 99, total: 100, strongETag: "\"stable\""))
    }

    @Test func ignoredRangeReturnsCompleteNeverAppendChunk() throws {
        #expect(try validate(response(200, range: nil, etag: nil, length: "100")) == .complete)
        #expect(throws: (any Error).self) { try validate(response(200, range: nil, length: "32")) }
        #expect(throws: (any Error).self) { try validate(response(200, range: nil, length: nil)) }
        #expect(throws: (any Error).self) { try validate(response(200, length: "100")) }
    }

    @Test func wrongOrMalformedRangeAndLengthCannotAppend() throws {
        for range in ["bytes 31-63/100", "bytes 32-64/100", "bytes 32-63/101", "bytes 32-63/*", "bytes */100", "bytes 63-32/100", "bytes 32-100/100", "bytes -1-63/100", "bytes 32-63/9223372036854775808", "bytes 32-63/100, bytes 64-99/100", "bytes  32-63/100", "bytes ٣٢-٦٣/١٠٠"] {
            #expect(throws: (any Error).self) { try validate(response(range: range)) }
        }
        for length in ["31", "33", "32,32", "-32", "999999999999999999999999"] {
            #expect(throws: (any Error).self) { try validate(response(length: length)) }
        }
        #expect(throws: (any Error).self) { try validate(response(range: nil)) }
        #expect(throws: (any Error).self) { try validate(response(), offset: -1) }
        #expect(throws: (any Error).self) { try validate(response(), end: 100) }
        #expect(throws: (any Error).self) {
            try ModelResumeProtocol.validate(response: response(), expectedTotal: 100_000_000,
                requestedOffset: 0, requestedEnd: ModelResumeProtocol.maximumChunkBytes, expectedETag: nil)
        }
    }

    @Test func weakUnicodeUnquotedInjectedOrChangedETagIsRefused() throws {
        for tag in ["W/\"stable\"", "stable", "\"two tags\"", "\"é\"", "\"a\"b\"", "\"a\r\nb\"", "\"a\u{0}b\"", "\"" + String(repeating: "a", count: 511) + "\""] {
            #expect(throws: (any Error).self) { try ModelResumeProtocol.strongETag(tag) }
        }
        #expect(try ModelResumeProtocol.strongETag("\"opaque-123\"") == "\"opaque-123\"")
        #expect(throws: (any Error).self) { try validate(response(etag: "\"changed\"")) }
        #expect(throws: (any Error).self) { try validate(response(etag: nil)) }
    }

    @Test func encodedMultipartHTMLHTTPAndErrorBodiesAreRefused() throws {
        for encoding in ["gzip", "br", "identity,gzip"] {
            #expect(throws: (any Error).self) { try validate(response(encoding: encoding)) }
        }
        for mime in ["multipart/byteranges; boundary=test", "text/html; charset=utf-8", "application/xhtml+xml", "application/json", "text/plain"] {
            #expect(throws: (any Error).self) { try validate(response(mime: mime)) }
        }
        #expect(throws: (any Error).self) { try validate(response(url: "http://cdn.example.test/model")) }
        for status in [301, 302, 401, 403, 404, 416, 500] {
            #expect(throws: (any Error).self) { try validate(response(status)) }
        }
        #expect(try validate(response(encoding: "identity")) == .chunk(start: 32, end: 63, total: 100, strongETag: "\"stable\""))
    }
}
