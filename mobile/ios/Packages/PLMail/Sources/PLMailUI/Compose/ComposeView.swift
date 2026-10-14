#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Writing a message.
///
/// Fullscreen on a phone, which is what the web UI does below its
/// breakpoint and what there is room for.
public struct ComposeView: View {
    @State private var model: ComposeModel
    @Environment(\.dismiss) private var dismiss
    /// The Send capsule and the recipient chips are drawn from the palette
    /// rather than from system styles, so a themed composer is themed all the
    /// way to its one filled button. Injected explicitly by whoever presents
    /// this sheet — see `MailView` and `ThreadReaderView`.
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focus: Field?

    private enum Field: Hashable { case to, cc, bcc, subject, body }

    @State private var bodySelection = AttributedTextSelection()
    @State private var showsMoreRecipients = false
    @State private var isPickingFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isPickingSendTime = false
    @State private var attachmentError: String?
    @State private var isConfirmingClose = false
    /// The recipient fragment the privacy question was raised over, so saying
    /// yes fills the list rather than needing another keystroke.
    @State private var askingFragment = ""

    /// A `mailto:` link that arrived while this composer already had something
    /// in it.
    ///
    /// Held rather than applied, which is the whole guard: a link from a web
    /// page must not be able to overwrite a message somebody is part way
    /// through writing. Nothing happens until the dialog this drives has been
    /// answered.
    @State private var arrivingMailto: MailtoRequest?

    /// The link to open a **second** composer on, once this one has finished
    /// dismissing.
    @State private var relaunchMailto: MailtoRequest?

    /// Whether the link carried more than ``Mailto`` was willing to use.
    ///
    /// Said out loud. A body silently cut at 16 KB teaches somebody that this
    /// app loses text.
    @State private var mailtoWasTrimmed = false

    /// Filled in by Shortcuts or Siri, applied once the model exists.
    private let prefill: (recipient: String?, subject: String?)?

    public init(
        kind: ComposeModel.Kind,
        accountKey: String,
        accountID: AccountID,
        client: JMAPClient,
        store: SyncStore,
        outbox: OutboxSender,
        prefill: (recipient: String?, subject: String?)? = nil
    ) {
        self.prefill = prefill

        _model = State(
            wrappedValue: ComposeModel(
                kind: kind, accountKey: accountKey, accountID: accountID,
                client: client, store: store,
                outbox: outbox.queue,
                onQueued: { outbox.drain() }))
    }

