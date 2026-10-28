import AmperoKit
import SwiftUI

struct PatchListView: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmScan = false

    var body: some View {
        NavigationStack {
            List(0..<MiniProtocol.patchCount, id: \.self) { index in
                Button {
                    Task {
                        await model.selectPatch(index)
                        dismiss()
                    }
                } label: {
                    HStack {
                        Text(MiniProtocol.patchLabel(index))
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(model.patchNames[index] ?? "—")
                        Spacer()
                        if index == model.patchIndex {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Пресеты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Прочитать имена") { confirmScan = true }
                        .disabled(model.scanProgress != nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let progress = model.scanProgress {
                    ProgressView(value: progress) { Text("Чтение пресетов…") }
                        .padding()
                        .background(.bar)
                }
            }
            .confirmationDialog("Прочитать имена всех пресетов?", isPresented: $confirmScan, titleVisibility: .visible) {
                Button("Прочитать") { Task { await model.scanPatchNames() } }
            } message: {
                Text("Педаль по очереди переключит все 99 пресетов (это слышно) и вернётся на текущий. Займёт несколько минут. Несохранённые изменения текущего пресета будут потеряны.")
            }
        }
    }
}
