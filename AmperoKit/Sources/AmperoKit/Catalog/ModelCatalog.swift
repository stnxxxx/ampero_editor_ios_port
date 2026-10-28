import Foundation

/// One editable parameter of a model, with its raw (wire) range and how to show it.
public struct ParamSpec: Identifiable, Sendable, Hashable {
    public enum Control: Sendable, Hashable {
        case knob
        case toggle
        case menu([String])
        /// Not editable from the app (text fields, unknown encodings).
        case readOnly
    }

    public let index: Int
    public let name: String
    public let control: Control
    public let rawRange: ClosedRange<Int>
    let displayMin: Double
    let displayMax: Double
    let step: Double
    let valueType: Int?

    public var id: Int { index }

    /// The value as the pedal screen shows it.
    public func format(_ raw: Int) -> String {
        switch control {
        case .toggle:
            return raw != 0 ? "On" : "Off"
        case .menu(let options):
            return options.indices.contains(raw) ? options[raw] : "\(raw)"
        case .readOnly, .knob:
            break
        }
        switch valueType {
        case 4: return raw == 0 ? "Off" : "\(raw + 19) Hz"                  // CAB Low Cut
        case 5: return raw >= 1801 ? "Off" : "\(2000 + 10 * raw) Hz"        // CAB High Cut
        case 2: return Self.number(Double(raw) - (displayMax - displayMin), step: step)
        default: return Self.number(displayMin + Double(raw) * step, step: step)
        }
    }

    static func number(_ value: Double, step: Double) -> String {
        let decimals = step >= 1 ? 0 : (step >= 0.1 ? 1 : 2)
        return String(format: "%.\(decimals)f", value)
    }
}

public struct ModelSpec: Identifiable, Sendable, Hashable {
    public let code: Int
    public let name: String
    /// 1-based position in the pedal/editor list.
    public let screen: Int?
    /// Real-world gear the model is based on, when Hotone lists one.
    public let basedOn: String?
    public let params: [ParamSpec]

    public var id: Int { code }
}

/// Model names, codes and parameters for each block (firmware V2.2), from the
/// ampero-bridge param map, which merges live pedal captures with the official
/// editor's algorithm_50.xml.
public struct ModelCatalog: Sendable {
    public let models: [Block: [ModelSpec]]
    public let firmware: String

    public func models(for block: Block) -> [ModelSpec] { models[block] ?? [] }

    public func model(_ block: Block, code: Int) -> ModelSpec? {
        models[block]?.first { $0.code == code }
    }

    public static func loadBundled() throws -> ModelCatalog {
        func resource(_ name: String) throws -> Data {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try Data(contentsOf: url)
        }
        return try load(lists: resource("model-lists"), paramMap: resource("param-map"))
    }

    /// `lists`: model names and codes per block, in screen order.
    /// `paramMap`: parameters per model code (CAB models share one layout keyed `ALL`).
    public static func load(lists: Data, paramMap: Data) throws -> ModelCatalog {
        let decoder = JSONDecoder()
        let lists = try decoder.decode(RawLists.self, from: lists)
        let map = try decoder.decode(RawMap.self, from: paramMap)

        var result: [Block: [ModelSpec]] = [:]
        for block in Block.allCases {
            let paramModels = map.blocks[block.rawValue]?.models ?? [:]
            let entries = lists.blocks[block.rawValue] ?? []
            result[block] = entries.map { entry in
                let rawParams = (paramModels[String(entry.code)] ?? paramModels["ALL"])?.params ?? [:]
                let params = rawParams
                    .compactMap { index, p in Int(index).map { p.spec(index: $0) } }
                    .sorted { $0.index < $1.index }
                return ModelSpec(code: entry.code, name: entry.name, screen: entry.screen,
                                 basedOn: entry.based_on, params: params)
            }
            .sorted { ($0.screen ?? 10_000 + $0.code, $0.code) < ($1.screen ?? 10_000 + $1.code, $1.code) }
        }
        return ModelCatalog(models: result, firmware: map.pedal ?? "fw 2.2")
    }
}

