import LiftCore
import SwiftUI

/// The options form a recipe task's settings schema generates (spec §4): one control per setting,
/// `basic` ones first and the rest under "Advanced". Edits `values`; validation is LiftCore's.
struct SettingsForm: View {
    let defs: [SettingDef]
    @Binding var values: [String: SettingValue]
    let errors: (String) -> [String]
    @State private var advanced = false

    init(defs: [SettingDef], values: Binding<[String: SettingValue]>, errors: @escaping (String) -> [String] = { _ in [] }) {
        self.defs = defs
        _values = values
        self.errors = errors
    }

    var body: some View {
        let basic = defs.filter { ($0.group ?? "basic") == "basic" }
        let rest = defs.filter { ($0.group ?? "basic") != "basic" }
        ForEach(basic, id: \.key) { row($0) }
        if !rest.isEmpty {
            Disclosure("Advanced", isExpanded: $advanced) {
                ForEach(rest, id: \.key) { row($0) }
            }
        }
    }

    func row(_ def: SettingDef) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            control(def)
            if let help = def.help { Text(help).font(.caption).foregroundStyle(.secondary) }
            ForEach(errors(def.key), id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder func control(_ def: SettingDef) -> some View {
        switch def.type {
        case .bool:
            Toggle(def.label, isOn: Binding(get: { values[def.key] == .bool(true) }, set: { values[def.key] = .bool($0) }))
        case .int:
            TextField(def.label, value: Binding(get: { Int(values[def.key]?.description ?? "") ?? 0 }, set: { values[def.key] = .int($0) }),
                      format: .number.grouping(.never))
        case .float:
            TextField(def.label, value: Binding(get: { Double(values[def.key]?.description ?? "") ?? 0 }, set: { values[def.key] = .float($0) }),
                      format: .number.grouping(.never))
        case .enum:
            let options = def.options ?? []
            let picker = Picker(def.label, selection: Binding(get: { values[def.key] ?? options.first ?? .string("") }, set: { values[def.key] = $0 })) {
                ForEach(options, id: \.self) { Text($0.description).tag($0) }
            }
            if options.count <= 4 { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
        case .string, .path:
            TextField(def.label, text: Binding(get: { values[def.key]?.description ?? "" }, set: { values[def.key] = .string($0) }))
        }
    }
}
