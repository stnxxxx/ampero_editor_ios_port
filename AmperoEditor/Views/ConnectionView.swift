import AmperoKit
import SwiftUI

struct ConnectionView: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Вход (от педали)", selection: $model.selectedSourceID) {
                        Text("Не выбран").tag(EditorModel.EndpointID?.none)
                        ForEach(model.sources) { Text($0.name).tag(EditorModel.EndpointID?.some($0.id)) }
                    }
                    Picker("Выход (к педали)", selection: $model.selectedDestinationID) {
                        Text("Не выбран").tag(EditorModel.EndpointID?.none)
                        ForEach(model.destinations) { Text($0.name).tag(EditorModel.EndpointID?.some($0.id)) }
                    }
                } header: {
                    Text("MIDI-порты")
                } footer: {
                    Text("Педаль определяется как USB-MIDI устройство без драйверов. Если её нет в списке — проверьте кабель (нужен кабель с передачей данных) и нажмите «Обновить».")
                }

                Section {
                    Button("Обновить список") { model.refreshEndpoints() }
                    if model.isConnected {
                        Button("Отключиться", role: .destructive) { model.disconnect() }
                    } else {
                        Button("Подключиться") {
                            Task {
                                await model.connect()
                                if model.isConnected { dismiss() }
                            }
                        }
                        .disabled(!model.canAutoConnect)
                    }
                }

                if case .failed(let message) = model.connection {
                    Section("Ошибка") { Text(message).foregroundStyle(.red) }
                }

                Section("О программе") {
                    LabeledContent("Каталог моделей", value: model.catalog?.firmware ?? (model.catalogError ?? "—"))
                    Text("Неофициальный редактор. Протокол восстановлен сообществом (проект ampero-bridge, MIT) и проверен на прошивке V2.2. Hotone не связан с этим приложением.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Подключение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear { model.refreshEndpoints() }
        }
    }
}
