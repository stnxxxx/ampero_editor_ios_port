import Foundation

/// Conversion between MIDI 1.0 byte messages and Universal MIDI Packets (group 0),
/// which is what CoreMIDI's MIDIEventList API speaks.
public enum UMP {
    /// One byte message → one or more UMPs (each UMP is 1 or 2 words).
    public static func encode(_ message: [UInt8]) -> [[UInt32]] {
        guard let status = message.first else { return [] }
        if status == 0xF0 {
            return encodeSysEx(Array(message.dropFirst().prefix { $0 != 0xF7 }))
        }
        // MIDI 1.0 channel voice message, type 0x2.
        let d1 = message.count > 1 ? UInt32(message[1]) : 0
        let d2 = message.count > 2 ? UInt32(message[2]) : 0
        return [[0x2000_0000 | UInt32(status) << 16 | d1 << 8 | d2]]
    }

    /// SysEx payload (without F0/F7) → 64-bit "Data" UMPs, type 0x3, six bytes each.
    static func encodeSysEx(_ payload: [UInt8]) -> [[UInt32]] {
        let chunks = stride(from: 0, to: max(payload.count, 1), by: 6).map {
            Array(payload[$0..<min($0 + 6, payload.count)])
        }
        return chunks.enumerated().map { i, chunk in
            let status: UInt32 = chunks.count == 1 ? 0 : (i == 0 ? 1 : (i == chunks.count - 1 ? 3 : 2))
            var b = chunk + [UInt8](repeating: 0, count: 6 - chunk.count)
            b = b.map { $0 & 0x7F }
            let w0 = 0x3000_0000 | status << 20 | UInt32(chunk.count) << 16 | UInt32(b[0]) << 8 | UInt32(b[1])
            let w1 = UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
            return [w0, w1]
        }
    }

    /// Reassembles UMP words back into complete MIDI 1.0 byte messages.
    public struct Decoder {
        private var sysex: [UInt8]?

        public init() {}

        public mutating func feed(_ words: [UInt32]) -> [[UInt8]] {
            var out: [[UInt8]] = []
            var i = 0
            while i < words.count {
                let w0 = words[i]
                let type = w0 >> 28
                let size = UMP.wordCount(type: type)
                defer { i += size }
                guard i + size <= words.count else { break }
                switch type {
                case 0x2:
                    let status = UInt8(truncatingIfNeeded: w0 >> 16)
                    let d1 = UInt8(truncatingIfNeeded: w0 >> 8) & 0x7F
                    let d2 = UInt8(truncatingIfNeeded: w0) & 0x7F
                    switch status & 0xF0 {
                    case 0xC0, 0xD0: out.append([status, d1])
                    default: out.append([status, d1, d2])
                    }
                case 0x3:
                    let w1 = words[i + 1]
                    let status = (w0 >> 20) & 0xF
                    let count = Int((w0 >> 16) & 0xF)
                    let all: [UInt8] = [UInt8(truncatingIfNeeded: w0 >> 8), UInt8(truncatingIfNeeded: w0),
                                        UInt8(truncatingIfNeeded: w1 >> 24), UInt8(truncatingIfNeeded: w1 >> 16),
                                        UInt8(truncatingIfNeeded: w1 >> 8), UInt8(truncatingIfNeeded: w1)]
                    let bytes = Array(all.prefix(min(count, 6)))
                    switch status {
                    case 0:
                        out.append([0xF0] + bytes + [0xF7])
                        sysex = nil
                    case 1:
                        sysex = bytes
                    case 2:
                        sysex?.append(contentsOf: bytes)
                    default:
                        if let head = sysex { out.append([0xF0] + head + bytes + [0xF7]) }
                        sysex = nil
                    }
                default:
                    break
                }
            }
            return out
        }
    }

    static func wordCount(type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: 2
        case 0xB, 0xC: 3
        default: 4
        }
    }
}
