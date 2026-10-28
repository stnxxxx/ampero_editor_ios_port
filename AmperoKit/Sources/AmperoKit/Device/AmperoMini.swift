import Foundation

/// High-level, paced access to an Ampero Mini.
///
/// The pedal never acknowledges writes and has been seen to stop on a firmware
/// assert under heavy traffic, so every write goes through one serial queue with a
/// gap between frames, a quiet period around saves, and slider moves are coalesced
/// (only the newest value of a knob is sent).
public actor AmperoMini {
    public struct Timing: Sendable {
        /// Minimum gap between two writes. ampero-bridge uses 500 ms; lower at your own risk.
        public var writeGap: Duration = .milliseconds(300)
        /// Quiet time before and after a save.
        public var saveQuiet: Duration = .seconds(3)
        /// Wait after a Program Change before reading the patch.
        public var patchSettle: Duration = .milliseconds(300)
        /// Gap between the eight read-request frames.
        public var requestGap: Duration = .milliseconds(30)
        public var readTimeout: Duration = .seconds(4)

        public init() {}
    }

    public nonisolated let events: AsyncStream<PedalEvent>
    private let eventsContinuation: AsyncStream<PedalEvent>.Continuation

    private let transport: MIDITransport
    private let timing: Timing
    private let clock = ContinuousClock()
    private var pump: Task<Void, Never>?

    private var lastWrite: ContinuousClock.Instant?
    private var quietUntil: ContinuousClock.Instant?
    private var queueTail: Task<Void, Never>?

    private var dumpFrames: [[UInt8]]?

    private struct ParamKey: Hashable { let block: Block; let param: Int }
    private var pendingParams: [ParamKey: (modelCode: Int, value: Int)] = [:]
    private var pendingOrder: [ParamKey] = []
    private var flushing = false

    public init(transport: MIDITransport, timing: Timing = Timing()) {
        self.transport = transport
        self.timing = timing
        let (stream, continuation) = AsyncStream.makeStream(of: PedalEvent.self, bufferingPolicy: .bufferingNewest(256))
        events = stream
        eventsContinuation = continuation
    }

    deinit {
        pump?.cancel()
        eventsContinuation.finish()
    }

    /// Start listening to the pedal. Call once after creating the actor.
    public func start() {
        guard pump == nil else { return }
        let incoming = transport.incoming
        pump = Task { [weak self] in
            for await message in incoming {
                await self?.ingest(message)
            }
        }
    }

    private func ingest(_ message: [UInt8]) {
        if dumpFrames != nil, let parsed = MiniProtocol.parse(message), MiniProtocol.isDumpReply(parsed.body) {
            dumpFrames?.append(message)
            return
        }
        eventsContinuation.yield(PedalEvent(message: message))
    }

    // MARK: Serial write queue

    /// Runs `operation` after everything queued before it has finished.
    private func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Sends one batch respecting the write gap and the quiet time after a save.
    private func pacedSend(_ messages: [[UInt8]], isSave: Bool = false) async throws {
        var earliest = clock.now
        if let last = lastWrite {
            earliest = max(earliest, last + (isSave ? timing.saveQuiet : timing.writeGap))
        }
        if let quiet = quietUntil { earliest = max(earliest, quiet) }
        if earliest > clock.now { try await clock.sleep(until: earliest) }

        try transport.send(messages)
        lastWrite = clock.now
        if isSave { quietUntil = clock.now + timing.saveQuiet }
    }

    // MARK: Patches

    /// Select a patch (0-based) and read it back.
    public func loadPatch(_ index: Int) async throws -> PatchRecord {
        let pc = try MiniProtocol.programChange(index)
        dropPendingParams()
        return try await enqueue {
            try await self.pacedSend([pc])
            try await Task.sleep(for: self.timing.patchSettle)
            let record = try await self.readSelected(hint: index)
            guard record.index == index else {
                throw ProtocolError.badRecord("педаль вернула \(MiniProtocol.patchLabel(record.index)) вместо \(MiniProtocol.patchLabel(index))")
            }
            return record
        }
    }

    /// Read whatever patch the pedal has selected (including unsaved edits).
    public func readCurrentPatch() async throws -> PatchRecord {
        try await enqueue { try await self.readSelected(hint: 0) }
    }

    private func readSelected(hint: Int) async throws -> PatchRecord {
        // Let the pedal apply the last write (a model change rewrites the whole block).
        var earliest = clock.now
        if let last = lastWrite { earliest = max(earliest, last + timing.patchSettle) }
        if let quiet = quietUntil { earliest = max(earliest, quiet) }
        if earliest > clock.now { try await clock.sleep(until: earliest) }

        dumpFrames = []
        defer { dumpFrames = nil }
        for request in try MiniProtocol.readPatchRequests(index: hint) {
            try transport.send([request])
            try await Task.sleep(for: timing.requestGap)
        }

        let deadline = clock.now + timing.readTimeout
        while clock.now < deadline, !dumpComplete {
            try await Task.sleep(for: .milliseconds(20))
        }
        let bytes = try MiniProtocol.decodePatchRecord(frames: dumpFrames ?? [])
        return try PatchRecord(bytes: bytes)
    }

    private var dumpComplete: Bool {
        guard let frames = dumpFrames else { return false }
        let chunks = Set(frames.compactMap { MiniProtocol.parse($0).flatMap { MiniProtocol.chunkNumber($0.body) } })
        return chunks.count >= MiniProtocol.patchChunks
    }

    /// Store the pedal's current edit buffer into slot `index` under `name`.
    public func save(to index: Int, name: String) async throws {
        let frames = try MiniProtocol.savePatch(index: index, name: name)
        try await flushPendingParams()
        try await enqueue { try await self.pacedSend(frames, isSave: true) }
    }

    // MARK: Blocks

    public func setBlock(_ block: Block, on: Bool) async throws {
        let cc = MiniProtocol.blockPower(block, on: on)
        try await enqueue { try await self.pacedSend([cc]) }
    }

    /// Change a block's model. The pedal resets the block's params to defaults,
    /// so re-read the patch afterwards to get them.
    public func setModel(_ block: Block, code: Int) async throws {
        let frame = try MiniProtocol.modelSelect(block, code: code)
        dropPendingParams(for: block)
        try await enqueue { try await self.pacedSend([frame]) }
    }

    public func setPatchLevel(_ level: Int) async throws {
        let cc = try MiniProtocol.controlChange(MiniProtocol.ccPatchLevel, min(max(level, 0), 99))
        try await enqueue { try await self.pacedSend([cc]) }
    }

    /// Queue a parameter write. Repeated calls for the same knob before it goes out
    /// replace each other, so a slider drag sends only a few frames.
    public func queueParam(_ block: Block, modelCode: Int, param: Int, value: Int) throws {
        _ = try MiniProtocol.paramSet(block, modelCode: modelCode, param: param, value: value) // validate now
        let key = ParamKey(block: block, param: param)
        if pendingParams.updateValue((modelCode, value), forKey: key) == nil {
            pendingOrder.append(key)
        }
        guard !flushing else { return }
        flushing = true
        Task {
            do { try await self.flushPendingParams() } catch { await self.report(error) }
        }
    }

    private func flushPendingParams() async throws {
        defer { flushing = false }
        while !pendingOrder.isEmpty {
            let key = pendingOrder.removeFirst()
            guard let pending = pendingParams.removeValue(forKey: key) else { continue }
            let frame = try MiniProtocol.paramSet(key.block, modelCode: pending.modelCode,
                                                  param: key.param, value: pending.value)
            try await enqueue { try await self.pacedSend([frame]) }
        }
    }

    private func report(_ error: Error) {
        eventsContinuation.yield(.writeFailed(error.localizedDescription))
    }

    private func dropPendingParams(for block: Block? = nil) {
        let drop = pendingOrder.filter { block == nil || $0.block == block }
        for key in drop { pendingParams.removeValue(forKey: key) }
        pendingOrder.removeAll { drop.contains($0) }
    }

    // MARK: Raw access (debugging / exploration)

    public func sendRaw(_ messages: [[UInt8]]) async throws {
        try await enqueue { try await self.pacedSend(messages) }
    }
}