    public var body: some View {
        NavigationStack {
            Form {
                Group {
                    recipients
                    subjectField
                    bodyField
                    quotedSection
                    attachmentsSection
                }
                // On the sections, not on the `Form`: a row background set on
                // the container does not reach the rows, and the composer came
                // up with white cards on a Paper ground — half themed, which
                // reads worse than not themed at all.
                .listRowBackground(palette.surface.color)
            }
            .themedFormSurface(palette)
            .navigationTitle(
                model.subject.isEmpty ? String(localized: .ui("New message")) : model.subject
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { cancel() }
                        // What Escape does everywhere else on the platform.
                        .keyboardShortcut(.cancelAction)
                }

                ToolbarItem(placement: .confirmationAction) { sendControl }

                ToolbarItem(placement: .topBarLeading) {
                    // A menu rather than a single button: on a phone the thing
                    // people attach is almost always a photo, and routing them
                    // through the document browser to find one — where the
                    // photo library is a sub-provider, several taps in — is the
                    // kind of detour that makes an app feel like a port.
                    Menu {
                        // A `PhotosPicker` placed directly in a menu never
                        // presents: the menu dismisses, and the sheet it was
                        // about to show goes with it. The flag and the
                        // modifier below are the arrangement that survives.
                        Button(.ui("Photo or video"), systemImage: "photo.on.rectangle") {
                            isPickingPhotos = true
                        }

                        Button(.ui("File"), systemImage: "folder") { isPickingFiles = true }
                    } label: {
                        Label(.ui("Attach"), systemImage: "paperclip")
                    }
                    .disabled(model.isSending)
                }

            }
            .safeAreaInset(edge: .bottom) { sendingBar }
            // Copied into memory on pick rather than held as a URL: the
            // picker's security scope is released when it closes, and a send
            // minutes later would find nothing at the other end.
            .fileImporter(
                isPresented: $isPickingFiles,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                attach(result)
            }
            .photosPicker(
                isPresented: $isPickingPhotos,
                selection: $pickedPhotos,
                maxSelectionCount: 10,
                matching: .any(of: [.images, .videos])
            )
            // Loaded as transferable data rather than by URL: a `PhotosPickerItem`
            // is a promise, and the asset it names may still be in iCloud. The
            // transfer is what forces the download.
            .onChange(of: pickedPhotos) { _, items in
                guard items.isEmpty == false else { return }

                Task { await attach(items) }
            }
            .sheet(isPresented: $isPickingSendTime) {
                SendLaterSheet { model.scheduleSend(at: $0) }
            }
            .alert(
                Text(.ui("Couldn't attach that")),
                isPresented: .init(
                    get: { attachmentError != nil || model.attachmentRefusal != nil },
                    set: {
                        if $0 == false {
                            attachmentError = nil
                            model.clearAttachmentRefusal()
                        }
                    })
            ) {
                Button(.ui("OK"), role: .cancel) {
                    attachmentError = nil
                    model.clearAttachmentRefusal()
                }
            } message: {
                Text(attachmentError ?? model.attachmentRefusal ?? "")
            }
            // Its own alert rather than sharing the attachment one: the title
            // has to name what was refused, and "Couldn't attach that" over a
            // From swap reads as a bug in the app.
            .alert(
                Text(.ui("Couldn't change the sending address")),
                isPresented: .init(
                    get: { model.identityRefusal != nil },
                    set: { if $0 == false { model.clearIdentityRefusal() } })
            ) {
                Button(.ui("OK"), role: .cancel) { model.clearIdentityRefusal() }
            } message: {
                Text(model.identityRefusal ?? "")
            }
            // The draft was rewritten on another device. Asked rather than
            // resolved: merging two edits to one letter is a guess, and
            // discarding the newer of them silently is the bug `ifInState`
            // exists to prevent. Both answers keep every character on screen —
            // one replaces the other copy, the other leaves it alone — so
            // nothing here can cost the user their typing.
            //
            // An alert, not a `.confirmationDialog`, for the reason spelled out
            // below the Cancel question: a dialog presented as a popover drops
            // its `.cancel` button, and a question with one visible answer is
            // not a question.
            .alert(
                Text(.ui("This draft changed somewhere else")),
                isPresented: .init(
                    get: { model.isDraftConflicted },
                    // Read-only from the view's side: the model clears the flag
                    // itself when the user picks, and a setter that cleared it
                    // on dismissal would turn swiping the alert away into a
                    // silent decision.
                    set: { _ in })
            ) {
                Button(.ui("Keep what I've written")) { model.overwriteDraftElsewhere() }

                Button(.ui("Close without saving"), role: .destructive) {
                    model.closeKeepingRemoteDraft()
                }
            } message: {
                Text(
                    .ui(
                        "Another device saved a newer version. Nothing you have typed has been touched — keep it and it replaces theirs, or close the composer to leave theirs alone."
                    ))
            }
            // Mail's own arrangement, and the reason Cancel stops being a
            // discard: everything typed is on the server within a few seconds
            // anyway, so the only question left is whether it should stay.
            .confirmationDialog(
                Text(.ui("This message hasn't been sent")),
                isPresented: $isConfirmingClose,
                titleVisibility: .visible
            ) {
                Button(.ui("Delete Draft"), role: .destructive) {
                    Task { await model.discardDraft() }
                }

                Button(.ui("Save Draft")) {
                    Task { await model.saveAndClose() }
                }

                Button(.ui("Cancel"), role: .cancel) {}
            }
            // The link, when one arrives over a message already being written.
            // Asked because the alternative — applying it — is the phishing
            // shape, where a page the user merely visited rewrites what they
            // were in the middle of.
            //
            // **An alert rather than a `.confirmationDialog`**, unlike the
            // Cancel question above it. A confirmation dialog drops its
            // `.cancel` button whenever the system presents it as a popover,
            // which is what happened on the first device this ran on: the
            // question appeared with one button and the way to decline it was
            // to tap outside. A question raised by something *outside* the app
            // has to show both answers.
            .alert(
                Text(.ui("Open this link in a new message?")),
                isPresented: Binding(
                    get: { arrivingMailto != nil },
                    set: { if $0 == false { arrivingMailto = nil } }),
                presenting: arrivingMailto
            ) { mailto in
                Button(.ui("Save Draft and Continue")) {
                    relaunchMailto = mailto
                    arrivingMailto = nil

                    Task { await model.saveAndClose() }
                }

                Button(.ui("Keep Writing"), role: .cancel) { arrivingMailto = nil }
            } message: { mailto in
                Text(.ui("That link writes to \(Self.naming(mailto.to))."))
            }
            .alert(
                Text(.ui("Some of that link was too long to use")),
                isPresented: $mailtoWasTrimmed
            ) {
                Button(.ui("OK"), role: .cancel) { mailtoWasTrimmed = false }
            } message: {
                Text(.ui("The composer has as much of it as it could take."))
            }
            .task {
                // Before `load`, which fills in identities and a signature —
                // neither of which should overwrite what was dictated.
                //
                // A link is a superset of what Siri hands over, so the two are
                // exclusive: applying both would set `to` twice, once from the
                // joined field and once from the tokens it was joined from.
                if let mailto = IntentRouter.shared.takeMailto() {
                    apply(mailto)
                } else if let prefill {
                    if let recipient = prefill.recipient { model.to = recipient }
                    if let subject = prefill.subject { model.subject = subject }
                }

                await model.load()
            }
            // A link tapped while this composer is already on screen. The shell
            // re-uses the sheet rather than replacing it, so `.task` above does
            // not run again — without this the payload would sit in the router
            // until some unrelated composer, opened by hand hours later, filled
            // itself in from it.
            .onChange(of: IntentRouter.shared.mailto) { _, arrived in
                guard arrived != nil, let mailto = IntentRouter.shared.takeMailto() else { return }

                // Nothing to lose: an empty composer takes the link outright.
                guard model.isEmpty == false else {
                    apply(mailto)

                    return
                }

                arrivingMailto = mailto
            }
            .onChange(of: model.status) { _, status in
                if status == .sent || status == .closed {
                    dismiss()
                    relaunch()
                }
            }
        }
        // A swipe-down on an empty composer just closes; one on a message
        // somebody has written has to go through the same question Cancel
        // asks, or the gesture becomes the way drafts are lost.
        .interactiveDismissDisabled(model.isSending || model.needsCloseConfirmation)
    }

    // MARK: - Send

    /// Send, and the chevron that holds "send later".
    ///
    /// **One control with two halves, per the mock.** Sending now and sending
    /// at a time are the same decision taken twice, and the clock used to sit
    /// on the *other* side of the bar from the button it modifies — so the two
    /// halves are adjacent, and the chevron is the disclosure it looks like.
    /// Both are disabled by the same condition: a time is no use without
    /// somebody to send to.
    private var sendControl: some View {
        HStack(spacing: 2) {
            Button(action: model.send) {
                Text(.ui("Send"))
                    .font(.subheadline.weight(.semibold))
                    // Not assumed white: the accent is the user's, and a pale
                    // one wants black on it — what `accentInk` is derived for.
                    .foregroundStyle(palette.accentInk.color)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(palette.accent.color, in: .capsule)
                    // A disabled capsule keeps its shape and loses its weight.
                    // Left at full strength it reads as a button that ignores
                    // taps, which is the one thing worse than a dimmed one.
                    .opacity(model.canSend ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(model.canSend == false)
            // ⌘↩, as in Mail. Deliberately not plain Return, which is a
            // newline in the body somebody is still writing.
            .keyboardShortcut(.return, modifiers: .command)

            Menu {
                SendLaterMenu(
                    onPick: { model.scheduleSend(at: $0) },
                    onPickExact: { isPickingSendTime = true }
                )
            } label: {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.accent.color)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .disabled(model.canSend == false)
            // The glyph says nothing on its own, and this is the only name
            // this control has now that the clock has left the bar.
            .accessibilityLabel(Text(.ui("Send later")))
        }
    }

    private var palette: ThemePalette {
        theme.palette(for: colorScheme)
    }

    /// Names a link's recipients for a dialog.
    ///
    /// Bare addresses, not the `Name <address>` the field holds. A
    /// `LocalizedStringResource` interpolation is parsed as Markdown, in which
    /// `<m@x.example>` is an autolink — the angle brackets vanish and the
    /// sentence reads as though the display name and the address were two
    /// separate recipients.
    private static func naming(_ tokens: [String]) -> String {
        tokens.map { RecipientParsing.parse($0)?.email ?? $0 }.joined(separator: ", ")
    }

    /// Puts a parsed link into this composer.
    ///
    /// Cc and Bcc are opened whenever the link filled either. A link that Ccs
    /// somebody behind a collapsed disclosure sends mail to a person the sender
    /// never saw named, which is the one failure in this file that reaches
    /// somebody else's inbox.
    private func apply(_ mailto: MailtoRequest) {
        model.apply(mailto)

        if mailto.needsMoreRecipients { showsMoreRecipients = true }
        if mailto.wasTrimmed { mailtoWasTrimmed = true }
    }

    /// Re-asks for a composer on a link that arrived while this one was open.
    ///
    /// After a beat, and the delay is the point. The shell opens the composer
    /// by setting its sheet item to `.new`, which it still is until this sheet
    /// has finished dismissing — asking again immediately changes nothing and
    /// the second composer never appears. Deliberately a free `Task` rather
    /// than `.task`, which would be cancelled by the dismissal that has to
    /// happen first.
    private func relaunch() {
        guard let mailto = relaunchMailto else { return }

        relaunchMailto = nil

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))

            IntentRouter.shared.request(mailto: mailto)
        }
    }

    /// Cancel, which is now a question rather than a discard.
    private func cancel() {
        guard model.needsCloseConfirmation else {
            dismiss()

            return
        }

        isConfirmingClose = true
    }

    /// Reads each picked file inside its security scope, which is the only
    /// window in which the URL resolves.
    private func attach(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else {
            attachmentError = String(localized: .ui("That file couldn't be opened."))
            return
        }

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()

            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                attachmentError = String(
                    localized: .ui("\(url.lastPathComponent) couldn't be read."))
                continue
            }

            let type =
                (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
                .preferredMIMEType ?? "application/octet-stream"

            model.attach(name: url.lastPathComponent, type: type, data: data)
        }
    }

    /// Pulls the picked assets in, one at a time.
    ///
    /// Sequentially on purpose. Ten photos fetched from iCloud at once is a
    /// spike of memory the size of all of them, on a device that may have been
    /// running low enough to have evicted them in the first place.
    private func attach(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                attachmentError = String(localized: .ui("That photo couldn't be loaded."))
                continue
            }

            let type = item.supportedContentTypes.first
            let name =
                type?.preferredFilenameExtension.map {
                    "photo-\(UUID().uuidString.prefix(8)).\($0)"
                }
                ?? "attachment"

            model.attach(
                name: name,
                type: type?.preferredMIMEType ?? "application/octet-stream",
                data: data)
        }

        pickedPhotos = []
    }

    // MARK: - Fields

    private var recipients: some View {
        Section {
            // Always shown, even with one identity: sending as the wrong
            // alias is invisible until someone replies to the wrong place.
            if model.identities.count > 1 {
                Picker(.ui("From"), selection: identitySelection) {
                    ForEach(model.identities) { identity in
                        // The account name only where it disambiguates. On the
                        // common single-account setup it is noise; across
                        // accounts it is the difference between two identical
                        // display names fronting two different mailboxes.
                        if spansAccounts {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(identity.displayName)
                                Text(identity.accountName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(identity))
                        } else {
                            Text(identity.displayName).tag(Optional(identity))
                        }
                    }
                }
            } else if let identity = model.selectedIdentity {
                LabeledContent(.ui("From"), value: identity.displayName)
            }

            RecipientField(
                label: .ui("To"), text: $model.to, model: model,
                askingFragment: $askingFragment
            )
            .focused($focus, equals: .to)

            if showsMoreRecipients {
                RecipientField(
                    label: .ui("Cc"), text: $model.cc, model: model,
                    askingFragment: $askingFragment
                )
                .focused($focus, equals: .cc)
                RecipientField(
                    label: .ui("Bcc"), text: $model.bcc, model: model,
                    askingFragment: $askingFragment
                )
                .focused($focus, equals: .bcc)
            } else {
                Button(.ui("Cc / Bcc")) { showsMoreRecipients = true }
                    .font(.footnote)
            }
        } footer: {
            serverSuggestionChoice

            // Named rather than dropped. A typed address without an `@` used
            // to be filtered out at send with nothing said, so the composer
            // listed five people and the message went to four.
            if model.invalidRecipients.isEmpty == false {
                Label {
                    Text(.ui("Not an address: \(model.invalidRecipients.joined(separator: ", "))"))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// A binding that routes through ``ComposeModel/selectIdentity(_:)``.
    ///
    /// Not a plain `$model.selectedIdentity`: choosing an address on another
    /// account has to abandon the draft written under the old one and re-upload
    /// the files, and a settable property would let a picker do half of that.
    private var identitySelection: Binding<ComposeModel.SendingIdentity?> {
        Binding(get: { model.selectedIdentity }, set: { model.selectIdentity($0) })
    }

    /// Whether the From list crosses more than one connected account.
    private var spansAccounts: Bool {
        Set(model.identities.map(\.accountKey)).count > 1
    }

    /// The one question this app asks about sending anything anywhere.
    ///
    /// Asked here, under the field somebody is typing in, rather than buried in
    /// a settings screen: it is a question about *this* keystroke, and the only
    /// moment it can be answered with the context to answer it is while the
    /// suggestion list would be being filled.
    ///
    /// Stated rather than glossed. Today recipient suggestions never leave the
    /// device — that is what the app's own contacts permission string promises —
    /// and saying yes sends a prefix of what is being typed to the user's
    /// server. It is their server, which is the premise of the whole product,
    /// and it is still a different promise from the one already made.
    @ViewBuilder
    private var serverSuggestionChoice: some View {
        if model.isAskingAboutServerSuggestions {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(
                        .ui(
                            "Your server can rank suggestions by who you actually write to. That means sending what you type here to your server as you type it — it already holds these addresses, harvested from your own mail, but not what you type or when."
                        ))
                } icon: {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                }
                .font(.caption)

                HStack(spacing: 12) {
                    Button(.ui("Ask my server")) {
                        model.answerServerSuggestions(allowed: true, for: askingFragment)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(.ui("Keep it on this device")) {
                        model.answerServerSuggestions(allowed: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
        }
    }

    private var subjectField: some View {
        Section {
            TextField(text: $model.subject) { Text(.ui("Subject")) }
                .focused($focus, equals: .subject)
        }
    }

    private var bodyField: some View {
        Section {
            RichTextEditor(text: $model.body, selection: $bodySelection)
                // A form row sizes to its content; a text editor has none until
                // there is text, so without a floor the field opens as a
                // one-line slot that nobody reads as "write here".
                //
                // Twice as tall where there is a page sheet to be tall in. A
                // `Form` row cannot stretch to fill what is left, so the floor
                // is what decides how much of the sheet the body gets, and one
                // number tuned for a phone leaves an iPad composer with half
                // its sheet empty under the last row.
                .frame(minHeight: sizeClass == .regular ? 460 : 260)
                .focused($focus, equals: .body)

            // Under the field rather than on the keyboard's accessory bar.
            // `placement: .keyboard` renders nothing when a hardware keyboard
            // is attached — which is every iPad with a Magic Keyboard, and
            // exactly the setup where someone is most likely to be writing
            // something worth formatting.
            FormattingBar(text: $model.body, selection: $bodySelection)
                .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
    }

    /// The quoted original, collapsed.
    ///
    /// Shown as one row rather than as text in the editor: the quote is not
    /// editable here — it is kept verbatim so it arrives exactly as it was
    /// received — and pretending otherwise by dropping it into the body would
    /// invite edits that get thrown away on send.
    @ViewBuilder
    private var quotedSection: some View {
        if model.quotedHTML != nil {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "quote.opening")
                        .foregroundStyle(.secondary)

                    Text(.ui("Quoted message included"))
                        .font(.subheadline)

                    Spacer(minLength: 0)

                    Button(.ui("Remove"), systemImage: "xmark.circle.fill") {
                        model.removeQuote()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var attachmentsSection: some View {
        if model.attachments.isEmpty == false {
            Section {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 10) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(attachment.size.formatted(.byteCount(style: .file)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Button(.ui("Remove"), systemImage: "xmark.circle.fill") {
                            model.removeAttachment(attachment.id)
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text(.ui("Attachments"))
            } footer: {
                // Both numbers, because the ceiling is the server's rather
                // than the app's and the total on its own says nothing about
                // how much room is left.
                Text(
                    .ui(
                        "\(model.attachmentsSize.formatted(.byteCount(style: .file))) of \(model.limits.maxTotalBytes.formatted(.byteCount(style: .file)))"
                    ))
            }
        }
    }

    /// What the composer is doing at the bottom of the sheet.
    ///
    /// **No countdown, and no Undo here.** The recall window is a hold the
    /// server applies to the submission, so the undo lives in the Outbox where
    /// it still works after this sheet has gone — which is the whole point:
    /// once the old five-second bar dismissed, there was no undo at all.
    @ViewBuilder
    private var sendingBar: some View {
        switch model.status {
        case .queuing:
            HStack(spacing: 8) {
                ProgressView()
                Text(.ui("Sending…"))
                    .font(.subheadline)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
            .accessibilityElement(children: .combine)

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message).font(.footnote)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

        case .editing:
            saveIndicator

        case .sent, .closed:
            EmptyView()
        }
    }

    /// Where the text currently is.
    ///
    /// Quiet on purpose — this is not an action, it is the answer to "have I
    /// lost this?". Nothing is shown until there is something worth saving,
    /// because a composer that says "Saved" before anything is typed teaches
    /// people to stop reading it.
    @ViewBuilder
    private var saveIndicator: some View {
        switch model.saveState {
        case .idle:
            EmptyView()

        case .saving:
            saveRow(Text(.ui("Saving…")), systemImage: "arrow.up.circle", tint: .secondary)

        case .saved:
            saveRow(Text(.ui("Saved to Drafts")), systemImage: "checkmark.circle", tint: .secondary)

        case .failed(let message):
            saveRow(Text(message), systemImage: "exclamationmark.circle", tint: .orange)
        }
    }

    private func saveRow(
        _ label: Text, systemImage: String, tint: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            label
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

/// One address field, with completions drawn from mail already synced.
///
/// **The field is still one string.** Everything below the view layer — the
/// draft, the autosave, `RecipientParsing`, the send — reads
/// `"a@x.example, b@y.example"` and always has. The chips are a rendering of
/// the part of that string which has been typed past: a separator commits a
/// recipient, and the text field edits only the fragment after the last one.
/// Making the tokens the model instead would have put a second representation
/// of the recipient list next to the one that gets sent.
private struct RecipientField: View {
    let label: LocalizedStringResource
    @Binding var text: String
    let model: ComposeModel
    @Binding var askingFragment: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                    // The label sits on the first line of chips rather than
                    // centred against a stack of them.
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 6) {
                    if committed.isEmpty == false {
                        ChipFlow(spacing: 6) {
                            // By position, because two chips can legitimately
                            // be the same string — a list pasted twice — and
                            // removing one of them must remove that one.
                            ForEach(Array(committed.enumerated()), id: \.offset) { index, token in
                                RecipientChip(token: token) { remove(at: index) }
                            }
                        }
                    }

                    TextField("", text: typing)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            // The address book is consulted for what is being typed now, not
            // loaded up front — see `lookUpContacts`.
            .onChange(of: current) { _, fragment in
                askingFragment = fragment
                model.lookUpContacts(for: fragment)
            }

            if matches.isEmpty == false {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(matches, id: \.email) { address in
                            Button(address.displayName) { complete(with: address) }
                                .font(.caption)
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// Matches the fragment being typed, not the whole field, so a second
    /// recipient still gets suggestions.
    ///
    /// The ranking itself lives in the model, where it can be tested; this is
    /// only responsible for working out which part of the field is being
    /// edited.
    private var matches: [EmailAddress] {
        model.suggestions(for: current)
    }

    /// The recipients that are settled, in the order they were typed. The
    /// arithmetic is ``RecipientTokens``, where it can be tested.
    private var committed: [String] {
        RecipientTokens.committed(in: text)
    }

    private var current: String {
        RecipientTokens.fragment(in: text)
    }

    /// The text field's own binding: the fragment after the last separator,
    /// written back into the whole string.
    private var typing: Binding<String> {
        Binding(
            get: { current },
            set: { fragment in text = RecipientTokens.joined(committed, typing: fragment) }
        )
    }

    private func remove(at index: Int) {
        text = RecipientTokens.removing(at: index, in: text)
    }

    private func complete(with address: EmailAddress) {
        text = RecipientTokens.joined(committed + [address.email], typing: "")
    }
}

#endif
