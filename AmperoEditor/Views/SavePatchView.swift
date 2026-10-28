import AmperoKit
import SwiftUI

struct SavePatchView: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = 0

    private var nameError: String? {
        (try? MiniProtocol.encodeName(name)) == nil ? "До 18 символов, только латиница, цифры и знаки ASCII" : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Имя пресета", text: $name)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                    if let nameError {
                        Text(nameError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Имя")
                }

                Section {
                    Picker("Ячейка", selection: $target) {
                        ForEach(0..<MiniProtocol.patchCount, id: \.self) { index in
                            Text("\(MiniProtocol.patchLabel(index))  \(model.patchNames[index] ?? "")").tag(index)
                        }
                    }
                } footer: {
                    Text("Сохраняется текущее состояние педали (буфер редактирования). Содержимое выбранной ячейки будет перезаписано. Педаль не подтверждает сохранение — проверьте результат на её экране.")
                }
            }
            .navigationTitle("Сохранить пресет")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task {
                            await model.save(name: name, to: target)
                            dismiss()
                        }
                    }
                    .disabled(nameError != nil)
                }
            }
            .onAppear {
                name = model.patchName
                target = model.patchIndex ?? 0
            }
        }
    }
}
