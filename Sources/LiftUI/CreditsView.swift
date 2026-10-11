import LiftCore
import SwiftUI

/// About Lift → Credits (spec §4a): every model Lift ships, everything each one uses, and the licenses.
public struct CreditsView: View {
    let app: AppModel

    public init(app: AppModel) { self.app = app }

    /// One entry per project, in name order (a project used by two recipes is listed once).
    nonisolated static func attributions(_ models: [ModelView]) -> [Attribution] {
        var seen = Set<String>()
        return models.map(\.recipe.attribution).sorted { $0.project < $1.project }.filter { seen.insert($0.project).inserted }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Lift").font(.largeTitle).bold()
                Text("Lift runs other people's open-source projects on your Mac. They made the models; Lift only installs and runs them.")
                    .foregroundStyle(.secondary)
                ForEach(Self.attributions(app.models), id: \.project) { a in
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.project).font(.headline)
                        Text("by " + a.authors.joined(separator: ", ")).foregroundStyle(.secondary)
                        HStack {
                            Link("Project page", destination: a.homepage)
                            Link("License: \(a.license.spdx)", destination: a.license.url)
                        }
                        .font(.callout)
                        ForEach(a.components.indices, id: \.self) { i in
                            let c = a.components[i]
                            HStack(alignment: .firstTextBaseline) {
                                Link(c.name, destination: c.url)
                                Text("· \(c.role) ·").foregroundStyle(.secondary)
                                Link(c.license.spdx, destination: c.license.url)
                                if !c.restrictions.isEmpty { Text(c.restrictions.joined(separator: ", ")).foregroundStyle(.orange) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
