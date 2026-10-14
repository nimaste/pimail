#if os(iOS)

import JMAPKit
import OSLog
import PLMailCore
import QuickLookThumbnailing
import SwiftUI
import UIKit

/// Holds one message's thumbnails, and is the only thing in the reader allowed
/// to turn an attachment into bytes on the wire.
///
/// One per message rather than one per app: the per-message fetch budget in
/// ``AttachmentThumbnailPolicy/Limits/perMessage`` is only meaningful if
/// something counts per message, and a shared cache would let a thread of
/// thirty messages spend one message's budget thirty times over. The cost of
/// that choice is that scrolling a message off screen and back re-renders from
/// disk — which is local work on a file that is already there, and cheaper
/// than the accounting needed to avoid it.
@MainActor
@Observable
final class AttachmentThumbnailLoader {
    /// What one tile should draw.
    ///
    /// `.placeholder` carries the policy's reason rather than collapsing to
    /// "no image", because the tile says different things for "too large" and
    /// "we haven't asked" — and because a test can then assert which brake
    /// held rather than only that nothing appeared.
    enum State: Equatable {
        case placeholder(AttachmentThumbnailPolicy.Reason)
        /// A fetch or a render is running for this attachment. Distinct from
        /// the row's own `isDownloading`: a thumbnail may be rendering while
        /// the user is separately opening the file.
        case loading
        case ready(UIImage)
    }

    /// Keyed by blob id rather than part id, because the cache is keyed by
    /// blob id: the same picture forwarded twice in one thread is one blob and
    /// deserves one render.
    private(set) var states: [String: State] = [:]

    /// Blobs whose fetch or render failed, so it is never attempted again.
    ///
    /// **The loop this prevents is the expensive one.** A blob the server has
    /// evicted, or a JPEG whose bytes are truncated, fails identically every
    /// time; without this set a redraw — and SwiftUI redraws a lot — would put
    /// the request back on somebody's single PHP worker for as long as the
    /// reader is open.
    private var failed: Set<String> = []

    /// How much of this message's budget one tap has already spent.
    ///
    /// Never reset. "Show previews" is offered once and spends at most
    /// ``AttachmentThumbnailPolicy/Limits/perMessage``; a counter that reset
    /// would turn a control the user can press repeatedly into an unbounded
    /// one.
    private(set) var spent = 0

    /// The Session's numbers once they are known, the local ones until then.
    ///
    /// Adopted rather than read on demand, because reading it on demand means
    /// awaiting the client inside a view update, and the one thing this whole
    /// design promises is that drawing costs nothing.
    private var policy = AttachmentThumbnailPolicy()

    /// True while the user-initiated pass is running, so a second tap on the
    /// control is ignored rather than starting a second sequence.
    private(set) var isFetching = false

    private let logger = Logger(subsystem: "de.plmail", category: "thumbnails")

    /// What the tile draws now.
    ///
    /// `.notRequested` rather than nil for an unseen attachment, so a tile
    /// that has never been asked about and a tile that was asked and declined
    /// both draw the same honest typed placeholder.
    func state(for attachment: AttachmentSnapshot) -> State {
        states[attachment.blobID] ?? .placeholder(.notRequested)
    }

    /// Whether the "Show previews" control is worth drawing.
    ///
    /// Measured against ``AttachmentThumbnailPolicy/Limits/local``, which
    /// needs no Session and therefore no round trip. A message of five
    /// spreadsheets gets no control at all rather than a control that does
    /// nothing when pressed.
    func hasAnythingToFetch(
        _ attachments: [AttachmentSnapshot], isDeviceOffline: Bool
    ) -> Bool {
        guard isFetching == false, isDeviceOffline == false else { return false }

        return attachments.contains { attachment in
            states[attachment.blobID] == nil
                && policy.decision(
                    for: attachment,
                    in: .init(
                        isUserInitiated: true,
                        isDeviceOffline: false,
                        hasFailed: failed.contains(attachment.blobID),
                        spentInMessage: spent)
                ) == .download
        }
    }

    // MARK: - The free half

