import BackgroundTasks
import OSLog
import PLMailCore

/// Registers and schedules the periodic background pull.
///
/// Fifteen minutes, matching the server's own scheduled sync. Being more
/// eager buys nothing — the mail is not there yet — and costs a wake-up on a
/// device and a request against someone's home server.
///
/// This is not push. Without APNs there is no true background delivery, and
/// the UI says "last checked" rather than pretending otherwise.
enum BackgroundRefresh {
    static let identifier = "de.plmail.refresh"
    private static let logger = Logger(subsystem: "de.plmail", category: "background")

    /// - Parameters:
    ///   - refresh: The pull itself.
    ///   - expire: Called when the system gives its few seconds' notice that
    ///     the task is about to be killed. Cancelling the enclosing `Task` is
    ///     not enough on its own: the body prefetcher checks a flag of its own
    ///     because the expiration handler does not run on the task that
    ///     started the run, and a background task that ignores its expiration
    ///     has the app's background time revoked — which costs every future
    ///     refresh, not just this one.
    static func register(
        refresh: @escaping @Sendable () async -> Void,
        expire: @escaping @Sendable () -> Void = {}
    ) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            // Rescheduled first: a run that crashes or is cut short must not
            // be the last one that was ever scheduled.
            schedule()

            // The task object is not Sendable, so completion is signalled
            // through a value the closure can safely capture.
            nonisolated(unsafe) let bgTask = task

            let work = Task {
                await refresh()
                bgTask.setTaskCompleted(success: true)
            }

            bgTask.expirationHandler = {
                expire()
                work.cancel()
                logger.notice("Background refresh expired before finishing.")
            }
        }
    }

    /// - Parameter due: When the outbox next has something to send, if it has.
    ///   Asking earlier than the usual quarter of an hour is worth it only for
    ///   mail somebody scheduled — and it is a request, not a guarantee: the
    ///   system grants these on its own budget, so a message may still go out
    ///   after its time rather than at it.
    static func schedule(noLaterThan due: Date? = nil) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        let usual = Date.now.addingTimeInterval(15 * 60)

        request.earliestBeginDate = [usual, due].compactMap { $0 }.min()

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected in the simulator and whenever the user has switched
            // Background App Refresh off — not worth surfacing.
            logger.debug("Could not schedule: \(error, privacy: .public)")
        }
    }
}
