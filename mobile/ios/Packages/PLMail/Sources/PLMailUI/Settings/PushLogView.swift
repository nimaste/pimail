#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// What actually reached this device, and by which route.
///
/// The screen exists because the two ways mail can arrive live are drawn
/// identically everywhere else. Someone whose mail appears the instant the app
/// is open and never while it is closed has a live EventSource stream and no
/// working subscription — a real, common and completely invisible state. One
/// badge per row separates them.
///
/// The registration is at the top rather than the bottom because it is what the
/// rows are evidence *about*: two hundred `stream` lines mean one thing beside a
/// live registration and something else beside none.
struct PushLogView: View {
    let sync: MailSyncService

    @State private var entries: [PushLogEntry] = []
    @State private var session: Session?

    var body: some View {
        List {
            registrationSection
            entriesSection
        }
        .navigationTitle(Text(.ui("Push log")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(.ui("Clear")) {
                    Task {
                        await PushActivityLog.shared.clear()
                        await reload()
                    }
                }
                .disabled(entries.isEmpty)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var registrationSection: some View {
        Section {
            if let session, session.capabilities.apns != nil {
                Label(.ui("This server can send push notifications"), systemImage: "bell.badge")
                    .font(.footnote)
            } else {
                // The ordinary case, and it has to read as ordinary. Nobody
                // self-hosting has an Apple developer key, and a warning icon
                // here would send people looking for a fault that is not there.
                Label(.ui("No push subscription"), systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            LabeledContent(.ui("Live updates")) {
                // Whether the stream is *allowed* to be open, which is what the
                // rows below are produced by. It is deliberately not a live
                // connection state: opening this screen must not open a stream
                // to find out, and a check that did would answer its own
                // question.
                Text(sync.status == .unauthenticated ? .ui("Signed out") : .ui("While app is open"))
            }
        } header: {
            Text(.ui("Registration"))
        } footer: {
            Text(
                .ui(
                    "Your server keeps its own record of what it sent. Comparing it with this list line by line is what tells you which half went missing."
                ))
        }
    }

    @ViewBuilder
    private var entriesSection: some View {
        Section {
            if entries.isEmpty {
                Text(.ui("Nothing has arrived yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
        } header: {
            Text(.ui("Received"))
        } footer: {
            Text(
                .ui(
                    "Only which mailboxes changed, never what was in them. The newest is at the top and the oldest are dropped."
                ))
        }
    }

    private func row(_ entry: PushLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Absolute and monospaced. Relative time is right on a message
                // list, where recency is what matters; here the job is lining a
                // row up against a server log or the moment someone restarted a
                // container, and "yesterday" cannot be lined up against
                // anything.
                Text(verbatim: entry.receivedAt.formatted(date: .numeric, time: .standard))
                    .font(.footnote.monospaced())

                Spacer()

                Text(verbatim: entry.route.rawValue)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(PanelStyle.hairline, in: Capsule())
            }

            Text(verbatim: entry.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                .ui(
                    "\(entry.route.rawValue) at \(entry.receivedAt.formatted(date: .abbreviated, time: .standard))"
                )))
    }

    private func reload() async {
        entries = await PushActivityLog.shared.recent()
        session = try? await sync.jmapClient.session()
    }
}

#endif
