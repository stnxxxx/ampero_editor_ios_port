import AmperoKit
import SwiftUI

struct ContentView: View {
    @Environment(EditorModel.self) private var model
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case patches, connection, monitor, save
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isConnected {
                    editor
                } else {
                    disconnected
                }
            }
            .navigationTitle("Ampero Mini")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(item: $sheet) { which in
                Group {
                    switch which {
                    case .patches: PatchListView()
                    case .connection: ConnectionView()
                    case .monitor: MIDIMonitorView()
                    case .save: SavePatchView()
                    }
                }
                .environment(model)
            }
            .alert("Ошибка", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .task {
            model.refreshEndpoints()
            if model.canAutoConnect { await model.connect() }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            PatchHeaderView { sheet = .patches }
            SignalChainView()
            Divider()
            BlockEditorView(block: model.selectedBlock)
        }
        .overlay(alignment: .top) {
            if model.isBusy {
                ProgressView().padding(8).background(.thinMaterial, in: Capsule()).padding(.top, 4)
            }
        }
    }

    private var disconnected: some View {
        ContentUnavailableView {
            Label(statusText, systemImage: "cable.connector.slash")
        } description: {
            Text("Подключите Ampero Mini кабелем USB-C к iPhone/iPad (для Lightning нужен Camera Connection Kit) и включите педаль.")
        } actions: {
            Button("Настроить подключение") { sheet = .connection }
                .buttonStyle(.borderedProminent)
        }
    }

    private var statusText: String {
        switch model.connection {
        case .disconnected: "Педаль не подключена"
        case .connecting: "Подключение…"
        case .connected(let name): name
        case .failed(let error): "Ошибка: \(error)"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { sheet = .connection } label: {
                Image(systemName: model.isConnected ? "cable.connector" : "cable.connector.slash")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { sheet = .save } label: { Image(systemName: "square.and.arrow.down") }
                .disabled(!model.isConnected || model.patchIndex == nil)
            Menu {
                Button("Пресеты", systemImage: "list.bullet") { sheet = .patches }
                Button("Перечитать с педали", systemImage: "arrow.clockwise") {
                    Task { await model.reloadCurrent() }
                }
                Button("MIDI-монитор", systemImage: "waveform") { sheet = .monitor }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(!model.isConnected)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

struct PatchHeaderView: View {
    @Environment(EditorModel.self) private var model
    let openList: () -> Void

    var body: some View {
        HStack {
            Button { Task { await model.step(by: -1) } } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            Button(action: openList) {
                VStack(spacing: 2) {
                    Text(model.patchIndex.map(MiniProtocol.patchLabel) ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(model.patchName.isEmpty ? "Без имени" : model.patchName)
                            .font(.title2.bold())
                            .lineLimit(1)
                        if model.isDirty {
                            Circle().fill(.orange).frame(width: 8, height: 8)
                                .accessibilityLabel("Есть несохранённые изменения")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            Button { Task { await model.step(by: 1) } } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
