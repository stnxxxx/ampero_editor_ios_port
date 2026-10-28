import Foundation

public enum ProtocolError: Error, Equatable, LocalizedError {
    case outOfRange(String)
    case badName
    case incompleteDump(missing: [Int])
    case badRecord(String)

    public var errorDescription: String? {
        switch self {
        case .outOfRange(let what): "Значение вне диапазона: \(what)"
        case .badName: "Имя — до 18 печатных ASCII-символов"
        case .incompleteDump(let missing): "Неполный дамп пресета, нет чанков \(missing)"
        case .badRecord(let why): "Некорректная запись пресета: \(why)"
        }
    }
}

/// Hotone Ampero Mini wire protocol (firmware V2.2).
///
/// Reverse-engineered by the ampero-bridge project (MIT, see third_party/ampero-bridge)
/// and summarised in docs/PROTOCOL.md. Every SysEx frame is
/// `F0 21 25 7F 4D 50 2D 32 <kind> <body> F7`, no checksum, 7-bit body.
/// This is NOT the Ampero II Stage/Stomp header.
public enum MiniProtocol {
    public static let header: [UInt8] = [0xF0, 0x21, 0x25, 0x7F, 0x4D, 0x50, 0x2D, 0x32]
    public static let kindData: UInt8 = 0x12
    public static let kindQuery: UInt8 = 0x11

    /// 99 user patches, 3 per bank (P1-1 ... P33-3).
    public static let patchCount = 99
    public static let patchesPerBank = 3
    public static let nameLength = 18
    public static let patchChunks = 5

    /// CCs proven on a Mini for patch navigation.
    public static let ccBankDown: UInt8 = 22
    public static let ccBankUp: UInt8 = 23
    public static let ccPatchDown: UInt8 = 24
    public static let ccPatchUp: UInt8 = 25
    /// Patch level, 0-99.
    public static let ccPatchLevel: UInt8 = 7

    // MARK: Framing

    static func check7(_ value: Int, _ what: String) throws -> UInt8 {
        guard (0...0x7F).contains(value) else { throw ProtocolError.outOfRange("\(what)=\(value)") }
        return UInt8(value)
    }

    /// 14-bit value as two 7-bit bytes, high first.
    public static func split14(_ value: Int) throws -> (hi: UInt8, lo: UInt8) {
        guard (0...0x3FFF).contains(value) else { throw ProtocolError.outOfRange("14-bit \(value)") }
        return (UInt8(value >> 7), UInt8(value & 0x7F))
    }

    public static func join14(_ hi: UInt8, _ lo: UInt8) -> Int { Int(hi) << 7 | Int(lo) }

    public static func frame(kind: UInt8, body: [UInt8]) throws -> [UInt8] {
        guard body.allSatisfy({ $0 <= 0x7F }) else { throw ProtocolError.outOfRange("SysEx body must be 7-bit") }
        return header + [kind] + body + [0xF7]
    }

    /// `(kind, body)` for a Mini SysEx frame, nil for anything else.
    public static func parse(_ data: [UInt8]) -> (kind: UInt8, body: [UInt8])? {
        guard data.count >= header.count + 2,
              data.starts(with: header),
              data.last == 0xF7 else { return nil }
        return (data[header.count], Array(data[(header.count + 1)..<(data.count - 1)]))
    }

    // MARK: Plain MIDI (channel 1)

    /// Select patch `index` (0-based). PC 75 lands on P26-1.
    public static func programChange(_ index: Int) throws -> [UInt8] {
        guard (0..<patchCount).contains(index) else { throw ProtocolError.outOfRange("patch \(index)") }
        return [0xC0, UInt8(index)]
    }

    public static func controlChange(_ cc: UInt8, _ value: Int) throws -> [UInt8] {
        [0xB0, try check7(Int(cc), "cc"), try check7(value, "value")]
    }

    /// Block on/off goes over CC, never SysEx: a host write of the pedal's
    /// enable-state frame (`10 06 00 00 00`) crashed it.
    public static func blockPower(_ block: Block, on: Bool) -> [UInt8] {
        [0xB0, block.powerCC, on ? 127 : 0]
    }

    // MARK: SysEx writes

    /// `10 AA 00 01 HH LL` — pick a model. Resets the block's params to the model defaults.
    public static func modelSelect(_ block: Block, code: Int) throws -> [UInt8] {
        let (hi, lo) = try split14(code)
        return try frame(kind: kindData, body: [0x10, block.slot, 0x00, 0x01, hi, lo])
    }

