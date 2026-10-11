import LiftCore
import SwiftUI

/// The numbered Hugging Face checklist (spec §1): account, each gated repo's terms with its live status, a Read
/// key, then paste and Check. Used by the install flow's sheet and by Settings → Hugging Face.
struct HFAccessView: View {
    let app: AppModel
    @Bindable var access: HFAccess
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                row(1, "Sign in to or create a free Hugging Face account", status: access.user.map { "Connected as \($0) ✓" }) {
                    Button("Open Hugging Face") { openURL(URL(string: "https://huggingface.co/join")!) }
                }
                ForEach(Array(access.repos.enumerated()), id: \.element) { i, repo in
                    Divider()
                    row(2 + i, "Accept the terms for \(access.names[i]) (\(repo))", status: repoStatus(repo)) {
                        Button("Open Page") { openURL(URL(string: "https://huggingface.co/\(repo)")!) }
                            .accessibilityLabel("Open the page for \(repo)")
                    }
                    if access.user != nil && access.repoAccess[repo] != true {
                        HStack {
                            Label(access.unchecked.contains(repo) ? "Lift couldn't check \(repo) just now." : access.notAccepted(repo),
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Check Again") { Task { await access.check(app) } }.disabled(access.busy)
                                .accessibilityLabel("Check \(repo) again")
                        }
                        .padding(.horizontal, 16).padding(.leading, 38).padding(.bottom, 12)
                    }
                }
                Divider()
                row(2 + access.repos.count, "Create a key (Hugging Face calls it an access token) — choose “Read”", status: nil) {
                    Button("Open Token Page") { openURL(URL(string: "https://huggingface.co/settings/tokens/new?tokenType=read")!) }
                }
                Divider()
                row(3 + access.repos.count, "Paste the key here. Lift keeps it in your Mac's Keychain.", status: nil) {
                    HStack {
                        SecureField("hf_…", text: $access.token).frame(width: 220).accessibilityLabel("Hugging Face key")
                            .onSubmit { Task { await access.check(app) } }
                        Button(access.user == nil ? "Check" : "Check Again") { Task { await access.check(app) } }.disabled(access.busy)
                    }
                    .fixedSize()
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            if access.busy { ProgressView().controlSize(.small) }
            if let problem = access.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .task { if access.user == nil && app.secrets.get(.hfToken) != nil { await access.check(app) } }
    }

    func repoStatus(_ repo: String) -> String {
        access.repoAccess[repo] == true ? "Access granted ✓" : access.user == nil ? "Waiting for your key" : "Not accepted yet"
    }

    func row(_ n: Int, _ title: String, status: String?, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(.headline).foregroundStyle(.white).frame(width: 26, height: 26).background(Circle().fill(.tint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let status {
                    Text(status).font(.callout).foregroundStyle(status.hasSuffix("✓") ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(n): \(title)\(status.map { ". \($0)" } ?? "")")
            Spacer()
            action()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// Before installing a model with gated weights while no key is kept: why, the checklist, then Continue on to
/// the install's own confirmation once the key is valid ("Continue anyway" while a repo's terms are still open).
struct HFAccessSheet: View {
    let app: AppModel
    let access: HFAccess

    var body: some View {
        let name = access.model?.name ?? "This model"
        VStack(alignment: .leading, spacing: 14) {
            Text("One more step for \(name)").font(.title2).bold()
            Text("\(name) uses \(ListFormatter.localizedString(byJoining: access.names)), whose authors ask you to accept their terms first. It's free.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView { HFAccessView(app: app, access: access) }
            HStack {
                Spacer()
                Button("Not Now", role: .cancel) { app.accessBeforeInstall = nil }.keyboardShortcut(.cancelAction)
                Button(access.continueLabel) { app.continueAfterAccess() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!access.canContinue)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}
