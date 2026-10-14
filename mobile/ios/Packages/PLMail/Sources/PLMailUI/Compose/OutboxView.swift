#if os(iOS)

public import PLMailCore

import SwiftUI

/// What is written but not yet gone.
///
/// Deliberately a place you can look rather than a status line that flickers
/// past: the whole point of the queue is that a message survives a closed
/// composer, a dead uplink and a relaunch, and a queue you cannot inspect is
/// indistinguishable from mail that was silently dropped.
public struct OutboxView: View {
    private let outbox: OutboxSender
    @State private var messages: [Outbox.PendingMessage] = []
    /// The result of the last cancel, when it is something the person who
    /// tapped it has to be told rather than merely see.
    @State private var outcome: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    /// Read here rather than captured by the theme: one ``ResolvedTheme``
    /// serves both appearances, and a value that stored one would be stale the
    /// moment the shade is pulled down and the phone switches to dark.
    @Environment(\.colorScheme) private var colorScheme

    public init(outbox: OutboxSender) {
        self.outbox = outbox
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(messages) { message in
                        row(for: message)
                    }
                } footer: {
                    // Only for rows this phone is actually holding. Saying it
                    // over a server-held schedule would apologise for a
                    // limitation that no longer applies to it, and the whole
                    // value of the sentence is that it is true.
                    if messages.contains(where: \.isDeviceHeld) {
                        Text(.ui(SendLaterSheet.deviceHeldCaveat))
                    }
                }
            }
            .overlay {
                if messages.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text(.ui("Nothing waiting"))
                        } icon: {
                            Image(systemName: "tray")
                        }
                    } description: {
                        Text(.ui("Everything you've written has been sent."))
                    }
                }
            }
            .navigationTitle(Text(.ui("Outbox")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.ui("Done")) { dismiss() }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button(.ui("Try now")) { outbox.drain() }
                        .disabled(messages.isEmpty || outbox.isSending)
                }
            }
            .alert(
                Text(.ui("Couldn't call that back")),
                isPresented: .init(
                    get: { outcome != nil }, set: { if $0 == false { outcome = nil } })
            ) {
                Button(.ui("OK"), role: .cancel) { outcome = nil }
            } message: {
                Text(outcome ?? "")
            }
            .task { await reload() }
            // The sender is what empties the queue, and it does so from a
            // detached task; watching its count is how this list learns a
            // message left without polling.
            .onChange(of: outbox.pendingCount) { _, _ in
                Task { await reload() }
            }
        }
    }

    private func row(for message: Outbox.PendingMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.displayRecipient.isEmpty ? "—" : message.displayRecipient)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(message.queuedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(message.subject.isEmpty ? String(localized: .ui("(no subject)")) : message.subject)
                .font(.subheadline)
                .lineLimit(1)

            // Stated rather than shown as a clock glyph and a time: a row that
            // is waiting on purpose and a row that is stuck look identical
            // otherwise, and the second is the one people worry about.
            //
            // And **who** is holding it, because the two make different
            // promises: a server-held message leaves on time with the phone
            // off, a device-held one needs this phone awake. Showing one time
            // for both would make the weaker promise invisible.
            if let handover = message.handover {
                Label(
                    String(
                        localized: .ui(
                            "Your server sends this at \(SnoozeMenu.shortTime(handover.sendAt))")),
                    systemImage: "externaldrive.badge.checkmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let sendAfter = message.sendAfter {
                Label(
                    String(
                        localized: .ui(
                            "This phone sends this at \(SnoozeMenu.shortTime(sendAfter))")),
                    systemImage: "iphone.gen3"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let failure = message.lastFailure {
                // Named rather than reduced to a spinner: "waiting for the
                // server" and "the server refused this" call for entirely
                // different responses from the person who wrote it.
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if outbox.isSending, message.isDue() {
                Label {
                    Text(.ui("Sending…"))
                } icon: {
                    ProgressView().controlSize(.mini)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(cancelLabel(for: message), systemImage: "trash", role: .destructive) {
                Task { await cancel(message.id) }
            }
        }
        .swipeActions(edge: .leading) {
            // The way out of a schedule that turned out to be wrong: send it
            // anyway. Discarding is the other, and it is on the side people
            // already swipe for it.
            if message.sendAfter != nil {
                Button(.ui("Send now"), systemImage: "paperplane") {
                    Task { await sendNow(message.id) }
                }
                // `.tint(_:)` wants a concrete `Color`, which is what
                // ``ResolvedTheme/accentColor(in:)`` exists for. `.accentColor`
                // here read the asset catalogue and ignored a server-set accent
                // entirely.
                .tint(theme.accentColor(in: colorScheme))
            }
        }
        // Both actions again, because a swipe is invisible until it is tried
        // and this is the screen someone opens when they are already unsure
        // what is happening to their mail.
        .contextMenu {
            if message.sendAfter != nil {
                Button(.ui("Send now"), systemImage: "paperplane") {
                    Task { await sendNow(message.id) }
                }
            }

            Button(cancelLabel(for: message), systemImage: "trash", role: .destructive) {
                Task { await cancel(message.id) }
            }
        }
        // A custom action rather than only a swipe. A swipe that is the sole
        // route to calling a message back is a gesture somebody has to already
        // know about, on the one screen people open because they are unsure.
        .accessibilityAction(named: Text(cancelLabel(for: message))) {
            Task { await cancel(message.id) }
        }
    }

    /// What the destructive action is actually called.
    ///
    /// "Discard" is right for mail this device still holds and wrong for a
    /// submission the server has accepted: that one is a cancel, it can be
    /// refused, and calling it Discard promises a local delete that would leave
    /// the mail on its way.
    private func cancelLabel(for message: Outbox.PendingMessage) -> LocalizedStringResource {
        message.handover == nil ? .ui("Discard") : .ui("Cancel send")
    }

    /// Calls a message back and says what actually happened.
    ///
    /// **"Already sent" is reported, never swallowed.** Telling somebody a
    /// message was called back when their recipient is reading it is the one
    /// sentence this whole path exists to avoid, and it is exactly the case a
    /// cancel raced against the release time produces.
    private func cancel(_ id: UUID) async {
        switch await outbox.cancel(id) {
        case .cancelled:
            break

        case .alreadySent:
            outcome = String(
                localized: .ui("That had already gone out. It couldn't be called back."))

        case .notFound:
            outcome = String(
                localized: .ui("Your server has no record of that send. It's back on this phone."))

        case .failed(let reason):
            outcome = reason
        }

        await reload()
    }

    /// Reloads afterwards rather than waiting for the count to change: a send
    /// that fails leaves the message here, and the row would otherwise go on
    /// saying it was waiting for a time that has been cleared.
    private func sendNow(_ id: UUID) async {
        await outbox.sendNow(id)
        await reload()
    }

    private func reload() async {
        messages = await outbox.pending()
    }
}

#endif
