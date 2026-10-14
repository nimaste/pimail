#if os(iOS)

import PLMailCore
import SwiftUI

/// One message inside a conversation.
struct MessageView: View {
    let message: MessageSnapshot
    let isExpanded: Bool
    let isRemoteContentAllowed: Bool
    let wasRemoteContentBlocked: Bool
    let blobs: BlobCache
    let downloadContext: DownloadContext
    /// Whether the phone has a network at all.
    ///
    /// Only the attachment grid reads it, and only to withhold the one control
    /// that would spend bytes. Passed down rather than read from
    /// `MailSyncService` here because the reader deliberately reads nothing
    /// from the sync service, and a card is the wrong place to start.
    let isDeviceOffline: Bool

    let onToggle: () -> Void
    let onAllowRemoteContent: () -> Void
    let onRemoteContentBlocked: () -> Void
    let onPreview: (URL) -> Void
    /// Replying to *this* message rather than to the newest in the thread.
    ///
    /// The bar at the bottom always answers the last message, which is right
    /// most of the time and wrong exactly when it matters: someone scrolls back
    /// to the message that asked the question and answers that. Without this
    /// their reply quotes the wrong thing and, on a thread with several
    /// participants, may go to the wrong person.
    let onCompose: (ComposeModel.Kind) -> Void
    /// Opens the raw RFC 822 source of this message.
    ///
    /// The sheet is presented by the thread rather than the card so it
    /// survives the card being rebuilt — this view's identity changes whenever
    /// a sender is trusted, which would otherwise dismiss the source view
    /// mid-read.
    let onShowSource: () -> Void

    /// The open find, or nil when the bar is closed.
    var find: ThreadFindModel?
    /// Where in this message's body the current match sits, as a fraction of
    /// the body's height. Only the thread's scroll view can act on it.
    var onCurrentMatchPositioned: (CGFloat) -> Void = { _ in }

    /// Follows the system, so mail matches the rest of the phone rather than
    /// being the one screen that stays white at night.
    @Environment(\.colorScheme) private var colorScheme
    /// The ink ladder the redesign states its greys against. `.secondary` is a
    /// system grey and reads cold on paper — the same reason the list stopped
    /// using it for a read row's sender.
    @Environment(\.theme) private var theme
    /// The disclosure curves, already reconciled with Reduce Motion by the
    /// root. Written as `.snappy(duration: 0.2)` twice before, which no
    /// preference could reach.
    @Environment(\.standardAnimation) private var standardAnimation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var prefersOriginalColors = false
    @State private var showsQuotedHistory = false
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                if showsDetails {
                    MessageDetailsView(message: message)
                }

                if wasRemoteContentBlocked && isRemoteContentAllowed == false {
                    remoteContentNotice
                }

                body(for: message)

                // Hidden while a find is live: the body is forced open for the
                // search, so the toggle would be a control with nothing to
                // toggle.
                if trimmed.quoted != nil, find?.hasQuery != true {
                    quotedHistoryToggle
                }

                if renderStyle(for: message).isTransformed || prefersOriginalColors {
                    originalColorsToggle
                }

