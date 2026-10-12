import AppKit
import LiftCore
import LiftServer
import LiftUI
import SwiftUI

@main
struct LiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Lift", id: "main") {
            RootView(app: delegate.app, onSidebarAppear: delegate.sidebarShown)
                .frame(minWidth: 860, minHeight: 600)
                .task { await delegate.start() }
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Lift") { openWindow(id: "about") }
            }
        }
        // About Lift → Credits (spec §4a): every model Lift runs, who made it and its license.
        Window("About Lift", id: "about") {
            CreditsView(app: delegate.app)
        }
        MenuBarExtra("Lift", systemImage: "cube.transparent", isInserted: menuBarInserted) {
            MenuBarView(app: delegate.app) {
                openWindow(id: "main")
                NSApplication.shared.activate()
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// "Keep running in the menu bar" (spec §11): the `menu_bar` setting.
    var menuBarInserted: Binding<Bool> {
        Binding(get: { delegate.app.settings.menuBar }, set: { on in
            delegate.app.setMenuBar(on)
        })
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `-LiftSmokeTest YES`: quit once the sidebar is on screen (App/smoke-test.sh). The smoke test passes an
    /// existing `-workdir` on the command line too, and keeps tokens in memory instead of the Keychain.
    let smokeTest = UserDefaults.standard.bool(forKey: "LiftSmokeTest")
    /// The smoke test skips the launch tools check (`checkPrereqs: nil`), so a Mac or CI runner without native
    /// Homebrew, git or uv still lands on the sidebar: it tests that the app starts, not this Mac's tools.
    lazy var app = AppModel(secrets: smokeTest ? MemorySecretStore() : CachedSecretStore(KeychainSecretStore()),
                            checkPrereqs: smokeTest ? nil : AppModel.detectPrereqs)
    var notifier: Notifier?

    func start() async {
        guard app.phase == .loading else { return }  // the window can reappear; start once
        if !smokeTest {
            let notifier = Notifier()
            self.notifier = notifier
            app.onEvent = { [weak self] event in
                if self?.app.settings.notifications == true { notifier.post(event) }
            }
            app.applyLaunchAtLogin = { try LoginItem.set($0) }
            app.launchAtLoginEnabled = { LoginItem.isEnabled }
            // The real claude/codex and Claude's settings file: never in the smoke test.
            app.assistants.makeConnector = { AssistantConnector(mcpURL: $0, skill: $1) }
        }
        await app.start()
    }

    func sidebarShown(_ titles: [String]) {
        guard smokeTest else { return }
        print("LIFT_SMOKE sidebar: \(titles.joined(separator: ", "))")
        NSApplication.shared.terminate(nil)
    }

    /// With the menu bar extra on, closing the window keeps the queue and server running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !app.settings.menuBar
    }

    /// Stops workers and the server before quitting; running jobs come back as interrupted next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await app.close()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
