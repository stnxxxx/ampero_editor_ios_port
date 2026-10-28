import Foundation

/// The nine blocks of an Ampero Mini patch, in signal-chain (and slot) order.
public enum Block: String, CaseIterable, Identifiable, Codable, Sendable {
    case fx1, fx2, amp, nr, cab, eq, fx3, dly, rvb

    public var id: String { rawValue }

    /// 0-based position in the chain.
    public var position: Int { Block.allCases.firstIndex(of: self)! }

    /// Slot byte used in model/param SysEx frames (01...09). RVB = 09 is not proven on a pedal yet.
    public var slot: UInt8 { UInt8(position + 1) }

    /// CC number that switches the block on (127) or off (0), MIDI channel 1.
    public var powerCC: UInt8 { UInt8(48 + position) }

    /// Offset of the block's state byte inside the 460-byte patch record.
    public var stateOffset: Int { 95 + 33 * position }

    public var title: String {
        switch self {
        case .fx1: "FX1"
        case .fx2: "FX2"
        case .amp: "AMP"
        case .nr: "NR"
        case .cab: "CAB"
        case .eq: "EQ"
        case .fx3: "FX3"
        case .dly: "DLY"
        case .rvb: "RVB"
        }
    }

    public init?(slot: UInt8) {
        guard (1...9).contains(slot) else { return nil }
        self = Block.allCases[Int(slot) - 1]
    }
}
