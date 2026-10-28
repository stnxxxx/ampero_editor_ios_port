import SwiftUI

/// What the pedal broadcasts, plus a raw sender for exploring the protocol.
struct MIDIMonitorView: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rawHex = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("B0 30 7F", text: $rawHex)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Button("Отправить") { Task { await model.sendRaw(hex: rawHex) } }
                        .disabled(rawHex.isEmpty)
                } header: {
                    Text("Отправить байты (hex)")
                } footer: {
                    Text("Осторожно: неверные SysEx-кадры могут подвесить педаль до перезагрузки питания. Никогда не отправляйте 10 06 00 00 00.")
                }

                Section("Входящие") {
                    ForEach(model.monitor.reversed()) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.time, format: .dateTime.hour().minute().second())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(line.text)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("MIDI-монитор")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
