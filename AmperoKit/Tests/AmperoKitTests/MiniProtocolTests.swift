import XCTest
@testable import AmperoKit

/// Byte-exact checks against frames captured from the official editor and a real
/// pedal (vectors from ampero-bridge tests/test_ampero_mini.py).
final class MiniProtocolTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    func testSaveFramesMatchEditorCapture() throws {
        let frames = try MiniProtocol.savePatch(index: 0x4B, name: "WADE")
        XCTAssertEqual(hex(frames[0]), "f0 21 25 7f 4d 50 2d 32 12 00 02 06 07 01 4b f7")
        XCTAssertEqual(hex(frames[1]), "f0 21 25 7f 4d 50 2d 32 12 10 00 00 00 01 4b 57 41 44 45"
                       + String(repeating: " 00", count: 14) + " f7")
    }

    func testNameRules() {
        XCTAssertThrowsError(try MiniProtocol.savePatch(index: 1, name: String(repeating: "x", count: 19)))
        XCTAssertThrowsError(try MiniProtocol.savePatch(index: 1, name: "bad\u{01}"))
        XCTAssertThrowsError(try MiniProtocol.savePatch(index: 1, name: "Привет"))
    }

    func testModelAndParamFrames() throws {
        XCTAssertTrue(hex(try MiniProtocol.modelSelect(.eq, code: 4)).hasSuffix("10 06 00 01 00 04 f7"))
        XCTAssertTrue(hex(try MiniProtocol.paramSet(.eq, modelCode: 4, param: 3, value: 0x1E))
            .hasSuffix("10 06 00 02 00 04 03 00 1e f7"))
        // 14-bit value: delay time 3980 = 0x1F 0x0C
        XCTAssertTrue(hex(try MiniProtocol.paramSet(.dly, modelCode: 0, param: 2, value: 3980))
            .hasSuffix("10 08 00 02 00 00 02 1f 0c f7"))
    }

    func testPlainMIDI() throws {
        XCTAssertEqual(try MiniProtocol.programChange(75), [0xC0, 75])
        XCTAssertEqual(MiniProtocol.blockPower(.rvb, on: true), [0xB0, 56, 127])
        XCTAssertEqual(MiniProtocol.blockPower(.fx1, on: false), [0xB0, 48, 0])
        XCTAssertThrowsError(try MiniProtocol.programChange(99))
    }

    func testLabels() {
        XCTAssertEqual(MiniProtocol.patchLabel(75), "P26-1")
        XCTAssertEqual(MiniProtocol.patchLabel(0), "P1-1")
        XCTAssertEqual(MiniProtocol.patchLabel(98), "P33-3")
    }

    func testReadRequestsMatchEditorGroup() throws {
        let reqs = try MiniProtocol.readPatchRequests(index: 0x4B).map {
            hex(Array($0[MiniProtocol.header.count..<($0.count - 1)]))
        }
        XCTAssertEqual(reqs.count, 8)
        XCTAssertEqual(reqs[0], "11 00 02 0a 00 00 00")
        XCTAssertEqual(reqs[1], "12 00 02 13 00 01 4b 01")
        XCTAssertEqual(reqs[2], "12 00 02 15 00 01 4b 00 00 01")
        XCTAssertEqual(reqs[6], "12 00 02 15 00 01 4b 00 04 01")
        XCTAssertEqual(reqs[7], "11 00 00 05 01")
    }

    func testDecodePatchFromNibbleChunks() throws {
        var record = [UInt8](repeating: 0, count: PatchRecord.length)
        record[0] = 0x01; record[1] = 0x4B; record[3] = 0x3C
        record.replaceSubrange(4..<8, with: Array("WADE".utf8))
        // DLY block: on, model 9 (Slapback), feedback 15, time 110
        let dly = Block.dly.stateOffset
        record[dly] = 1; record[dly + 2] = 9; record[dly + 6] = 15; record[dly + 7] = 0; record[dly + 8] = 110
        // AMP block: model 55 (Marshell 50), param 0 = 55
        let amp = Block.amp.stateOffset
        record[amp + 2] = 55; record[amp + 4] = 55

        let nibbles = record.flatMap { [$0 >> 4, $0 & 0x0F] }
        let perChunk = nibbles.count / MiniProtocol.patchChunks
        let frames = try (0..<MiniProtocol.patchChunks).map { n in
            try MiniProtocol.frame(kind: MiniProtocol.kindData,
                                   body: [0x00, 0x02, 0x14, 0x00, 0x01, 0x4B, 0x00, UInt8(n)]
                                       + nibbles[(n * perChunk)..<((n + 1) * perChunk)])
        }

        let patch = try PatchRecord(bytes: MiniProtocol.decodePatchRecord(frames: frames))
        XCTAssertEqual(patch.index, 0x4B)
        XCTAssertEqual(patch.name, "WADE")
        XCTAssertEqual(patch.level, 0x3C)
        XCTAssertEqual(patch.block(.dly), BlockState(isOn: true, modelCode: 9,
                                                     params: [0, 15, 110] + [Int](repeating: 0, count: 11)))
        XCTAssertEqual(patch.block(.amp).modelCode, 55)
        XCTAssertFalse(patch.block(.amp).isOn)
        XCTAssertEqual(patch.block(.amp).params[0], 55)

        XCTAssertThrowsError(try MiniProtocol.decodePatchRecord(frames: Array(frames.prefix(3))))
    }

    func testPedalEvents() throws {
        let param = try MiniProtocol.paramSet(.fx2, modelCode: 9, param: 1, value: 55)
        XCTAssertEqual(PedalEvent(message: param), .paramChanged(.fx2, modelCode: 9, param: 1, value: 55))
        let model = try MiniProtocol.modelSelect(.cab, code: 34)
        XCTAssertEqual(PedalEvent(message: model), .modelChanged(.cab, modelCode: 34))
        let counter = try MiniProtocol.frame(kind: MiniProtocol.kindData, body: [0x00, 0x02, 0x06, 0x04, 0x01, 0x05])
        XCTAssertEqual(PedalEvent(message: counter), .patchIndex(5))
        XCTAssertEqual(PedalEvent(message: [0xC0, 7]), .programChange(7))
    }
}