    /// Renders every attachment whose bytes ``BlobCache`` already holds.
    ///
    /// **This is the only path that runs without a tap, and it never touches
    /// the network.** It asks the cache whether a file exists and renders the
    /// ones that do, so an attachment the user opened once shows a picture for
    /// as long as it survives eviction — including in aeroplane mode, which is
    /// the case this app is built around. Everything else is left at its typed
    /// placeholder.
    func loadCached(
        _ attachments: [AttachmentSnapshot],
        accountID: AccountID,
        blobs: BlobCache
    ) async {
        for attachment in attachments where states[attachment.blobID] == nil {
            guard failed.contains(attachment.blobID) == false else { continue }

            // Renderability and size are checked before the disk is even
            // consulted: a cached 40 MB TIFF is still not worth handing to a
            // thumbnail generator on a five-year-old phone.
            guard
                policy.isWorthRendering(attachment),
                let url = await blobs.cachedFile(
                    blobID: BlobID(attachment.blobID),
                    accountID: accountID,
                    name: attachment.name,
                    type: attachment.type)
            else { continue }

            await render(attachment, at: url)
        }
    }

    // MARK: - The half that costs something

    /// Downloads and renders, on an explicit tap and only then.
    ///
    /// Sequential on purpose. The server is a Raspberry Pi with one PHP worker
    /// pool, and eight parallel blob downloads is the whole pool — the sync
    /// the user is actually waiting on would queue behind pictures they asked
    /// for as an afterthought.
    ///
    /// `isDeviceOffline` is read from `MailSyncService`: a fetch with no
    /// network buys a timeout and a spinner where a perfectly good icon was,
    /// so it is refused before it starts.
    func fetch(
        _ attachments: [AttachmentSnapshot],
        blobs: BlobCache,
        downloadContext: DownloadContext,
        isDeviceOffline: Bool
    ) async {
        guard isFetching == false, isDeviceOffline == false else { return }

        isFetching = true
        defer { isFetching = false }

        // The server's own ceiling, if it will tell us. A failure here is not
        // worth reporting: the local limits already bound everything, and the
        // session is cached by the client on any run that got this far.
        if let session = try? await downloadContext.client.session() {
            policy.limits = .reading(session, accountID: downloadContext.accountID)
        }

        for attachment in attachments {
            guard Task.isCancelled == false else { return }

            let decision = policy.decision(
                for: attachment,
                in: .init(
                    isOnDisk: false,
                    isUserInitiated: true,
                    isDeviceOffline: isDeviceOffline,
                    hasFailed: failed.contains(attachment.blobID),
                    spentInMessage: spent))

            switch decision {
            case .download:
                break
            case .render:
                continue
            case .placeholder(let reason):
                // Recorded so the tile can say "too large" rather than sitting
                // at the resting placeholder as though nothing was decided.
                if states[attachment.blobID] == nil {
                    states[attachment.blobID] = .placeholder(reason)
                }
                continue
            }

            spent += 1
            states[attachment.blobID] = .loading

            do {
                let url = try await downloadContext.file(for: attachment, blobs: blobs)
                await render(attachment, at: url)
            } catch {
                logger.debug("Thumbnail fetch failed: \(error, privacy: .public)")
                give(up: attachment)
            }
        }
    }

    // MARK: - Rendering

    /// Turns a local file into a picture, or gives up on it for good.
    ///
    /// `representationTypes: .thumbnail` and not `.all`: `.icon` would have
    /// Quick Look hand back the generic document glyph for anything it cannot
    /// render, which arrives as a success and puts a *worse* icon on the tile
    /// than the typed placeholder this file already knows how to draw.
    private func render(_ attachment: AttachmentSnapshot, at url: URL) async {
        states[attachment.blobID] = .loading

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: Self.renderSize,
            scale: UITraitCollection.current.displayScale,
            representationTypes: .thumbnail)

        do {
            let representation = try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)

            states[attachment.blobID] = .ready(representation.uiImage)
        } catch {
            logger.debug("Thumbnail render failed: \(error, privacy: .public)")
            give(up: attachment)
        }
    }

    /// Marks an attachment as never worth trying again, and puts the tile back
    /// to something that reads as an ordinary state.
    ///
    /// Deliberately **not** an error state on the tile. A thumbnail is
    /// decorative; the filename, type and size are already on screen and are
    /// what the row is for. An orange line under a picture that failed to
    /// render would report a fault about something the reader never asked for.
    private func give(up attachment: AttachmentSnapshot) {
        failed.insert(attachment.blobID)
        states[attachment.blobID] = .placeholder(.failed)
    }

    /// The pixel size asked of Quick Look.
    ///
    /// Generous relative to the 72-point tile so the picture still looks right
    /// at accessibility text sizes and on a 3× screen, and bounded so a
    /// full-resolution page render is never what lands in memory.
    private static let renderSize = CGSize(width: 160, height: 160)
}

#endif
