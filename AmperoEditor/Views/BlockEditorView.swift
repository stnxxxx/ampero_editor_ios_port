import AmperoKit
import SwiftUI

/// Model picker and parameters of the selected block.
struct BlockEditorView: View {
    @Environment(EditorModel.self) private var model
    let block: Block

    var body: some View {
        if let state = model.blocks[block] {
            let spec = model.catalog?.model(block, code: state.modelCode)
            Form {
                Section(block.title) {
                    Toggle("Включён", isOn: Binding(
                        get: { state.isOn },
                        set: { on in Task { await model.setBlock(block, on: on) } }
                    ))
                    Picker("Модель", selection: Binding(
                        get: { state.modelCode },
                        set: { code in Task { await model.setModel(block, code: code) } }
                    )) {
                        ForEach(model.catalog?.models(for: block) ?? []) { item in
                            Text(item.screen.map { String(format: "%02d  ", $0) + item.name } ?? item.name)
                                .tag(item.code)
                        }
                        if spec == nil {
                            Text("Неизвестная модель (\(state.modelCode))").tag(state.modelCode)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    if let basedOn = spec?.basedOn {
                        LabeledContent("Основана на", value: basedOn)
                    }
                }
                if let spec, !spec.params.isEmpty {
                    Section("Параметры") {
                        ForEach(spec.params) { param in
                            ParamRow(block: block, spec: param,
                                     raw: state.params.indices.contains(param.index) ? state.params[param.index] : 0)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("Нет данных пресета", systemImage: "slider.horizontal.3",
                                   description: Text("Прочитайте пресет с педали."))
        }
    }
}

private struct ParamRow: View {
    @Environment(EditorModel.self) private var model
    let block: Block
    let spec: ParamSpec
    let raw: Int

    var body: some View {
        switch spec.control {
        case .knob:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(spec.name)
                    Spacer()
                    Text(spec.format(raw))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(raw) },
                    set: { model.setParam(block, spec, raw: Int($0.rounded())) }
                ), in: sliderRange, step: 1)
                .accessibilityValue(spec.format(raw))
            }
        case .toggle:
            Toggle(spec.name, isOn: Binding(
                get: { raw != 0 },
                set: { model.setParam(block, spec, raw: $0 ? 1 : 0) }
            ))
        case .menu(let options):
            Picker(spec.name, selection: Binding(
                get: { raw },
                set: { model.setParam(block, spec, raw: $0) }
            )) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i]).tag(i)
                }
            }
        case .readOnly:
            LabeledContent(spec.name, value: spec.format(raw))
        }
    }

    private var sliderRange: ClosedRange<Double> {
        let lo = Double(spec.rawRange.lowerBound)
        return lo...max(Double(spec.rawRange.upperBound), lo + 1)
    }
}
