import Foundation

/// Byte-level MIDI pipe to the pedal. Each message is one complete MIDI 1.0
/// message (a channel message or a whole `F0 … F7` SysEx frame).
public protocol MIDITransport: AnyObject {
    /// Every complete message the pedal sends.
    var incoming: AsyncStream<[UInt8]> { get }
    /// Sends the messages back to back in one batch (one CoreMIDI event list).
    func send(_ messages: [[UInt8]]) throws
}

public enum TransportError: Error, LocalizedError {
    case coreMIDI(String, OSStatus)
    case notConnected
    case endpointNotFound

    public var errorDescription: String? {
        switch self {
        case .coreMIDI(let call, let status): "CoreMIDI: \(call) вернул \(status)"
        case .notConnected: "Педаль не подключена"
        case .endpointNotFound: "MIDI-порт педали не найден"
        }
    }
}