// MARK: - JSON shape of param-map.json (only the fields the app needs)

private struct RawLists: Decodable {
    struct Entry: Decodable {
        let code: Int
        let screen: Int?
        let name: String
        let based_on: String?
    }
    let blocks: [String: [Entry]]
}

private struct RawMap: Decodable {
    let pedal: String?
    let blocks: [String: RawBlock]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pedal = try? c.decode(String.self, forKey: .pedal)
        blocks = try c.decode([String: RawBlock].self, forKey: .blocks)
    }

    enum CodingKeys: String, CodingKey { case pedal, blocks }
}

private struct RawBlock: Decodable {
    let models: [String: RawModel]
}

private struct RawModel: Decodable {
    let name: String?
    let editor_screen: LenientNumber?
    let params: [String: RawParam]?
}

private struct RawParam: Decodable {
    struct Definition: Decodable {
        struct Item: Decodable { let Name: LenientString? }
        let control_type: String?
        let editor_attributes: [String: LenientString]?
        let selector_items: [Item]?
    }

    struct EnumItem: Decodable {
        let value: LenientNumber?
        let label: LenientString?
    }

    let name: String?
    let editor_definition: Definition?
    let editor_enum: [EnumItem]?
    let editor_display_range: [LenientNumber]?
    let editor_control_range: [LenientNumber]?
    let valid_range: [LenientNumber]?

    func spec(index: Int) -> ParamSpec {
        let attrs = editor_definition?.editor_attributes ?? [:]
        func attr(_ key: String) -> Double? { attrs[key].flatMap { Double($0.value) } }
        func range(_ values: [LenientNumber]?) -> (Double, Double)? {
            guard let values, values.count == 2, let lo = values[0].value, let hi = values[1].value else { return nil }
            return (lo, hi)
        }

        let step = attr("Step").flatMap { $0 > 0 ? $0 : nil } ?? 1
        let display = range(editor_display_range)
        let valueType = attr("valueType").map { Int($0) }
        let options: [String] = {
            let labels: [String?]
            if let e = editor_enum, !e.isEmpty {
                labels = e.sorted { ($0.value?.value ?? 0) < ($1.value?.value ?? 0) }.map { $0.label?.value }
            } else {
                labels = (editor_definition?.selector_items ?? []).map { $0.Name?.value }
            }
            return labels.enumerated().map { i, label in
                let trimmed = label?.trimmingCharacters(in: .whitespaces) ?? ""
                return trimmed.isEmpty ? "\(i + 1)" : trimmed
            }
        }()

        var control: ParamSpec.Control
        var raw: ClosedRange<Int>?
        switch editor_definition?.control_type {
        case "Switch":
            control = .toggle
            raw = 0...1
        case "Combox" where !options.isEmpty:
            control = .menu(options)
            raw = 0...(options.count - 1)
        case "Knob", "Slider", "TextEditor":   // TextEditor = CAB mic position X/Y/Z, 0-100
            control = .knob
            if let d = display {
                raw = 0...Int(((d.1 - d.0) / step).rounded())
            } else if let lo = attr("Min"), let hi = attr("Max") {
                raw = Int(lo)...Int(hi)
            } else if let c = range(editor_control_range) {
                raw = Int(c.0)...Int(c.1)
            }
        default:
            control = .readOnly
        }
        // Ranges proven on a pedal win over anything derived from the editor.
        if let v = range(valid_range) { raw = Int(v.0)...Int(v.1) }
        if raw == nil { control = .readOnly }

        return ParamSpec(index: index, name: name ?? attrs["Name"]?.value ?? "P\(index + 1)",
                         control: control, rawRange: raw ?? 0...0,
                         displayMin: display?.0 ?? 0, displayMax: display?.1 ?? 0,
                         step: step, valueType: valueType)
    }
}

/// Decodes a string, number or bool as a string.
private struct LenientString: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else if let b = try? c.decode(Bool.self) { value = String(b) }
        else { value = "" }
    }
}

/// Decodes a number or numeric string; nil for null or anything else.
private struct LenientNumber: Decodable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = Double(s) }
        else { value = nil }
    }
}
