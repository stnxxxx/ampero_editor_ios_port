import AmperoKit
import Foundation
import Observation

/// App state: connection, the patch being edited and the pedal's broadcasts.
@MainActor
@Observable
final class EditorModel {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected(String)
        case failed(String)
    }

    struct MonitorLine: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    typealias EndpointID = CoreMIDITransport.Endpoint.ID

    // Connection
    private(set) var connection: Connection = .disconnected
    private(set) var sources: [CoreMIDITransport.Endpoint] = []
    private(set) var destinations: [CoreMIDITransport.Endpoint] = []
    var selectedSourceID: EndpointID?
    var selectedDestinationID: EndpointID?

    // Catalog
    let catalog: ModelCatalog?
    let catalogError: String?

    // Patch being edited
    private(set) var patchIndex: Int?
    private(set) var patchName = ""
    private(set) var blocks: [Block: BlockState] = [:]
    private(set) var isDirty = false
    var selectedBlock: Block = .amp

    private(set) var patchNames: [Int: String] = [:]
    private(set) var isBusy = false
    private(set) var scanProgress: Double?
    var errorMessage: String?
    private(set) var monitor: [MonitorLine] = []

    private var transport: CoreMIDITransport?
    private var device: AmperoMini?
    private var eventsTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var paramWriter: AsyncStream<(Block, Int, Int, Int)>.Continuation?

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    init() {
        do {
            catalog = try ModelCatalog.loadBundled()
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = error.localizedDescription
        }
    }

    // MARK: Connection

    func refreshEndpoints() {
        sources = CoreMIDITransport.sources()
        destinations = CoreMIDITransport.destinations()
        if selectedSourceID.map({ id in !sources.contains { $0.id == id } }) ?? true {
            selectedSourceID = CoreMIDITransport.guessPedal(in: sources)?.id
        }
        if selectedDestinationID.map({ id in !destinations.contains { $0.id == id } }) ?? true {
            selectedDestinationID = CoreMIDITransport.guessPedal(in: destinations)?.id
        }
        // The pedal went away: drop the connection so the UI says so.
        if isConnected, selectedSourceID == nil || selectedDestinationID == nil {
            disconnect()
        }
    }

    var canAutoConnect: Bool { selectedSourceID != nil && selectedDestinationID != nil }

    func connect() async {
        guard let source = sources.first(where: { $0.id == selectedSourceID }),
              let destination = destinations.first(where: { $0.id == selectedDestinationID }) else {
            errorMessage = "Выберите MIDI-вход и выход педали"
            return
        }
        disconnect()
        connection = .connecting
        do {
            // A fresh transport per connection: its incoming stream allows only one reader.
            let transport = try CoreMIDITransport()
            transport.onSetupChanged = { [weak self] in
                Task { @MainActor in self?.refreshEndpoints() }
            }
            try transport.connect(source: source, destination: destination)
            self.transport = transport

            let device = AmperoMini(transport: transport)
            await device.start()
            self.device = device
            listen(to: device)
            startParamWriter(device)
            connection = .connected(source.name)
            await reloadCurrent()
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        eventsTask?.cancel()
        paramWriter?.finish()
        transport?.disconnect()
        transport = nil
        device = nil
        connection = .disconnected
    }

    private func listen(to device: AmperoMini) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in device.events {
                self?.handle(event)
            }
        }
    }

    /// Param writes go through one ordered stream so a fast slider drag can't
    /// reach the pedal out of order.
    private func startParamWriter(_ device: AmperoMini) {
        paramWriter?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: (Block, Int, Int, Int).self)
        paramWriter = continuation
        Task { [weak self] in
            for await (block, code, param, value) in stream {
                do {
                    try await device.queueParam(block, modelCode: code, param: param, value: value)
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: Pedal events

    private func handle(_ event: PedalEvent) {
        switch event {
        case .heartbeat:
            return
        case let .paramChanged(block, code, param, value):
            if blocks[block]?.modelCode == code { setLocalParam(block, param, value) }
            isDirty = true
        case let .modelChanged(block, code):
            blocks[block]?.modelCode = code
            isDirty = true
            scheduleReload()
        case let .patchIndex(index), let .programChange(index):
            if index != patchIndex { scheduleReload() }
        case let .patchSaved(index, name):
            patchNames[index] = name
        case let .writeFailed(message):
            errorMessage = message
        case .controlChange, .unknown:
            break
        }
        log(describe(event))
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.reloadCurrent()
        }
    }

    // MARK: Patches

    func reloadCurrent() async {
        guard let device else { return }
        await run { try await self.apply(device.readCurrentPatch()) }
    }

    func selectPatch(_ index: Int) async {
        guard let device, (0..<MiniProtocol.patchCount).contains(index) else { return }
        await run { try await self.apply(device.loadPatch(index)) }
    }

    func step(by delta: Int) async {
        let count = MiniProtocol.patchCount
        await selectPatch(((patchIndex ?? 0) + delta + count) % count)
    }

    func save(name: String, to index: Int) async {
        guard let device else { return }
        await run {
            try await device.save(to: index, name: name)
            self.patchNames[index] = name
            if index == self.patchIndex {
                self.patchName = name
                self.isDirty = false
            }
        }
    }

    /// Walk all patches to read their names. Switches patches on the pedal (audible!)
    /// and returns to the one that was selected.
    func scanPatchNames() async {
        guard let device else { return }
        let start = patchIndex
        scanProgress = 0
        defer { scanProgress = nil }
        for index in 0..<MiniProtocol.patchCount {
            do {
                let record = try await device.loadPatch(index)
                patchNames[index] = record.name
            } catch {
                errorMessage = "\(MiniProtocol.patchLabel(index)): \(error.localizedDescription)"
                break
            }
            scanProgress = Double(index + 1) / Double(MiniProtocol.patchCount)
        }
        if let start { await selectPatch(start) }
    }

    private func apply(_ record: PatchRecord) {
        patchIndex = record.index
        patchName = record.name
        blocks = record.blocks
        patchNames[record.index] = record.name
        isDirty = false
    }

    // MARK: Editing

    func setBlock(_ block: Block, on: Bool) async {
        guard let device else { return }
        blocks[block]?.isOn = on
        isDirty = true
        await run { try await device.setBlock(block, on: on) }
    }

    func setModel(_ block: Block, code: Int) async {
        guard let device, blocks[block]?.modelCode != code else { return }
        blocks[block]?.modelCode = code
        isDirty = true
        await run {
            try await device.setModel(block, code: code)
            // The pedal resets the block to the model's defaults; fetch them.
            try await self.apply(device.readCurrentPatch())
            self.isDirty = true
        }
    }

    func setParam(_ block: Block, _ spec: ParamSpec, raw: Int) {
        guard let state = blocks[block] else { return }
        let value = min(max(raw, spec.rawRange.lowerBound), spec.rawRange.upperBound)
        guard state.params.indices.contains(spec.index) ? state.params[spec.index] != value : true else { return }
        setLocalParam(block, spec.index, value)
        isDirty = true
        paramWriter?.yield((block, state.modelCode, spec.index, value))
    }

    private func setLocalParam(_ block: Block, _ index: Int, _ value: Int) {
        guard var state = blocks[block] else { return }
        if state.params.count <= index {
            state.params += [Int](repeating: 0, count: index + 1 - state.params.count)
        }
        state.params[index] = value
        blocks[block] = state
    }

    /// Send hand-typed hex bytes (MIDI monitor, for exploring the protocol).
    func sendRaw(hex: String) async {
        guard let device else { return }
        let bytes = hex.split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { UInt8($0, radix: 16) }
        guard !bytes.isEmpty else { return }
        log("→ " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        await run { try await device.sendRaw([bytes]) }
    }

    // MARK: Helpers

    private func run(_ operation: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func log(_ text: String) {
        monitor.append(MonitorLine(text: text))
        if monitor.count > 300 { monitor.removeFirst(monitor.count - 300) }
    }

    private func describe(_ event: PedalEvent) -> String {
        switch event {
        case let .paramChanged(block, code, param, value): "← \(block.title) модель \(code) параметр \(param) = \(value)"
        case let .modelChanged(block, code): "← \(block.title) модель = \(code)"
        case let .patchIndex(index): "← патч \(MiniProtocol.patchLabel(index))?"
        case let .patchSaved(index, name): "← сохранено \(MiniProtocol.patchLabel(index)) «\(name)»"
        case let .programChange(index): "← PC \(index)"
        case let .controlChange(cc, value): "← CC \(cc) = \(value)"
        case let .unknown(bytes): "← " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        case let .writeFailed(message): "✕ \(message)"
        case .heartbeat: "← heartbeat"
        }
    }
}