                if message.attachments.isEmpty == false {
                    attachments
                }
            }
        }
        .padding(.vertical, isExpanded ? 12 : 8)
    }

    // MARK: - Header

    private var palette: ThemePalette {
        theme.palette(for: colorScheme)
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                // The same circle the list draws, so a message and its row are
                // recognisably the same correspondent. Smaller when collapsed:
                // a folded message is a one-line summary in the mock, and a
                // full-size avatar on it sets the row's height rather than the
                // text doing so.
                SenderAvatar(
                    name: message.fromName ?? message.displayName,
                    address: message.fromAddress,
                    diameter: isExpanded ? 38 : 30
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        found(.sender, in: message.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.ink.color)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                        if message.isDraft {
                            Text(.ui("Draft"))
                                .font(.caption2)
                                .foregroundStyle(palette.danger.color)
                        }
                    }

                    if isExpanded {
                        // Only where it says something the name does not. On a
                        // message whose display name *is* the address this
                        // would be the same string twice.
                        if let address = message.fromAddress, address != message.displayName {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(palette.inkFaint.color)
                                .lineLimit(1)
                        }

                        recipientLine
                    } else if message.preview.isEmpty == false {
                        // Only when there is one. An empty line still takes a
                        // line's height, and a column of collapsed rows with
                        // phantom second lines reads as broken spacing.
                        Text(message.preview)
                            .font(.caption)
                            .foregroundStyle(palette.inkFaint.color)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(palette.inkFaint.color)
                        .lineLimit(1)
                        // Never squeezed to nothing so a long sender name can
                        // fit: the name truncates first, and it is the thing
                        // with a sensible truncation.
                        .layoutPriority(1)

                    if message.attachments.isEmpty == false {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if isExpanded { actions }
            }
            .padding(.horizontal, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(
            Text(isExpanded ? .ui("Collapses this message") : .ui("Expands this message")))
    }

    /// The per-message overflow.
    ///
    /// Only on an expanded message: a collapsed row is a summary, and hanging
    /// a menu off it would put three of them on screen with nothing to say
    /// which is which.
    private var actions: some View {
        Menu {
            Button(.ui("Reply"), systemImage: "arrowshape.turn.up.left") {
                onCompose(.reply(to: message, all: false))
            }

            if hasOtherRecipients {
                Button(.ui("Reply all"), systemImage: "arrowshape.turn.up.left.2") {
                    onCompose(.reply(to: message, all: true))
                }
            }

            Button(.ui("Forward"), systemImage: "arrowshape.turn.up.right") {
                onCompose(.forward(message))
            }

            // Hidden rather than disabled when the server has no blob for this
            // message: an item that is always there and never works reads as a
            // broken feature, and a message with no `blobId` is one the server
            // genuinely cannot hand back.
            if message.blobID != nil {
                Section {
                    Button(
                        .ui("View source"),
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        action: onShowSource
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(.ui("Actions for this message")))
    }

    /// Whether replying to everyone would reach anybody new.
    private var hasOtherRecipients: Bool {
        message.to.count + message.cc.count > 1
    }

    /// Who this went to, and the way into the full detail.
    ///
    /// The label and the names are separate views rather than one interpolated
    /// string so the names can carry find highlighting: the find model counts
    /// occurrences in the names alone, and a query like "to" would otherwise
    /// match the label and put every subsequent occurrence one out.
    @ViewBuilder
    private var recipientLine: some View {
        let names = message.to.map(\.displayName).joined(separator: ", ")

        HStack(spacing: 4) {
            if names.isEmpty == false {
                Text(.ui("To:"))
                found(.recipients, in: names)
            }

            Button {
                withAnimation(standardAnimation) { showsDetails.toggle() }
            } label: {
                Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(showsDetails ? .ui("Hide details") : .ui("Show details")))
        }
        .font(.caption)
        .foregroundStyle(palette.inkFaint.color)
        .lineLimit(1)
    }

    /// One of the natively drawn fields, with its find matches picked out.
    ///
    /// The string is passed in rather than derived from the field, because the
    /// view already has it and deriving it twice is how the highlighted ranges
    /// and the drawn text drift apart.
    @ViewBuilder
    private func found(_ field: ThreadFind.Field, in text: String) -> some View {
        if let find, find.hasQuery {
            FoundText(
                text: text,
                ranges: find.ranges(in: text),
                currentOccurrence: find.currentOccurrence(in: message.id, field: field)
            )
        } else {
            Text(text)
        }
    }

    private var date: String {
        guard let receivedAt = message.receivedAt else { return "" }

        // "31 Jul 2026 at 18:18" wraps to three lines at accessibility sizes
        // and takes half the row from the sender's name. The day and time are
        // what a reader is actually scanning for in a thread.
        guard dynamicTypeSize.isAccessibilitySize else {
            // The same three-step rule the list rows use, plus the time — a
            // reader is in one thread and wants to know when *this* message
            // landed. `.abbreviated` spells the year on every message, which
            // is four characters that are only ever news once a year, and on a
            // 380pt reading pane it was enough to truncate the date **and** the
            // sender's name in the same row.
            if Calendar.current.isDateInToday(receivedAt) {
                return receivedAt.formatted(date: .omitted, time: .shortened)
            }

            let day =
                Calendar.current.isDate(receivedAt, equalTo: .now, toGranularity: .year)
                ? receivedAt.formatted(.dateTime.day().month(.abbreviated))
                : receivedAt.formatted(.dateTime.day().month(.abbreviated).year())

            return day + ", " + receivedAt.formatted(date: .omitted, time: .shortened)
        }

        return receivedAt.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Body

    /// What was written, and the history under it.
    ///
    /// Computed once here rather than inside the body builder so the toggle and
    /// the renderer cannot disagree about whether there is anything to hide.
    private var trimmed: (visible: String, quoted: String?) {
        guard let html = message.htmlBody, html.isEmpty == false else { return ("", nil) }

        return MailHTML.trimQuotedHistory(html)
    }

    /// Whether the quoted history has to be on screen.
    ///
    /// A find is computed over the whole body, history included — searching a
    /// thread and being told there are matches you cannot see would be a worse
    /// answer than not searching the history at all. So while a query is live
    /// the message renders in full, which also keeps the rendered HTML and the
    /// projection the offsets are stated against the same string.
    private var showsFullBody: Bool {
        showsQuotedHistory || (find?.hasQuery ?? false)
    }

    @ViewBuilder
    private func body(for message: MessageSnapshot) -> some View {
        if let html = message.htmlBody, html.isEmpty == false {
            MessageBodyView(
                html: showsFullBody ? html : trimmed.visible,
                inlineParts: message.inlineParts,
                accountKey: message.accountKey,
                loadRemoteContent: isRemoteContentAllowed,
                renderStyle: renderStyle(for: message),
                inlineProvider: { part, _ in
                    await downloadContext.data(for: part, blobs: blobs)
                },
                onRemoteContentBlocked: onRemoteContentBlocked,
                findMatches: find?.bodyMatches(in: message.id) ?? [],
                currentFindOccurrence: find?.currentOccurrence(in: message.id, field: .body),
                onCurrentMatchPositioned: onCurrentMatchPositioned
            )
            // **The one thing in the reader that is not paper.** A message body
            // renders on white — deliberately, and in every appearance, because
            // recolouring a sender's markup is how mail starts looking wrong —
            // so on a cream pane it is a sheet of a different colour. Left
            // full-bleed it ran to the pane card's own edges and squared its
            // rounded corners off, which is what stopped the reader reading as
            // a card at all beside the list. The message card used to do this
            // clipping; the thread is flat now, so the body does it for itself:
            // inset from the measure and rounded at the control radius, so the
            // white is visibly a document laid on the page rather than the page.
            //
            // Clipped *before* it is padded: the other order rounds the corners
            // of the margin instead of the sheet, which draws nothing at all.
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            // The handle the find scrolls to once it knows how far down this
            // body the match is. Separate from the card's own, because the
            // fraction is measured against the body and not the header above it.
            .id(ThreadReaderView.bodyAnchor(message.id))
        } else if let text = message.textBody, text.isEmpty == false {
            // Plain text stays native: no renderer needed, and it inherits
            // Dynamic Type and the app's theme for free.
            found(.body, in: text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        } else if message.hasBody == false {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            Text(.ui("This message has no content."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
    }

    /// Which dark-mode strategy this message gets.
    ///
    /// Per message, not per app: a plain reply and a marketing newsletter need
    /// different treatment, and applying one of them to both is what makes
    /// dark mail readers look broken.
    private func renderStyle(for message: MessageSnapshot) -> MessageRenderStyle {
        MessageRenderStyle.choose(
            profile: MessageColorProfile.profile(of: message.htmlBody ?? ""),
            isDark: colorScheme == .dark,
            prefersOriginal: prefersOriginalColors
        )
    }

    /// The `•••` chip, which is what every mail client uses for this and
    /// therefore what people already know how to read.
    ///
    /// Left-aligned and small on purpose: it is a seam in the message, not an
    /// action anyone came here to take.
    private var quotedHistoryToggle: some View {
        Button {
            withAnimation(standardAnimation) { showsQuotedHistory.toggle() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(palette.inkMuted.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    // 6 is the control radius, not the pane's: this is a chip
                    // in a message, and rounding it to the pane radius would
                    // make a seam look like a card.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.sunken.color))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityLabel(
            Text(
                showsQuotedHistory
                    ? .ui("Hide quoted history") : .ui("Show quoted history")))
    }

    /// The escape hatch.
    ///
    /// Offered only where the rendering actually transformed something that
    /// could be wrong. Inversion gets some messages wrong, and when it does
    /// the reader needs to see what was sent rather than be told it is fine.
    private var originalColorsToggle: some View {
        Button {
            prefersOriginalColors.toggle()
        } label: {
            Label(
                prefersOriginalColors ? "Using original colours" : "Show original colours",
                systemImage: prefersOriginalColors ? "sun.max" : "circle.lefthalf.filled"
            )
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Shown only once something was actually blocked, so a message with no
    /// remote content never nags.
    private var remoteContentNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)

            Text(.ui("Remote images blocked"))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            Button(.ui("Load"), action: onAllowRemoteContent)
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Attachments

    private var attachments: some View {
        AttachmentsSection(
            attachments: message.attachments,
            blobs: blobs,
            downloadContext: downloadContext,
            isDeviceOffline: isDeviceOffline,
            onPreview: onPreview
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

#endif
