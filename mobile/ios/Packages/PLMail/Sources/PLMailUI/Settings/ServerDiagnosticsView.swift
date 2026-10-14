#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI
import UIKit

/// What the app knows about the server, in the detail someone who administers
/// it needs.
///
/// Kept as a real screen rather than debug scaffolding: plMail users run the
/// machine they are talking to, so when something is wrong they are the ones
/// who can fix it. That changes what belongs here. In an app whose backend
/// someone else operates, a state token is noise; here it is the difference
/// between "the app is broken" and "that one IMAP account stopped answering at
/// 04:12, and the cursor has not moved since".
///
/// The limits are read from the live Session rather than restated as
/// constants. They are per-server and configurable, and a screen that printed
/// this app's assumptions instead of the server's answers would be at its most
/// confidently wrong exactly when someone came here to find out why an upload
/// failed.
struct ServerDiagnosticsView: View {
    let connection: ServerConnection
    let sync: MailSyncService
    let store: SyncStore

    @State private var session: Session?
    @State private var sessionFailure: String?
    @State private var accounts: [AccountSnapshot] = []
    @State private var didCopy = false
    /// The result of the last **deliberate** check, or nil because nobody has
    /// asked for one.
    ///
    /// Nil on open, always. Android's standing rule is worth adopting verbatim:
    /// never make requests just because the screen was opened. The first thing
    /// someone does when their server is struggling must not be to add traffic
    /// to it.
    @State private var echo: EchoResult?
    @State private var isChecking = false

    /// What one `Core/echo` round trip found out.
    ///
    /// `Core/echo` is the cheapest probe there is — it takes no `accountId`,
    /// reads nothing and writes nothing — which is exactly what an "is the
    /// server answering" check should cost on a machine with one PHP worker
    /// pool. A failed sync tells you something is wrong; this tells you whether
    /// it is the server, the credential or the mail.
    private struct EchoResult: Equatable {
        var checkedAt: Date
        /// Round-trip time. The number people actually want: a NAS answering in
        /// 4 seconds is a different problem from one not answering.
        var duration: Duration?
        /// Verbatim, and never rewritten into something friendlier. Whoever
        /// reads this screen operates the server, and the exact error is the
        /// thing they can act on.
        var failure: String?

        var succeeded: Bool { failure == nil }
    }

    var body: some View {
        List {
            connectionSection
            checkSection
            accountsSection
            limitsSection
            pushSection
            reportSection
        }
        .navigationTitle(Text(.ui("Diagnostics")))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            LabeledContent(.ui("Address"), value: connection.host)
            LabeledContent(.ui("Signed in as"), value: connection.username ?? "—")
            LabeledContent(.ui("Status")) { statusText }

            if let lastCheckedAt = sync.lastCheckedAt {
                // Absolute, with the date. Relative time is right on a message
                // list, where recency is what matters; it is wrong here, where
                // the job is correlating against a server log or the moment
                // somebody restarted a container. "Yesterday" cannot be lined
                // up against a log line and "01/08/2026, 03:14" can.
                LabeledContent(.ui("Last checked")) {
                    Text(verbatim: absolute(lastCheckedAt))
                }
            }

            if let fingerprint = connection.pinnedFingerprint {
                // Shown, not merely asserted. Neither client could display a
                // pin once it was accepted, so the one moment a user could
                // compare it against `openssl` was during onboarding — the one
                // moment they have nothing to compare it with.
                //
                // **Not clearable, deliberately.** `ServerTrust`'s fourth
                // branch refuses a changed key permanently rather than
                // degrading back into a prompt, and a Clear button here would
                // be a way around that.
                LabeledContent(.ui("Certificate pinned")) {
                    Text(verbatim: fingerprint.description)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }

            if connection.address.isCleartext {
                Label(.ui("Unencrypted connection"), systemImage: "lock.open")
                    .font(.footnote)
                    .foregroundStyle(ActionTint.spam)
            }
        } header: {
            Text(.ui("Connection"))
        }
    }

