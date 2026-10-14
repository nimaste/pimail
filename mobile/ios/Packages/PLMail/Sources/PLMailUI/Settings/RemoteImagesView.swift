#if os(iOS)

public import PLMailCore

import SwiftUI

/// The senders allowed to load remote images.
///
/// The reader blocks remote images because in mail a remote image is usually a
/// tracking pixel, and "load images from this sender" is a decision that then
/// sticks forever. Made once, in a hurry, from inside a message — and until
/// now with nowhere to see it again or take it back. A permission that can only
/// ever be granted is not a permission.
struct RemoteImagesView: View {
    @State private var senders: [String] = []
    @State private var isConfirmingRevokeAll = false

    private let policy = RemoteContentPolicy()

    var body: some View {
        List {
            if senders.isEmpty == false {
                Section {
                    ForEach(senders, id: \.self) { sender in
                        Text(verbatim: sender)
                            .swipeActions {
                                Button(.ui("Block"), systemImage: "eye.slash", role: .destructive) {
                                    policy.revoke(sender: sender)
                                    reload()
                                }
                            }
                    }
                } footer: {
                    Text(
                        .ui(
                            "Images in mail from these addresses load without asking. Everything else stays blocked until you tap Load."
                        ))
                }

                Section {
                    Button(.ui("Block all again"), role: .destructive) {
                        isConfirmingRevokeAll = true
                    }
                }
            }
        }
        .overlay {
            if senders.isEmpty {
                ContentUnavailableView(
                    .ui("No senders trusted"),
                    systemImage: "eye.slash",
                    description: Text(
                        .ui(
                            "Remote images are blocked everywhere. Tap Load on a message to let one sender through, and it appears here."
                        ))
                )
            }
        }
        .navigationTitle(Text(.ui("Remote images")))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            .ui("Block remote images from every sender?"),
            isPresented: $isConfirmingRevokeAll,
            titleVisibility: .visible
        ) {
            Button(.ui("Block all again"), role: .destructive) {
                policy.revokeAll()
                reload()
            }
            Button(.ui("Cancel"), role: .cancel) {}
        }
        .onAppear(perform: reload)
    }

    /// Read on appear rather than held in a binding: `RemoteContentPolicy` is a
    /// thin `UserDefaults` wrapper with no change notification, and the reader
    /// can add to it while this screen is not on top of the stack.
    private func reload() {
        senders = policy.allowedSenders()
    }
}

#endif
