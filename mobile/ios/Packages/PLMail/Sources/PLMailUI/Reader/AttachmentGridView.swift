#if os(iOS)

import PLMailCore
import SwiftUI
import UniformTypeIdentifiers

/// A message's attachments, as a grid of typed tiles.
///
/// **The tiles are informative before anything is downloaded.** Every one of
/// them draws a `UTType` icon, the system's own name for the type, the
/// filename and the size from the moment the message opens — none of which
/// costs a byte. A picture appears on top of that only for attachments whose
/// bytes ``BlobCache`` already holds, or after the reader presses "Show
/// previews". Scrolling a thread fetches nothing; see
/// ``AttachmentThumbnailPolicy`` for why that is the whole point.
///
/// A thumbnail is never the only way to tell two attachments apart: the
/// filename sits under every tile and is what VoiceOver reads first.
struct AttachmentsSection: View {
    let attachments: [AttachmentSnapshot]
    let blobs: BlobCache
    let downloadContext: DownloadContext
    /// Read from `MailSyncService`. Offline the grid still draws every typed
    /// placeholder and every cached picture; only the control that would spend
    /// bytes is withheld, because pressing it could not work.
    let isDeviceOffline: Bool
    let onPreview: (URL) -> Void

    @State private var thumbnails = AttachmentThumbnailLoader()
    /// Which attachments have a download running for Open or Save, keyed by
    /// part id. A second tap on a busy tile is ignored rather than starting a
    /// second transfer of the same fifteen megabytes.
    @State private var busy: Set<String> = []
    @State private var errorMessage: String?
    @State private var exported: DownloadedFile?
    @State private var isExporting = false
    /// What the exporter is currently writing. Held separately from
    /// ``exported`` because the picker needs a type and a default name, and
    /// the grid — unlike a single row — does not know which attachment it is
    /// saving until the tap.
    @State private var exportedAttachment: AttachmentSnapshot?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The tile's picture. Scaled so the square grows with the text beside it
    /// rather than staying a fixed box that the caption overflows.
    @ScaledMetric(relativeTo: .caption2) private var tileSide: CGFloat = 72

    /// Whether the grid is abandoned in favour of the full-width rows.
    ///
    /// At accessibility text sizes a filename is three lines tall and a 72
    /// point square leaves it a column 72 points wide, which is one word per
    /// line. The rows are what a reader at those sizes wants: full width, no
    /// picture, a visible menu. Degrading to them is better than shrinking
    /// text beside a fixed square.
    private var prefersRows: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if prefersRows {
                rows
            } else {
                grid

                if showsFetchControl { fetchControl }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        // Keyed on the blob ids so a sync that replaces the message's
        // attachments re-runs the disk pass, and a redraw that changes nothing
        // does not.
        .task(id: attachments.map(\.blobID).joined(separator: ",")) {
            guard prefersRows == false else { return }

            await thumbnails.loadCached(
                attachments, accountID: downloadContext.accountID, blobs: blobs)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exported,
            contentType: exportedAttachment.map(Self.contentType) ?? .data,
            defaultFilename: exportedAttachment?.displayName
        ) { result in
            // A cancelled picker is not a failure and must not leave an orange
            // line under the grid saying it was.
            if case .failure = result {
                errorMessage = String(localized: .ui("Couldn't save this attachment."))
            }
        }
    }

    // MARK: - Layouts

