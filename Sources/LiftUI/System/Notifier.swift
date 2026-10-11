import AppKit
import LiftCore
@preconcurrency import UserNotifications

/// macOS notifications for job events (spec §8, §11), with a Reveal in Finder action.
/// Needs a real app bundle: UNUserNotificationCenter isn't available to bare executables or test runners.
@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let reveal = "reveal"
    nonisolated static let category = "job"

    public override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.reveal, title: "Reveal in Finder")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [action], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func post(_ event: JobEvent) {
        let content = Self.content(event)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// The text of each notification; facts only.
    static func content(_ event: JobEvent) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.categoryIdentifier = category
        switch event {
        case .finished(let v):
            c.title = v.job.state == .succeeded ? "Finished: \(v.job.title)" : "Failed: \(v.job.title)"
            c.body = v.job.state == .succeeded ? v.outputs.map { URL(filePath: $0).lastPathComponent }.joined(separator: ", ") : (v.job.error ?? "")
            if let path = v.outputs.first { c.userInfo = ["path": path] }
        case .waitingForMemory(let v):
            c.title = "Waiting for memory: \(v.job.title)"
            c.body = Format.waitReason(v.job.waitReason)
        }
        return c
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Self.reveal, let path = response.notification.request.content.userInfo["path"] as? String else { return }
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
