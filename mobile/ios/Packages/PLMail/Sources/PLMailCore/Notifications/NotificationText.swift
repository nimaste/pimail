import Foundation

/// Every word a notification says.
///
/// **In `PLMailCore`, not in `App/`.** A notification body is built outside
/// SwiftUI, so it cannot go through `Text(.ui(…))`, and `String(localized:)`
/// without an explicit bundle resolves against `Bundle.main` — the app — which
/// has no catalogue of its own. The lookup misses silently and falls through
/// to the English literal. The Android client shipped exactly that bug: a
/// German device read a German inbox out in English, in the one place in the
/// app the user cannot correct by looking somewhere else.
///
/// So the strings live in this module's catalogue, next to the other
/// non-SwiftUI strings, and every one of them is looked up with
/// `bundle: .module`.
public enum NotificationText {
    /// The banner's title when the sender has neither a name nor an address.
    public static var unknownSender: String {
        String(localized: "Unknown sender", bundle: .module)
    }

    /// Shown where the subject would be. A blank line there reads as a
    /// truncation bug rather than as mail with no subject.
    public static var noSubject: String {
        String(localized: "(no subject)", bundle: .module)
    }

    /// Reversible, and labelled so. Archive is not a delete and the action
    /// must not be styled or worded as one.
    public static var archive: String {
        String(localized: "Archive", bundle: .module)
    }

    public static var markAsRead: String {
        String(localized: "Mark as read", bundle: .module)
    }

    public static var reply: String {
        String(localized: "Reply", bundle: .module)
    }

    /// The button inside the inline reply field, as distinct from the action
    /// that opens it.
    public static var send: String {
        String(localized: "Send", bundle: .module)
    }

    public static var replyPlaceholder: String {
        String(localized: "Reply to this message", bundle: .module)
    }

    /// The failure banner's title. Says what did not happen, because "an error
    /// occurred" over a reply someone typed is the least useful sentence in
    /// the app.
    public static var replyFailedTitle: String {
        String(localized: "Your reply hasn't been sent", bundle: .module)
    }

    /// The reassurance that matters more than the failure: the words are not
    /// gone. Queued mail lives in Application Support, not in the cache, so
    /// this is a promise the app can actually keep.
    public static var replyFailedBody: String {
        String(localized: "It's queued and will go out when the server answers.", bundle: .module)
    }

    public static var tryAgain: String {
        String(localized: "Try again", bundle: .module)
    }

    /// Subtitle for a conversation that gained more than one message while
    /// nobody was looking.
    ///
    /// - Parameter count: Always two or more at the call site; the singular is
    ///   handled by not using this string at all.
    /// - Returns: The translated sentence, with the count already formatted.
    public static func moreMessages(_ count: Int) -> String {
        String(
            format: String(localized: "%lld new messages", bundle: .module),
            count)
    }
}
