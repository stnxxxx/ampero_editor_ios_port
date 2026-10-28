#if canImport(CoreMIDI)
import CoreMIDI
import Foundation

/// MIDI over CoreMIDI. The Ampero Mini's USB-MIDI interface is class compliant,
/// so on iPhone/iPad (USB-C, or Lightning + Camera Connection Kit) it shows up as
/// an ordinary MIDI source/destination pair without any driver.
public final class CoreMIDITransport: MIDITransport {
    public struct Endpoint: Identifiable, Hashable, Sendable {
        public let id: MIDIUniqueID
        public let name: String
        let ref: MIDIEndpointRef
    }

    public let incoming: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var source: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0
    // Touched only from CoreMIDI's receive thread.
    private var decoder = UMP.Decoder()

    /// Called (on a CoreMIDI thread) when devices are plugged in or removed.
    public var onSetupChanged: (@Sendable () -> Void)?

    public init(clientName: String = "Ampero Editor") throws {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .bufferingNewest(1024))
        incoming = stream
        self.continuation = continuation

        var status = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged { self?.onSetupChanged?() }
        }
        guard status == noErr else { throw TransportError.coreMIDI("MIDIClientCreate", status) }

        status = MIDIOutputPortCreate(client, "Ampero Out" as CFString, &outPort)
        guard status == noErr else { throw TransportError.coreMIDI("MIDIOutputPortCreate", status) }

        status = MIDIInputPortCreateWithProtocol(client, "Ampero In" as CFString, ._1_0, &inPort) { [weak self] list, _ in
            self?.receive(list)
        }
        guard status == noErr else { throw TransportError.coreMIDI("MIDIInputPortCreate", status) }
    }

    deinit {
        continuation.finish()
        MIDIClientDispose(client)
    }

    // MARK: Endpoints

    public static func sources() -> [Endpoint] {
        (0..<MIDIGetNumberOfSources()).map { endpoint(MIDIGetSource($0)) }
    }

    public static func destinations() -> [Endpoint] {
        (0..<MIDIGetNumberOfDestinations()).map { endpoint(MIDIGetDestination($0)) }
    }

    /// The first endpoint whose name looks like the pedal.
    public static func guessPedal(in endpoints: [Endpoint]) -> Endpoint? {
        let hints = ["ampero", "hotone", "mp-50", "mp50"]
        return endpoints.first { ep in hints.contains { ep.name.lowercased().contains($0) } }
    }

    private static func endpoint(_ ref: MIDIEndpointRef) -> Endpoint {
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &id)
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ref, kMIDIPropertyDisplayName, &name)
        return Endpoint(id: id, name: (name?.takeRetainedValue() as String?) ?? "MIDI \(id)", ref: ref)
    }

    // MARK: Connection

    public var isConnected: Bool { source != 0 && destination != 0 }

    public func connect(source newSource: Endpoint, destination newDestination: Endpoint) throws {
        disconnect()
        let status = MIDIPortConnectSource(inPort, newSource.ref, nil)
        guard status == noErr else { throw TransportError.coreMIDI("MIDIPortConnectSource", status) }
        source = newSource.ref
        destination = newDestination.ref
    }

    public func disconnect() {
        if source != 0 { MIDIPortDisconnectSource(inPort, source) }
        source = 0
        destination = 0
    }

    // MARK: I/O

    public func send(_ messages: [[UInt8]]) throws {
        guard destination != 0 else { throw TransportError.notConnected }
        let umps = messages.flatMap(UMP.encode)
        let wordCount = umps.reduce(0) { $0 + $1.count }
        let byteSize = MemoryLayout<MIDIEventList>.size + wordCount * 4 + 64

        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)

        // All words share one timestamp, so CoreMIDI keeps them in one packet. That is
        // what the save needs: the pedal only takes frames A and B sent together.
        var packet: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(list, ._1_0)
        for ump in umps {
            packet = ump.withUnsafeBufferPointer { words in
                MIDIEventListAdd(list, byteSize, packet!, 0, words.count, words.baseAddress!)
            }
            guard packet != nil else { throw TransportError.coreMIDI("MIDIEventListAdd", -1) }
        }
        let status = MIDISendEventList(outPort, destination, list)
        guard status == noErr else { throw TransportError.coreMIDI("MIDISendEventList", status) }
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words)!
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let base = (UnsafeRawPointer(packet) + wordsOffset).assumingMemoryBound(to: UInt32.self)
            let words = Array(UnsafeBufferPointer(start: base, count: count))
            for message in decoder.feed(words) {
                continuation.yield(message)
            }
        }
    }
}
#endif
