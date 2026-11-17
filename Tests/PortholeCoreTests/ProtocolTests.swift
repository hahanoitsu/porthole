import XCTest
@testable import PortholeCore

final class ProtocolTests: XCTestCase {
    func testParsesPipelinedRequestsAndWaitsForFullBody() throws {
        let first = "POST /fp-setup RTSP/1.0\r\nCSeq: 3\r\nContent-Length: 4\r\nContent-Type: application/octet-stream\r\n\r\nabcd"
        let second = "GET /info RTSP/1.0\r\nCSeq: 4\r\n\r\n"
        let buffer = Data((first + second).utf8)

        XCTAssertNil(try RTSPRequest.parse(buffer.prefix(20)))
        XCTAssertNil(try RTSPRequest.parse(Data(first.utf8).dropLast(2)))

        let (request, consumed) = try XCTUnwrap(RTSPRequest.parse(buffer))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/fp-setup")
        XCTAssertEqual(request.cseq, "3")
        XCTAssertEqual(request.header("content-type"), "application/octet-stream")
        XCTAssertEqual(request.body, Data("abcd".utf8))
        XCTAssertEqual(consumed, first.utf8.count)

        let (next, _) = try XCTUnwrap(RTSPRequest.parse(buffer.dropFirst(consumed)))
        XCTAssertEqual(next.method, "GET")
        XCTAssertTrue(next.body.isEmpty)
    }

    func testRequestPaths() throws {
        func path(_ uri: String) throws -> String {
            try XCTUnwrap(RTSPRequest.parse(Data("SETUP \(uri) RTSP/1.0\r\n\r\n".utf8))).request.path
        }
        XCTAssertEqual(try path("rtsp://192.168.1.20/1234567"), "/1234567")
        XCTAssertEqual(try path("rtsp://[fe80::1%en0]/9"), "/9")
        XCTAssertEqual(try path("/info?txtAirPlay&txtRAOP"), "/info")
    }

    func testRejectsOversizedBody() {
        let request = Data("POST /x RTSP/1.0\r\nContent-Length: 999999999\r\n\r\n".utf8)
        XCTAssertThrowsError(try RTSPRequest.parse(request))
    }

    func testResponseSerialization() {
        var response = RTSPResponse(proto: "RTSP/1.0")
        response.addHeader("CSeq", "7")
        response.body = Data("hi".utf8)
        XCTAssertEqual(String(decoding: response.serialized(), as: UTF8.self), "RTSP/1.0 200 OK\r\nCSeq: 7\r\nContent-Length: 2\r\n\r\nhi")

        var empty = RTSPResponse(proto: "RTSP/1.0")
        empty.addHeader("Content-Type", "application/octet-stream")
        XCTAssertTrue(String(decoding: empty.serialized(), as: UTF8.self).hasSuffix("Content-Length: 0\r\n\r\n"))
    }

    func testFairPlayReplies() throws {
        var session = FairPlaySession()
        for mode: UInt8 in 0...3 {
            let request = Data([0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x02, 0x00, mode, 0xbb])
            let reply = try session.handleSetup(request)
            XCTAssertEqual(reply.count, 142)
            XCTAssertEqual(reply.prefix(4), Data("FPLY".utf8))
            XCTAssertEqual(reply[13], mode)
        }
        XCTAssertThrowsError(try session.decryptKey(randomData(72)), "needs the second fp-setup first")

        var outOfRange = randomData(164)
        outOfRange[4] = 0x03
        outOfRange[12] = 4
        XCTAssertThrowsError(try session.handleSetup(outOfRange), "mode byte must be 0-3")

        var second = randomData(164)
        second[4] = 0x03
        second[12] = 0x02
        let reply = try session.handleSetup(second)
        XCTAssertEqual(reply.count, 32)
        XCTAssertEqual(reply.prefix(12), Data([0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00, 0x14]))
        XCTAssertEqual(reply.suffix(20), second.suffix(20))

        let ekey = randomData(72)
        let key = try session.decryptKey(ekey)
        XCTAssertEqual(key.count, 16)
        XCTAssertEqual(try session.decryptKey(ekey), key, "decryption is deterministic")

        var wrongVersion = Data(count: 16)
        wrongVersion[4] = 0x02
        XCTAssertThrowsError(try session.handleSetup(wrongVersion))
    }

    func testFeatureBits() {
        var config = ReceiverConfig()
        XCTAssertEqual(config.featuresText, "0x5A7FFEE6,0x400")
        config.allowHEVC = false
        XCTAssertEqual(config.featuresText, "0x5A7FFEE6,0x0")
        config.legacyPairing = false
        XCTAssertEqual(config.featuresText, "0x527FFEE6,0x0")
        XCTAssertNotEqual(config.features & (1 << 7), 0, "screen mirroring")
        XCTAssertNotEqual(config.features & (1 << 9), 0, "audio")
    }

    func testTXTRecordEncoding() {
        let identity = ReceiverIdentity.generate()
        let txt = ReceiverConfig().airplayTXT(identity: identity)
        var entries: [String: String] = [:]
        var offset = 0
        while offset < txt.count {
            let length = Int(txt[offset])
            let entry = String(decoding: txt[(offset + 1)..<(offset + 1 + length)], as: UTF8.self)
            let parts = entry.split(separator: "=", maxSplits: 1)
            entries[String(parts[0])] = String(parts[1])
            offset += 1 + length
        }
        XCTAssertEqual(offset, txt.count)
        XCTAssertEqual(entries["deviceid"], identity.deviceID)
        XCTAssertEqual(entries["features"], "0x5A7FFEE6,0x400")
        XCTAssertEqual(entries["pk"]?.count, 64)
        XCTAssertEqual(entries["model"], "AppleTV3,2")
    }

    func testIdentityPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("porthole-identity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try ReceiverIdentity.loadOrCreate(at: url)
        let second = try ReceiverIdentity.loadOrCreate(at: url)
        XCTAssertEqual(first.publicKey, second.publicKey)
        XCTAssertEqual(first.deviceID, second.deviceID)
        XCTAssertEqual(first.hardwareAddress[0] & 0x03, 0x02, "locally administered unicast address")
    }
}
