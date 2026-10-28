import Foundation

/// Something the pedal sent on its own (it broadcasts SysEx while you use it).
public enum PedalEvent: Equatable, Sendable {
    /// A knob was turned on the pedal: `10 AA 00 02 HH LL SS HI LO`.
    case paramChanged(Block, modelCode: Int, param: Int, value: Int)
    /// A model was picked on the pedal: `10 AA 00 01 HH LL`.
    case modelChanged(Block, modelCode: Int)
    /// `00 02 06 04 01 NN`. Looks like "patch NN is now selected"; not proven.
    case patchIndex(Int)
    /// `10 00 00 00 01 <idx> <name>` — a save made on the pedal itself.
    case patchSaved(index: Int, name: String)
    /// `00 02 06 05 …`
    case heartbeat
    case programChange(Int)
    case controlChange(cc: Int, value: Int)
    case unknown([UInt8])
    /// Not from the pedal: a queued background write failed on our side.
    case writeFailed(String)

    public init(message: [UInt8]) {
        if let parsed = MiniProtocol.parse(message) {
            self = Self.decode(kind: parsed.kind, body: parsed.body)
            return
        }
        switch message.first.map({ $0 & 0xF0 }) {
        case 0xC0 where message.count >= 2:
            self = .programChange(Int(message[1]))
        case 0xB0 where message.count >= 3:
            self = .controlChange(cc: Int(message[1]), value: Int(message[2]))
        default:
            self = .unknown(message)
        }
    }

    private static func decode(kind: UInt8, body: [UInt8]) -> PedalEvent {
        let b = body
        if b.count == 9, b[0] == 0x10, b[2] == 0x00, b[3] == 0x02, let block = Block(slot: b[1]) {
            return .paramChanged(block, modelCode: MiniProtocol.join14(b[4], b[5]),
                                 param: Int(b[6]), value: MiniProtocol.join14(b[7], b[8]))
        }
        if b.count == 6, b[0] == 0x10, b[2] == 0x00, b[3] == 0x01, let block = Block(slot: b[1]) {
            return .modelChanged(block, modelCode: MiniProtocol.join14(b[4], b[5]))
        }
        if b.count >= 6, b.starts(with: [0x10, 0x00, 0x00, 0x00, 0x01]) {
            let name = String(decoding: b.dropFirst(6).prefix { $0 != 0 }, as: UTF8.self)
            return .patchSaved(index: Int(b[5]), name: name)
        }
        if b.count == 6, b.starts(with: [0x00, 0x02, 0x06, 0x04, 0x01]) {
            return .patchIndex(Int(b[5]))
        }
        if b.starts(with: [0x00, 0x02, 0x06, 0x05]) {
            return .heartbeat
        }
        return .unknown(MiniProtocol.header + [kind] + body + [0xF7])
    }
}
