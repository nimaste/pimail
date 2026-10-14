import Foundation
import JMAPKit

/// What this server will actually accept as an attachment.
///
/// Read from the Session rather than invented. Both numbers are published and
/// were read by nobody: `maxSizeUpload` on core, `maxSizeAttachmentsPerEmail`
/// on the mail account. Without them the composer let someone add ten 4K videos
/// — held in memory, written to the outbox, and held again while the request
/// was built — and the app was terminated before they learned the server would
/// have refused the first one.
public struct AttachmentLimits: Hashable, Sendable {
    /// The ceiling on one upload. Over it the server answers `tooLarge` / 413,
    /// which arrives as a failed send long after the composer has closed.
    public var maxFileBytes: Int

    /// The ceiling on everything attached to one message.
    public var maxTotalBytes: Int

    /// Used until the Session has been read.
    ///
    /// Deliberately the same 50 MB plMail publishes rather than something
    /// smaller: a floor that refused a file this server would have taken is a
    /// worse failure than one refusal arriving a moment late, because the user
    /// has no way to tell it is the app's opinion rather than the server's.
    public static let unknown = AttachmentLimits(
        maxFileBytes: 50_000_000, maxTotalBytes: 50_000_000)

    public init(maxFileBytes: Int, maxTotalBytes: Int) {
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
    }

    /// Reads the limits this account is actually under.
    ///
    /// Falls back per field rather than wholesale: an instance that publishes
    /// core's limits but not the mail account's is answerable, and refusing to
    /// attach anything at all because one key was absent would be the app
    /// breaking itself over a server that is merely terse.
    public init(session: Session, accountID: AccountID) {
        let perEmail = session.accounts[accountID]?
            .accountCapabilities.mail?.maxSizeAttachmentsPerEmail

        maxFileBytes = session.capabilities.core.maxSizeUpload
        maxTotalBytes = perEmail ?? session.capabilities.core.maxSizeUpload
    }

    /// Why a file was not attached.
    ///
    /// Two cases and not one, because they lead the user somewhere different:
    /// a file that is too big on its own has to be shared another way, while a
    /// message that is merely full can lose something else instead.
    public enum Refusal: Hashable, Sendable {
        case fileTooLarge(name: String, size: Int, limit: Int)
        case messageWouldBeTooLarge(name: String, total: Int, limit: Int)

        /// Named out loud, never truncated. A message that goes out with the
        /// first 25 MB of a video looks to the sender like it worked.
        public var message: String {
            switch self {
            case .fileTooLarge(let name, let size, let limit):
                String(
                    localized:
                        "\(name) is \(Self.bytes(size)). This server accepts attachments up to \(Self.bytes(limit)).",
                    bundle: .module)

            case .messageWouldBeTooLarge(let name, let total, let limit):
                String(
                    localized:
                        "Adding \(name) would take this message to \(Self.bytes(total)). The limit is \(Self.bytes(limit)).",
                    bundle: .module)
            }
        }

        private static func bytes(_ count: Int) -> String {
            count.formatted(.byteCount(style: .file))
        }
    }

    /// Whether one more file fits, at pick time, while the user is still
    /// standing in the picker and can choose a different one.
    public func refusal(forFileNamed name: String, size: Int, currentTotal: Int) -> Refusal? {
        guard size <= maxFileBytes else {
            return .fileTooLarge(name: name, size: size, limit: maxFileBytes)
        }

        guard currentTotal + size <= maxTotalBytes else {
            return .messageWouldBeTooLarge(
                name: name, total: currentTotal + size, limit: maxTotalBytes)
        }

        return nil
    }
}
