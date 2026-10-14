import Foundation
import LiftCore

/// A model in plain words: what it does, who made it, how big it is, what it asks of you and its limits.
public struct ModelCard: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The image → 3D task's own label, e.g. "Photo → 3D model" (else the first task's).
    public var task: String
    public var description: String?
    /// "by <authors> · <license>".
    public var credit: String
    /// The weights' size when Hugging Face reported it, else the recipe's estimate.
    public var size: String?
    /// Hugging Face repos whose authors ask you to accept their terms first.
    public var gated: [String]
    /// One line per restricted component, e.g. "Not for commercial use: RMBG-2.0 by BRIA AI (CC-BY-NC-4.0)".
    public var restrictions: [String]

    public init(_ m: ModelView, weightsBytes: Int?) {
        let r = m.recipe, a = r.attribution
        id = m.id
        name = m.name
        task = (r.tasks.first { $0.inputs.first?.type == .image && $0.output == .mesh } ?? r.tasks.first)?.label ?? ""
        description = r.description
        credit = "by \(a.authors.joined(separator: ", ")) · \(a.license.spdx)"
        let bytes = weightsBytes ?? Int(r.resources.diskGB * 1_000_000_000)
        size = bytes > 0 ? "About " + (Double(bytes) / 1e9).formatted(.number.precision(.fractionLength(0...1))) + " GB" : nil
        gated = r.weights.filter(\.gated).map(\.repo)
        restrictions = a.components.flatMap { c in
            let other = c.restrictions.filter { $0 != "non-commercial" }
            return (c.restrictions.contains("non-commercial") ? ["Not for commercial use: \(c.name) (\(c.license.spdx))"] : [])
                + (other.isEmpty ? [] : ["\(c.name): \(other.joined(separator: "; "))"])
        }
    }
}
