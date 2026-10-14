#if os(iOS)

import PLMailCore
import SwiftUI

/// The raw RFC 822 source of one message.
///
/// The reason anyone opens this is a header chain — `Received:`, `DKIM-
/// Signature:`, `Authentication-Results:` — and those are exactly the lines
/// that are longer than a phone is wide. So the text does **not** wrap: it
/// scrolls in both axes, because folding a `Received:` header at the device
/// width destroys the one thing the view exists to show. Monospaced for the
/// same reason, and selectable so a header can be pasted into a bug report.
struct MessageSourceSheet: View {
    let message: MessageSnapshot
    let blobs: BlobCache
    let downloadContext: DownloadContext

    /// How much of the source is drawn.
    ///
    /// A `Text` holding a fifty-megabyte mailing-list digest with images
    /// inlined as base64 does not render slowly — it hangs the main thread
    /// while TextKit lays it out, with no way back. The rest is not lost: the
    /// share sheet always carries the whole file, and the view says so.
    private static let displayByteLimit = 512 * 1024

    @State private var fileURL: URL?
    @State private var text: String?
    @State private var isTruncated = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(.ui("Message source"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(.ui("Done")) { dismiss() }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        // Only once the bytes are here. `ShareLink` needs a
                        // real file, and a share button that is present before
                        // the download finishes is a button that shares
                        // nothing.
                        //
                        // The file rather than the string: it is named
                        // `.eml`, so iOS previews it and the receiving app
                        // gets a message rather than a wall of text.
                        if let fileURL {
                            ShareLink(item: fileURL) {
                                Label(.ui("Share"), systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let text {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 12) {
                    if isTruncated {
                        Text(.ui("Only the first part is shown. Share to get the whole message."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(16)
            }
        } else if let errorMessage {
            ContentUnavailableView {
                Label(.ui("Couldn't load the source"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button(.ui("Try again")) { Task { await load() } }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Fetches the message blob and decodes as much of it as will be drawn.
    ///
    /// `message.eml` / `message/rfc822` are template variables the server
    /// echoes into `Content-Disposition` and `Content-Type`. Asking for the
    /// wrong type gets the right bytes labelled wrong, which is what makes the
    /// share sheet offer to open a message as plain text.
    private func load() async {
        guard let blobID = message.blobID else {
            errorMessage = String(localized: .ui("This message has no stored source."))
            return
        }

        errorMessage = nil

        do {
            let url = try await downloadContext.file(
                blobID: blobID, name: "message.eml", type: "message/rfc822", blobs: blobs)

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            let head = try handle.read(upToCount: Self.displayByteLimit) ?? Data()
            let more = (try handle.read(upToCount: 1) ?? Data()).isEmpty == false

            fileURL = url
            isTruncated = more
            // Mail source is ASCII with 8-bit escapes in practice, so a strict
            // UTF-8 decode fails on exactly the messages worth inspecting.
            // Latin-1 never fails and never loses a byte's identity.
            text =
                String(data: head, encoding: .utf8)
                ?? String(data: head, encoding: .isoLatin1)
                ?? ""
        } catch {
            errorMessage = String(localized: .ui("The server didn't return this message."))
        }
    }
}

#endif
