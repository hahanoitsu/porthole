import XCTest
@testable import PortholeCore

final class VideoTests: XCTestCase {
    func testParsesH264CodecPacket() throws {
        let video = try EncodedVideo.make(.h264)
        let packet = mirrorPacket(type: 1, option: 0x16, payload: video.codecPacketPayload,
                                  width: Float(video.width), height: Float(video.height))
        let format = try VideoStreamFormat.parse(header: packet.prefix(128), payload: packet.dropFirst(128))
        XCTAssertEqual(format.codec, .h264)
        XCTAssertEqual(format.parameterSets.count, 2)
        XCTAssertEqual(format.width, video.width)
        XCTAssertEqual(format.height, video.height)

        let description = try XCTUnwrap(SampleBuffers.formatDescription(for: format))
        XCTAssertEqual(SampleBuffers.presentationSize(of: description), CGSize(width: video.width, height: video.height))
        XCTAssertEqual(try decodedFrameCount(video.frames, format: format), video.frames.count)
    }

    func testParsesHEVCCodecPacket() throws {
        let video = try EncodedVideo.make(.hevc)
        let payload = video.codecPacketPayload
        XCTAssertEqual(payload.range(of: Data("hvcC".utf8))?.upperBound, 94, "same layout as the phone's: arrays start at 0x75")

        let format = try VideoStreamFormat.parse(header: mirrorPacket(type: 1, payload: Data()).prefix(128), payload: payload)
        XCTAssertEqual(format.codec, .hevc)
        XCTAssertEqual(format.parameterSets.count, 3)
        XCTAssertEqual(try decodedFrameCount(video.frames, format: format), video.frames.count)
    }

    func testEmptyCodecPacketExplainsMissingFeatureBit() {
        XCTAssertThrowsError(try VideoStreamFormat.parse(header: Data(count: 128), payload: Data())) { error in
            XCTAssertTrue("\(error)".contains("bit 42"))
        }
    }

    func testNALUnitChecks() throws {
        let video = try EncodedVideo.make(.h264, frameCount: 8)
        for frame in video.frames {
            XCTAssertTrue(NALUnits.isWellFormed(frame.data))
            XCTAssertEqual(NALUnits.containsKeyFrame(frame.data, codec: .h264), frame.isKeyFrame)
        }
        XCTAssertTrue(video.frames[0].isKeyFrame)
        XCTAssertFalse(NALUnits.isWellFormed(Data()))
        XCTAssertFalse(NALUnits.isWellFormed(randomData(64)))
        XCTAssertFalse(NALUnits.isWellFormed(Data([0, 0, 0, 9, 0x65])))
    }
}
