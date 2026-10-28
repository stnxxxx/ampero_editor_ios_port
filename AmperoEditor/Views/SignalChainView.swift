import AmperoKit
import SwiftUI

/// The nine blocks in signal order. Tap selects a block, the power icon switches it.
struct SignalChainView: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Block.allCases) { block in
                    BlockTile(block: block)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }
}

private struct BlockTile: View {
    @Environment(EditorModel.self) private var model
    let block: Block

    var body: some View {
        let state = model.blocks[block]
        let isOn = state?.isOn ?? false
        let isSelected = model.selectedBlock == block
        let modelName = state.flatMap { model.catalog?.model(block, code: $0.modelCode)?.name } ?? "—"

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(block.title).font(.caption.bold())
                Spacer(minLength: 4)
                Button {
                    Task { await model.setBlock(block, on: !isOn) }
                } label: {
                    Image(systemName: "power")
                        .font(.caption.bold())
                        .foregroundStyle(isOn ? Color.green : Color.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isOn ? "Выключить \(block.title)" : "Включить \(block.title)")
            }
            Text(modelName)
                .font(.caption2)
                .lineLimit(2)
                .foregroundStyle(isOn ? .primary : .secondary)
        }
        .padding(8)
        .frame(width: 104, height: 72, alignment: .topLeading)
        .background(isOn ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { model.selectedBlock = block }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
