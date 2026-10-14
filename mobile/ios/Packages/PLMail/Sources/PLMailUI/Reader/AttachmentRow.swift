#if os(iOS)

import PLMailCore
import SwiftUI
import UniformTypeIdentifiers

/// One attachment.
///
/// Always downloaded to a file and handed to Quick Look, never rendered in
/// place: the server serves only `image/*` inline, ignores the `accept`
/// parameter and always sets `nosniff`, so a viewer that assumed inline
/// rendering would show a blank page for most of what people actually send.
struct AttachmentRow: View {
    let attachment: AttachmentSnapshot
    let blobs: BlobCache
    let downloadContext: DownloadContext
    let onPreview: (URL) -> Void

    @State private var isDownloading = false
    @State private var errorMessage: String?
    /// The downloaded file, held so the exporter has something to write.
    ///
    /// Nil until the bytes are on disk. `.fileExporter` cannot be handed a
    /// promise, so "Save" downloads first and opens the picker afterwards —
    /// the alternative is a picker that returns a destination for a file that
    /// then fails to arrive.
    @State private var exported: DownloadedFile?
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    open()
                } label: {
                    row
                }
                .buttonStyle(.plain)
                .disabled(isDownloading)
                .accessibilityElement(children: .combine)
                // The same sentence the grid speaks, from the same place: a
                // reader who meets this row at an accessibility text size and
                // the grid at a smaller one must hear one description of the
                // attachment, not two that disagree about what it is.
                .accessibilityLabel(Text(AttachmentsSection.spokenLabel(for: attachment)))
                .accessibilityHint(Text(.ui("Downloads and opens this attachment")))
                // The same two actions the menu offers, on the row itself.
                // A menu button 28 points wide is a hard target for anyone who
                // is not looking at the screen, and Save must not depend on
                // finding it.
                .accessibilityAction(named: Text(.ui("Open"))) { open() }
                .accessibilityAction(named: Text(.ui("Save"))) { save() }

                menu
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exported,
            contentType: contentType,
            defaultFilename: attachment.displayName
        ) { result in
            // A cancelled picker is not a failure and must not leave an orange
            // line under the row saying it was.
            if case .failure = result {
                errorMessage = String(localized: .ui("Couldn't save this attachment."))
            }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.subheadline)
                    .lineLimit(1)

                Text(sizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if isDownloading {
                ProgressView()
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(.rect)
    }

    /// Open and Save, as a visible control.
    ///
    /// Not a context menu: a long press that is the only route to saving an
    /// attachment is a route most people never find and VoiceOver users cannot
    /// reach at all.
    private var menu: some View {
        Menu {
            Button(.ui("Open"), systemImage: "eye", action: open)
            Button(.ui("Save"), systemImage: "square.and.arrow.down", action: save)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .disabled(isDownloading)
        .accessibilityLabel(Text(.ui("Actions for this attachment")))
    }

    private func open() {
        download { url in onPreview(url) }
    }

    /// Downloads if needed, then asks the user where to put it.
    ///
    /// A copy, not a move: the file stays in ``BlobCache`` so opening the
    /// attachment again does not go back to somebody's NAS for bytes that are
    /// already on the device.
    private func save() {
        download { url in
            exported = DownloadedFile(url: url)
            isExporting = true
        }
    }

    /// One download path for both actions.
    ///
    /// `isDownloading` gates it, so a second tap on a spinning row is ignored
    /// rather than starting a second transfer of the same fifteen megabytes.
    /// ``BlobCache`` single-flights as well, but only after the request has
    /// been made — this stops it being made.
    private func download(then use: @escaping (URL) -> Void) {
        guard isDownloading == false else { return }

        isDownloading = true
        errorMessage = nil

        Task {
            defer { isDownloading = false }

            do {
                use(try await downloadContext.file(for: attachment, blobs: blobs))
            } catch {
                errorMessage = String(localized: .ui("Couldn't download this attachment."))
            }
        }
    }

    /// What the exporter writes the file as.
    ///
    /// Derived from what the sender declared, falling back to `.data`. The
    /// server stores the declared type and never parses it, so a wrong
    /// `Content-Type` must degrade to "some bytes" rather than stopping the
    /// save.
    private var contentType: UTType {
        UTType(mimeType: attachment.type) ?? .data
    }

    private var sizeDescription: String {
        attachment.size.formatted(.byteCount(style: .file))
    }

    /// Chosen from the declared type. The server stores what the sender
    /// declared and never parses it, so this is a hint for the user, not a
    /// claim about the bytes.
    ///
    /// Shared with the grid rather than written twice: this row *is* the grid
    /// at accessibility text sizes, and two mappings would let the same
    /// attachment draw one icon at one text size and a different one at
    /// another — which reads as a bug in whichever the reader saw second.
    private var symbolName: String {
        AttachmentThumbnailPolicy.symbolName(for: attachment.type)
    }
}

/// A file already on disk, presented to `.fileExporter`.
///
/// Wraps the cached URL rather than the bytes: a `Data`-backed document would
/// fault a twenty-megabyte attachment into memory to hand it straight back to
/// the filesystem, and on an older device that is where the save fails.
struct DownloadedFile: FileDocument {
    /// Export-only. Declared as `.data` because the picker never reads through
    /// this type — leaving the array empty makes `FileDocument` conformance
    /// look like an oversight instead of a decision.
    static var readableContentTypes: [UTType] { [.data] }

    let url: URL

    init(url: URL) { self.url = url }

    /// Never called: nothing in this app opens a document. It throws rather
    /// than returning something plausible so a future reader who wires this up
    /// as an importer finds out immediately.
    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url)
    }
}

#endif