    /// The one thing on this screen that costs the server anything, behind a
    /// button the user has to press.
    private var checkSection: some View {
        Section {
            Button {
                Task { await check() }
            } label: {
                LabeledContent {
                    if isChecking { ProgressView() }
                } label: {
                    Label(.ui("Check now"), systemImage: "bolt.horizontal")
                }
            }
            .disabled(isChecking)

            if let echo {
                LabeledContent(.ui("Result")) {
                    if echo.succeeded {
                        Text(.ui("Answered"))
                    } else {
                        Text(.ui("No answer"))
                            .foregroundStyle(ActionTint.spam)
                    }
                }

                if let duration = echo.duration {
                    LabeledContent(.ui("Round trip")) {
                        Text(verbatim: duration.formatted(.units(allowed: [.milliseconds])))
                    }
                }

                LabeledContent(.ui("Checked at")) {
                    Text(verbatim: absolute(echo.checkedAt))
                }

                if let failure = echo.failure {
                    Text(verbatim: failure)
                        .font(.footnote)
                        .foregroundStyle(ActionTint.spam)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text(.ui("Check"))
        } footer: {
            Text(
                .ui(
                    "Sends the smallest request there is and times the reply. It reads no mail and changes nothing, and nothing on this screen contacts your server until you press it."
                ))
        }
    }

    @ViewBuilder
    private var accountsSection: some View {
        ForEach(displayedAccounts) { account in
            Section {
                if let message = sync.degradedAccounts[account.accountKey]
                    ?? account.lastSyncError
                {
                    Label {
                        Text(verbatim: message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(ActionTint.spam)
                }

                LabeledContent(.ui("Last sync")) {
                    if let lastSyncedAt = account.lastSyncedAt {
                        Text(verbatim: absolute(lastSyncedAt))
                    } else {
                        Text(.ui("Never"))
                    }
                }

                LabeledContent(.ui("Account id"), value: account.accountID.rawValue)

                // The three cursors, named after the JMAP object each belongs
                // to. A stale one here against a moving one on the server is
                // the whole diagnosis for "new mail never arrives".
                stateRow(.ui("Messages"), token: account.emailState)
                stateRow(.ui("Conversations"), token: account.threadState)
                stateRow(.ui("Labels"), token: account.mailboxState)
            } header: {
                Text(verbatim: account.displayName)
            }
        }
    }

    @ViewBuilder
    private var limitsSection: some View {
        Section {
            if let core = session?.capabilities.core {
                LabeledContent(.ui("Largest attachment")) {
                    Text(Int64(core.maxSizeUpload).formatted(.byteCount(style: .file)))
                }
                LabeledContent(.ui("Largest request")) {
                    Text(Int64(core.maxSizeRequestObject).formatted(.byteCount(style: .file)))
                }
                LabeledContent(.ui("Objects per read"), value: core.maxObjectsInGet.formatted())
                LabeledContent(.ui("Objects per write"), value: core.maxObjectsInSet.formatted())
                LabeledContent(.ui("Calls per request"), value: core.maxCallsInRequest.formatted())
                LabeledContent(
                    .ui("Requests at once"), value: core.maxConcurrentRequests.formatted())

                // Per account in JMAP, but identical across accounts on this
                // server, so the first one that publishes it answers for the
                // screen. It is here rather than only in the composer because
                // "why was my scheduled message refused" is asked here.
                if let seconds = schedulingCeiling {
                    LabeledContent(.ui("Furthest ahead a send can be scheduled")) {
                        Text(
                            verbatim: Duration.seconds(seconds)
                                .formatted(.units(allowed: [.days, .hours])))
                    }
                }
            } else if let sessionFailure {
                Label {
                    Text(verbatim: sessionFailure)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(ActionTint.spam)
            } else {
                ProgressView()
            }
        } header: {
            Text(.ui("Server limits"))
        } footer: {
            Text(
                .ui(
                    "Your server's own numbers, not the app's. A message with a bigger attachment than this is refused before it is sent, and bulk actions are split to fit."
                ))
        }
    }

    @ViewBuilder
    private var pushSection: some View {
        if let session {
            Section {
                if let apns = session.capabilities.apns {
                    Label(.ui("This server can send push notifications"), systemImage: "bell.badge")
                        .font(.footnote)

                    if let environment = apns.environment {
                        LabeledContent(.ui("Environment"), value: environment)
                    }
                    if let topic = apns.topic {
                        LabeledContent(.ui("Topic"), value: topic)
                    }
                } else {
                    // The normal case, and it must read as normal. Sending to
                    // APNs needs a paid Apple developer key, which almost no
                    // self-hoster has; the app polls instead and says so.
                    Label(.ui("No push from this server"), systemImage: "bell.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // The evidence, one tap away. Two hundred `stream` lines beside
                // "no push from this server" is the diagnosis for "mail only
                // arrives while the app is open", and nothing else in the app
                // can tell those two apart.
                NavigationLink {
                    PushLogView(sync: sync)
                } label: {
                    Label(.ui("Push log"), systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text(.ui("Notifications"))
            } footer: {
                if session.capabilities.apns == nil {
                    Text(
                        .ui(
                            "Sending push notifications to an iPhone needs an Apple developer key on the server. Without one, mail arrives when the app checks — on opening it, and in the background when iOS allows."
                        ))
                }
            }
        }
    }

    private var reportSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = report()
                didCopy = true
            } label: {
                Label(
                    didCopy ? .ui("Copied") : .ui("Copy diagnostics"),
                    systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
        } footer: {
            Text(
                .ui(
                    "Everything on this screen as plain text, for pasting into a bug report. It contains your server's address and your mailbox names, and never your app password."
                ))
        }
    }

    // MARK: - Pieces

    /// Monospaced and truncated in the middle: a state token is an opaque
    /// string that is compared, not read, so the ends are what identify it and
    /// a proportional font makes two similar ones look identical.
    private func stateRow(_ label: LocalizedStringResource, token: StateToken?) -> some View {
        LabeledContent(label) {
            Text(verbatim: token?.rawValue ?? "—")
                .font(.footnote.monospaced())
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var displayedAccounts: [AccountSnapshot] {
        accounts.isEmpty ? sync.accounts : accounts
    }

    /// The scheduling ceiling in seconds, from the first account that publishes
    /// one.
    ///
    /// Nil on a server that publishes none, which is not the same as zero: zero
    /// is "this server does not do delayed send" and is worth drawing, while
    /// nil is an older server whose behaviour is only discoverable by trying.
    private var schedulingCeiling: Int? {
        guard let session else { return nil }

        return
            displayedAccounts
            .compactMap { session.submissionCapabilities(for: $0.accountID)?.maxDelayedSend }
            .first
    }

    private var statusText: Text {
        switch sync.status {
        case .idle: Text(.ui("Connected"))
        case .syncing: Text(.ui("Checking…"))
        case .unauthenticated: Text(.ui("App password rejected"))
        case .failed(let message): Text(verbatim: message)
        }
    }

    /// On-screen timestamps carry the date and the time, always.
    ///
    /// One function so that every row on the screen agrees: two rows formatted
    /// differently look like two different kinds of fact, and the whole use of
    /// this screen is comparing them against each other and against a log.
    private func absolute(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }

    // MARK: - Loading

    /// One `Core/echo`, timed.
    ///
    /// It goes through `sync.jmapClient` rather than a client of its own so
    /// that it queues behind the same `RequestGate` as everything else. A probe
    /// that jumped the queue would report a round trip nobody else's request
    /// could get, which is the opposite of what a diagnostic is for.
    private func check() async {
        isChecking = true

        let started = ContinuousClock.now

        do {
            var builder = RequestBuilder(session: try await sync.jmapClient.session())
            let call = builder.add(CoreEcho(.object(["plmail": .string("ping")])))
            let results = try await sync.jmapClient.send(builder)

            if let error = results.failure(of: call) { throw error }

            _ = try results.result(of: call)

            echo = EchoResult(checkedAt: .now, duration: ContinuousClock.now - started)
        } catch {
            // The error verbatim. Whoever reads this screen runs the server,
            // and "something went wrong" is the one answer they cannot use.
            echo = EchoResult(
                checkedAt: .now, duration: ContinuousClock.now - started,
                failure: String(describing: error))
        }

        isChecking = false
    }

    private func reload() async {
        accounts = (try? await store.accounts()) ?? []

        do {
            session = try await sync.jmapClient.session()
            sessionFailure = nil
        } catch {
            session = nil
            sessionFailure = String(describing: error)
        }
    }

    /// The report is deliberately **not** localised.
    ///
    /// It exists to be pasted into an issue or a forum post that whoever reads
    /// it will be reading in English, and a German traceback helps nobody
    /// debug it. The screen above is the localised one; this is the artefact.
    private func report() -> String {
        var lines: [String] = ["plMail for iOS diagnostics"]

        lines.append("server: \(connection.host)")
        lines.append("user: \(connection.username ?? "unknown")")
        lines.append("pinned: \(connection.pinnedFingerprint?.hex ?? "no")")
        lines.append("cleartext: \(connection.address.isCleartext ? "yes" : "no")")
        lines.append("status: \(sync.status)")
        lines.append("lastChecked: \(sync.lastCheckedAt.map(isoFormatted) ?? "never")")

        if let echo {
            lines.append(
                "echo: \(echo.succeeded ? "ok" : "failed") at \(isoFormatted(echo.checkedAt))")

            if let duration = echo.duration { lines.append("echoDuration: \(duration)") }
            if let failure = echo.failure { lines.append("echoError: \(failure)") }
        }

        for account in displayedAccounts {
            lines.append("")
            lines.append("account \(account.accountID.rawValue): \(account.displayName)")
            lines.append("  readOnly: \(account.isReadOnly)")
            lines.append("  lastSynced: \(account.lastSyncedAt.map(isoFormatted) ?? "never")")
            lines.append(
                "  error: \(sync.degradedAccounts[account.accountKey] ?? account.lastSyncError ?? "none")"
            )
            lines.append("  emailState: \(account.emailState?.rawValue ?? "—")")
            lines.append("  threadState: \(account.threadState?.rawValue ?? "—")")
            lines.append("  mailboxState: \(account.mailboxState?.rawValue ?? "—")")

            if let submission = session?.submissionCapabilities(for: account.accountID) {
                lines.append(
                    "  maxDelayedSend: \(submission.maxDelayedSend.map(String.init) ?? "—")")
            }
        }

        if let core = session?.capabilities.core {
            lines.append("")
            lines.append("limits")
            lines.append("  maxSizeUpload: \(core.maxSizeUpload)")
            lines.append("  maxSizeRequestObject: \(core.maxSizeRequestObject)")
            lines.append("  maxObjectsInGet: \(core.maxObjectsInGet)")
            lines.append("  maxObjectsInSet: \(core.maxObjectsInSet)")
            lines.append("  maxCallsInRequest: \(core.maxCallsInRequest)")
            lines.append("  maxConcurrentRequests: \(core.maxConcurrentRequests)")
            lines.append("  maxConcurrentUpload: \(core.maxConcurrentUpload)")
        }

        if let session {
            lines.append("")
            lines.append("apns: \(session.capabilities.apns == nil ? "not advertised" : "yes")")
            lines.append(
                "webPush: \(session.capabilities.push?.isConfigured == true ? "configured" : "no")")
        }

        if let sessionFailure {
            lines.append("")
            lines.append("sessionError: \(sessionFailure)")
        }

        return lines.joined(separator: "\n")
    }

    private func isoFormatted(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

#endif