    /// The pre-existing list, unchanged, for accessibility text sizes.
    private var rows: some View {
        ForEach(attachments) { attachment in
            AttachmentRow(
                attachment: attachment,
                blobs: blobs,
                downloadContext: downloadContext,
                onPreview: onPreview
            )
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: tileSide, maximum: tileSide * 1.4),
                    spacing: 10,
                    alignment: .topLeading)
            ],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(attachments) { tile($0) }
        }
    }

    // MARK: - One tile

    private func tile(_ attachment: AttachmentSnapshot) -> some View {
        Button {
            open(attachment)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                square(attachment)

                // The filename stays, always. A thumbnail of a scanned
                // invoice and a thumbnail of a different scanned invoice are
                // the same grey rectangle at 72 points.
                Text(attachment.displayName)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(attachment.size.formatted(.byteCount(style: .file)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(busy.contains(attachment.partID))
        .accessibilityElement(children: .combine)
        // Name, type and size — everything the tile shows and everything the
        // picture cannot say. The thumbnail itself is hidden, exactly as
        // `SenderAvatar` is: it carries nothing this sentence does not.
        .accessibilityLabel(Text(Self.spokenLabel(for: attachment)))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(.ui("Downloads and opens this attachment")))
        // The same two actions the corner menu offers. A 28-point menu on the
        // corner of a 72-point square is not a target anyone reaches without
        // looking at it, and Save must not depend on finding it.
        .accessibilityAction(named: Text(.ui("Open"))) { open(attachment) }
        .accessibilityAction(named: Text(.ui("Save"))) { save(attachment) }
        .overlay(alignment: .topTrailing) { menu(attachment) }
    }

    /// The picture, or the typed placeholder standing in for it.
    ///
    /// Both are drawn into the same rounded square so a message where one
    /// attachment rendered and another did not still reads as a grid rather
    /// than as a row of things that went wrong.
    @ViewBuilder
    private func square(_ attachment: AttachmentSnapshot) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))

            switch thumbnails.state(for: attachment) {
            case .ready(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            case .loading:
                ProgressView()
            case .placeholder:
                // Every reason draws the same thing on purpose. "Too large",
                // "offline" and "the render failed" are all states in which
                // the honest picture of this attachment is its type — and a
                // broken-image glyph would report a fault about something the
                // reader never asked for.
                Image(systemName: AttachmentThumbnailPolicy.symbolName(for: attachment.type))
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            if busy.contains(attachment.partID) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)

                ProgressView()
            }
        }
        .frame(width: tileSide, height: tileSide)
        // Decorative. The label on the tile already says the filename, the
        // type and the size.
        .accessibilityHidden(true)
    }

    /// Open and Save, as a visible control on every tile.
    ///
    /// Not a long press. The house rule is that a gesture which is the only
    /// route to an action is a bug, and Save is the action people come to an
    /// attachment for after they have already looked at it.
    private func menu(_ attachment: AttachmentSnapshot) -> some View {
        Menu {
            Button(.ui("Open"), systemImage: "eye") { open(attachment) }
            Button(.ui("Save"), systemImage: "square.and.arrow.down") { save(attachment) }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.body)
                .symbolRenderingMode(.palette)
                // Two layers rather than one tint: the glyph sits on top of an
                // arbitrary photograph, and a single-colour ellipsis
                // disappears into roughly half of them.
                .foregroundStyle(.white, .black.opacity(0.45))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .disabled(busy.contains(attachment.partID))
        .accessibilityLabel(Text(.ui("Actions for this attachment")))
    }

    // MARK: - The one control that spends bytes

    /// Whether the fetch control is on screen.
    ///
    /// Kept visible while a fetch runs — otherwise the control the user just
    /// pressed vanishes and takes the only evidence that anything is happening
    /// with it.
    private var showsFetchControl: Bool {
        thumbnails.isFetching
            || thumbnails.hasAnythingToFetch(attachments, isDeviceOffline: isDeviceOffline)
    }

    /// The whole of this feature's network cost, behind one press.
    ///
    /// Deliberately one control for the message rather than a tap target on
    /// each tile: the decision a reader is making is "show me what these are",
    /// not "fetch this one, now this one", and one press that spends a bounded
    /// budget is far easier to reason about than eight that each spend a
    /// little.
    private var fetchControl: some View {
        Button {
            Task {
                await thumbnails.fetch(
                    attachments,
                    blobs: blobs,
                    downloadContext: downloadContext,
                    isDeviceOffline: isDeviceOffline)
            }
        } label: {
            HStack(spacing: 6) {
                if thumbnails.isFetching {
                    ProgressView()
                } else {
                    Image(systemName: "square.grid.2x2")
                }

                Text(.ui("Show previews"))
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(thumbnails.isFetching)
    }

    // MARK: - Downloads

    private func open(_ attachment: AttachmentSnapshot) {
        download(attachment) { url in onPreview(url) }
    }

    /// Downloads if needed, then asks the user where to put it.
    ///
    /// A copy, not a move: the file stays in ``BlobCache`` so opening the
    /// attachment again does not go back to somebody's NAS for bytes that are
    /// already on the device.
    private func save(_ attachment: AttachmentSnapshot) {
        download(attachment) { url in
            exported = DownloadedFile(url: url)
            exportedAttachment = attachment
            isExporting = true
        }
    }

    /// One download path for both actions.
    ///
    /// ``busy`` gates it per attachment rather than per grid, so saving one
    /// attachment does not disable the other seven. ``BlobCache``
    /// single-flights as well, but only after the request has been made — this
    /// stops it being made.
    private func download(
        _ attachment: AttachmentSnapshot, then use: @escaping (URL) -> Void
    ) {
        guard busy.contains(attachment.partID) == false else { return }

        busy.insert(attachment.partID)
        errorMessage = nil

        Task {
            defer { busy.remove(attachment.partID) }

            do {
                use(try await downloadContext.file(for: attachment, blobs: blobs))
            } catch {
                errorMessage = String(localized: .ui("Couldn't download this attachment."))
            }
        }
    }

    // MARK: - Description

    /// What VoiceOver reads for one tile: the filename, what kind of thing it
    /// is, and how big.
    ///
    /// The type description comes from `UTType` rather than from the raw MIME
    /// string — "JPEG image" rather than "image/jpeg", and nothing at all when
    /// the declared type is unrecognised, because a reader who cannot see the
    /// tile is not helped by hearing `application/x-foo`.
    static func spokenLabel(for attachment: AttachmentSnapshot) -> String {
        let size = attachment.size.formatted(.byteCount(style: .file))

        guard
            let described = AttachmentThumbnailPolicy.placeholder(for: attachment).typeDescription
        else {
            return "\(attachment.displayName), \(size)"
        }

        return "\(attachment.displayName), \(described), \(size)"
    }

    /// What the exporter writes the file as.
    ///
    /// Derived from what the sender declared, falling back to `.data`. The
    /// server stores the declared type and never parses it, so a wrong
    /// `Content-Type` must degrade to "some bytes" rather than stopping the
    /// save.
    static func contentType(for attachment: AttachmentSnapshot) -> UTType {
        UTType(mimeType: attachment.type) ?? .data
    }
}

#endif
