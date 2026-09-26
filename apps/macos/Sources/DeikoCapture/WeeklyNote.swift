import AppKit
import UserNotifications

// ─────────────────────────────────────────────────────────────────────────────
// THE MONDAY NOTE. Optional, off unless turned on in Settings: once a week,
// on Monday from 9 in the morning, one notification says how many pieces of
// work moved in the last seven days and how many still have something open.
// Clicking it opens the Dashboard's "This week". Built from the board on this
// Mac (`WeekDigest.load`); nothing is sent anywhere. A week nothing moved
// gets no note at all.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class WeeklyNote: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WeeklyNote()
    static let key = "DEIKO_WEEKLY_NOTE"
    private static let lastKey = "DEIKO_WEEKLY_NOTE_LAST"

    /// Where a click on the note goes.
    var onOpen: (() -> Void)?
    private var timer: Timer?

    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    /// Notifications need a real app bundle; a bare build (`swift run`,
    /// `ui-shot`) has none, and asking would stop the process.
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        if on, canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
    }

    func start() {
        guard Self.canNotify else { return }
        UNUserNotificationCenter.current().delegate = self
        // Hourly is plenty for a note that comes once a week.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await WeeklyNote.shared.checkNow() }
        }
        Task { await checkNow() }
    }

    func checkNow() async {
        guard Self.enabled else { return }
        let calendar = Calendar.current
        let now = Date()
        guard calendar.component(.weekday, from: now) == 2, calendar.component(.hour, from: now) >= 9 else { return }
        let week = "\(calendar.component(.yearForWeekOfYear, from: now))-\(calendar.component(.weekOfYear, from: now))"
        guard UserDefaults.standard.string(forKey: Self.lastKey) != week else { return }
        await SessionsStore.shared.load(root: Collections.root)
        let rows = await WeekDigest.load(SessionsStore.shared)
        UserDefaults.standard.set(week, forKey: Self.lastKey)
        guard !rows.isEmpty else { return }
        let open = rows.filter { !$0.open.isEmpty }.count
        let content = UNMutableNotificationContent()
        content.title = "Where things stand"
        content.body = "\(rows.count) piece\(rows.count == 1 ? "" : "s") of work moved last week"
            + (open > 0 ? ", and \(open) still \(open == 1 ? "has" : "have") something open." : ".")
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "weekly-\(week)", content: content, trigger: nil)
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { onOpen?() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
