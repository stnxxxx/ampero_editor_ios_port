import Foundation

/// On/off, model and raw parameter values of one block.
public struct BlockState: Equatable, Sendable {
    public var isOn: Bool
    public var modelCode: Int
    /// Raw values as the pedal stores them (not display units), indexed by param number.
    public var params: [Int]

    public init(isOn: Bool, modelCode: Int, params: [Int]) {
        self.isOn = isOn
        self.modelCode = modelCode
        self.params = params
    }
}

/// The 460-byte record the pedal returns for its selected patch.
///
/// Layout: `01 <idx> 00 <level> <name, 18 bytes>`, then nine 33-byte blocks
/// starting at offset 95: `<state> <model hi> <model lo> <x> <p0 lo> <p0 hi> …`.
/// Byte 459 is a checksum the pedal maintains itself.
public struct PatchRecord: Equatable, Sendable {
    public static let length = 460
    static let levelOffset = 3
    static let nameOffset = 4
    static let paramSlots = 14

    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= Self.length else {
            throw ProtocolError.badRecord("\(bytes.count) байт вместо \(Self.length)")
        }
        self.bytes = Array(bytes.prefix(Self.length))
    }

    public var index: Int { Int(bytes[1]) }
    public var level: Int { Int(bytes[Self.levelOffset]) }

    public var name: String {
        let raw = bytes[Self.nameOffset..<(Self.nameOffset + MiniProtocol.nameLength)]
        let trimmed = raw.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    public func block(_ block: Block) -> BlockState {
        let off = block.stateOffset
        let code = Int(bytes[off + 1]) * 128 + Int(bytes[off + 2])
        return BlockState(isOn: bytes[off] == 1, modelCode: code, params: decodeParams(block, code: code))
    }

    public var blocks: [Block: BlockState] {
        Dictionary(uniqueKeysWithValues: Block.allCases.map { ($0, block($0)) })
    }

    private func wide(_ hi: Int, _ lo: Int) -> Int { Int(bytes[hi]) * 128 + Int(bytes[lo]) }

    /// Most params are two bytes, low byte first. A few fields are packed differently
    /// (taken from ampero-bridge records.py, all checked on a pedal).
    private func decodeParams(_ block: Block, code: Int) -> [Int] {
        let off = block.stateOffset
        var params = (0..<Self.paramSlots).map { i in
            Int(bytes[off + 4 + 2 * i]) | Int(bytes[off + 5 + 2 * i]) << 8
        }
        switch block {
        case .dly:
            params[1] = Int(bytes[off + 6])          // Feedback: single byte
            params[2] = wide(off + 7, off + 8)        // Time: 14-bit, raw + 20 = ms
            if code == 16 {                           // 2290 Mod: Mod Rate is 14-bit
                params[3] = wide(off + 9, off + 10)
            }
        case .cab:
            params[4] = Int(bytes[off + 12])         // Position Z
            params[5] = wide(off + 13, off + 14)      // Low Cut: 0 = Off, raw + 19 = Hz
            params[6] = wide(off + 15, off + 16)      // High Cut: 1801 = Off, 2000 + 10 * raw = Hz
        case .eq where code == 4:                     // Para EQ: Volume is a 15th one-byte control
            params.append(Int(bytes[off + 32]))
        default:
            break
        }
        let swellerCodes: [Block: Int] = [.fx1: 142, .fx2: 126, .fx3: 75]
        if swellerCodes[block] == code {
            params[0] = wide(off + 3, off + 4)        // Sweller Attack: raw + 80 = ms
        }
        return params
    }
}
