import LiftCore
import SwiftUI

/// Shown on launch when jobs were loading or running when Lift last stopped (spec §7).
struct InterruptedSheet: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interrupted jobs").font(.title2).bold()
            Text("These jobs were running when Lift stopped. Re-queued jobs restart from the step that was interrupted; finished steps are kept.")
                .foregroundStyle(.secondary)
            List(app.interrupted, id: \.job.id) { v in
                VStack(alignment: .leading) {
                    Text(v.job.title).bold()
                    Text("Step \(v.job.currentStep + 1) of \(v.steps.count) · \(v.steps[min(v.job.currentStep, v.steps.count - 1)].recipe)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 160)
            HStack {
                Button("Decide Later") { app.showInterrupted = false }
                Spacer()
                Button("Discard", role: .destructive) { app.resolveInterrupted(.discard) }
                Button("Re-queue All") { app.resolveInterrupted(.requeue) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
