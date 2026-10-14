import OSLog
import PLMailCore
import UIKit
import UserNotifications

/// The bit of push that has to be a `UIApplicationDelegate`.
///
/// SwiftUI has no equivalent hook for the device token — the callback is only
/// delivered to an app delegate — so this exists purely to catch it and hand
/// it on.
///
/// **The honesty rule this enforces.** A push here means "something changed",
/// never "here is your mail": the payload carries no subject, no sender and no
/// body, so nothing about the mail passes through Apple. That means the
/// notification cannot say who wrote to you until the app has fetched, which
/// is a deliberate trade — a self-hosted mail client whose whole point is that
/// the mail stays on your server should not be relaying its contents through a
/// third party for the sake of a nicer banner.
@MainActor
final class PushDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "de.plmail", category: "push")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        logger.notice("Push delegate installed.")

        // Set here rather than from the scene: a notification action taken
        // while the app is not running is delivered as part of launch, and a
        // delegate assigned any later than this misses it entirely — the
        // press appears to do nothing.
        UNUserNotificationCenter.current().delegate = self

        return true
    }

    /// Set by the app once it has a connection to register against.
    var onToken: ((Data) async -> Void)?
    /// Called when a push says the mailbox moved.
    var onSilentPush: (() async -> Void)?
    /// Called when someone presses an action on a banner, or taps one.
    var onNotificationResponse: ((UNNotificationResponse) async -> Void)?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        logger.info("Device token received (\(deviceToken.count) bytes).")

        Task { await onToken?(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // Routine on a simulator without a push entitlement, and not worth a
        // dialog anywhere: the app already refreshes on foreground and in the
        // background, so the failure costs latency, not mail.
        NSLog("Remote notification registration failed: \(error.localizedDescription)")
    }

    /// A silent push.
    ///
    /// The completion-handler form, not the `async` one. The async variant
    /// compiles and looks equivalent, but UIKit never called it — the system
    /// log showed `UIFetchContentInBackgroundAction` being delivered to the
    /// scene while this method sat unused. Only the selector below is looked
    /// up.
    ///
    /// The result matters: iOS throttles an app that reports `.newData` every
    /// time and delivers nothing, so an unconnected app says `.noData` and
    /// means it.
    @objc func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler:
            @escaping (UIBackgroundFetchResult) -> Void
    ) {
        logger.notice("Silent push received.")

        // `@objc` and not `nonisolated`, both deliberately. Without `@objc`
        // the selector is not emitted at all and UIKit answers the fetch
        // action itself — the system log shows it decoded and replied to in
        // the same millisecond, with nothing in between. Marking it
        // `nonisolated` had the same effect.
        let finish = UncheckedSendable(completionHandler)

        Task { @MainActor in
            guard let onSilentPush else {
                logger.info("Nothing signed in; ignoring the push.")
                finish.value(.noData)

                return
            }

            await onSilentPush()
            logger.notice("Silent push handled.")
            finish.value(.newData)
        }
    }
}

/// The half of notifications that is not push at all.
///
/// Local notifications for new mail need no APNs key, no App Group and no paid
/// account: a background refresh that finds mail can post one today. The
/// delegate is shared with push only because iOS has exactly one — the two
/// mechanisms are otherwise unrelated, and conflating them is what left this
/// app posting nothing.
extension PushDelegate: UNUserNotificationCenterDelegate {
    /// A press on Archive, Mark as read or Reply — or a tap on the banner.
    ///
    /// The completion handler form again, for the same reason as the silent
    /// push above: the `async` variant is not the selector UIKit looks up, and
    /// the app is suspended the moment this returns. Calling it early would
    /// cut the server request off mid-flight.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let finish = UncheckedSendable(completionHandler)
        let carried = UncheckedSendable(response)

        Task { @MainActor in
            await onNotificationResponse?(carried.value)
            finish.value()
        }
    }

    /// What a banner does while the app is open.
    ///
    /// `.list` and `.badge`, never `.banner`. Mail arriving in a list someone
    /// is already looking at does not need a card drawn over the top of it —
    /// the row appears by itself — but it does belong in Notification Centre
    /// afterwards, so it is there when they put the phone down.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.list, .badge])
    }
}

extension PushDelegate {
    /// Asks for permission and registers.
    ///
    /// Deliberately **not** called at first launch, and not called at all
    /// unless the server says it can actually send a push. A permission prompt
    /// before someone has seen a single message is the prompt everybody
    /// denies, and a denial is close to permanent — it can only be undone in
    /// Settings. Spending that one chance on a server with no APNs sender,
    /// where granting it would deliver precisely nothing, is worse than not
    /// asking.
    static func requestAuthorization() async {
        let centre = UNUserNotificationCenter.current()

        guard
            let granted = try? await centre.requestAuthorization(options: [.alert, .badge, .sound]),
            granted
        else { return }

        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Registers for silent pushes only, which needs no permission at all.
    ///
    /// Worth doing even when someone has refused notifications: a silent push
    /// still wakes the app to sync, so the mail is already there when they
    /// next look. Refusing banners is not the same as refusing fresh mail.
    static func registerForSilentPushes() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// UIKit's completion handler, carried across an actor hop.
///
/// Safe because it is called exactly once, on the main actor, and UIKit's own
/// contract is that it may be called from any thread.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
