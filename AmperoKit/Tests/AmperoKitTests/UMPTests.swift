import XCTest
@testable import AmperoKit

final class UMPTests: XCTestCase {
    func testChannelMessages() {
        XCTAssertEqual(UMP.encode([0xC0, 75]), [[0x20C0_4B00]])
        XCTAssertEqual(UMP.encode([0xB0, 48, 127]), [[0x20B0_307F]])
        var decoder = UMP.Decoder()
        XCTAssertEqual(decoder.feed([0x20C0_4B00, 0x20B0_307F]), [[0xC0, 75], [0xB0, 48, 127]])
    }

    func testSysExRoundTripAllLengths() {
        for length in 0...40 {
            let message = [0xF0] + (0..<length).map { UInt8($0 & 0x7F) } + [0xF7]
            var decoder = UMP.Decoder()
            let words = UMP.encode(message).flatMap { $0 }
            XCTAssertEqual(decoder.feed(words), [message], "length \(length)")
        }
    }

    func testSaveBatchStaysTwoMessages() throws {
        let frames = try MiniProtocol.savePatch(index: 75, name: "TEST")
        var decoder = UMP.Decoder()
        XCTAssertEqual(decoder.feed(frames.flatMap(UMP.encode).flatMap { $0 }), frames)
    }
}