    /// `10 AA 00 02 HH LL SS HI LO` — set one parameter. `modelCode` must be the model
    /// the block holds right now, otherwise the pedal silently ignores the write.
    public static func paramSet(_ block: Block, modelCode: Int, param: Int, value: Int) throws -> [UInt8] {
        let (mhi, mlo) = try split14(modelCode)
        let (vhi, vlo) = try split14(value)
        return try frame(kind: kindData, body: [0x10, block.slot, 0x00, 0x02, mhi, mlo,
                                               try check7(param, "param"), vhi, vlo])
    }

    public static func encodeName(_ name: String) throws -> [UInt8] {
        let raw = Array(name.utf8)
        guard raw.count <= nameLength, raw.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            throw ProtocolError.badName
        }
        return raw + [UInt8](repeating: 0, count: nameLength - raw.count)
    }

    /// The editor's save: frame A (`00 02 06 07 01 idx`) and frame B
    /// (`10 00 00 00 01 idx name18`). They must go out together in one transfer;
    /// the pedal stores its current edit buffer under that name and sends nothing back.
    public static func savePatch(index: Int, name: String) throws -> [[UInt8]] {
        let idx = try check7(index, "patch")
        let a = try frame(kind: kindData, body: [0x00, 0x02, 0x06, 0x07, 0x01, idx])
        let b = try frame(kind: kindData, body: [0x10, 0x00, 0x00, 0x00, 0x01, idx] + encodeName(name))
        return [a, b]
    }

    // MARK: Patch read

    /// The eight frames the editor sends to pull a patch. The pedal always answers
    /// with the patch it has selected, whatever `index` says — select it first with PC.
    public static func readPatchRequests(index: Int) throws -> [[UInt8]] {
        let idx = try check7(index, "patch")
        var reqs = [
            try frame(kind: kindQuery, body: [0x00, 0x02, 0x0A, 0x00, 0x00, 0x00]),
            try frame(kind: kindData, body: [0x00, 0x02, 0x13, 0x00, 0x01, idx, 0x01]),
        ]
        for chunk in 0..<UInt8(patchChunks) {
            reqs.append(try frame(kind: kindData, body: [0x00, 0x02, 0x15, 0x00, 0x01, idx, 0x00, chunk, 0x01]))
        }
        reqs.append(try frame(kind: kindQuery, body: [0x00, 0x00, 0x05, 0x01]))
        return reqs
    }

    /// Reply prefixes: dump header, data chunk, trailer.
    static let dumpHeader: [UInt8] = [0x00, 0x02, 0x12]
    static let dumpChunk: [UInt8] = [0x00, 0x02, 0x14]
    static let dumpTrailer: [UInt8] = [0x00, 0x02, 0x16]

    static func isDumpReply(_ body: [UInt8]) -> Bool {
        body.starts(with: dumpHeader) || body.starts(with: dumpChunk) || body.starts(with: dumpTrailer)
    }

    /// Chunk number carried by a `00 02 14 00 01 <idx> 00 <n> <data…>` reply, if it is one.
    static func chunkNumber(_ body: [UInt8]) -> Int? {
        guard body.starts(with: dumpChunk), body.count > 8 else { return nil }
        return Int(body[7])
    }

    /// Join the five nibble-split chunks into the patch record bytes.
    public static func decodePatchRecord(frames: [[UInt8]]) throws -> [UInt8] {
        var chunks: [Int: ArraySlice<UInt8>] = [:]
        for data in frames {
            guard let parsed = parse(data), parsed.kind == kindData,
                  let n = chunkNumber(parsed.body) else { continue }
            chunks[n] = parsed.body[8...]
        }
        let missing = (0..<patchChunks).filter { chunks[$0] == nil }
        guard missing.isEmpty else { throw ProtocolError.incompleteDump(missing: missing) }

        let nibbles = (0..<patchChunks).flatMap { chunks[$0]! }
        var record: [UInt8] = []
        record.reserveCapacity(nibbles.count / 2)
        var i = 0
        while i + 1 < nibbles.count {
            record.append((nibbles[i] & 0x0F) << 4 | (nibbles[i + 1] & 0x0F))
            i += 2
        }
        return record
    }

    public static func patchLabel(_ index: Int) -> String {
        "P\(index / patchesPerBank + 1)-\(index % patchesPerBank + 1)"
    }
}
