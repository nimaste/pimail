// The package declares macOS so `swift test` runs on the host without booting
// a simulator; the app itself is iOS-only, and this file uses UIKit directly.
#if os(iOS)

public import PLMailCore

import SafariServices
import SwiftUI
import UIKit

/// Connecting to a server, first run.
///
/// Two things shape this screen. The address is free text because plMail is
/// self-hosted and there is no canonical host to default to. And the credential
/// is a 71-character secret shown exactly once in a web UI, most likely on a
/// different device — so the field is paste-first, monospaced, and never
/// autocorrected.
public struct ServerSetupView: View {
    /// A `plmail://pair` link the app was opened with.
    ///
    /// Handed in rather than observed here so the shell owns URL handling:
    /// this view exists only while signed out, and a link that arrived a
    /// moment before it appeared would otherwise be dropped.
    public var pairingLink: URL?

    @State private var model: ServerSetupModel
    @State private var isShowingWebUI = false
    @State private var isScanning = false
    @FocusState private var focus: Field?

    private enum Field { case address, secret }

    /// Pre-filling `address` is what makes this screen usable for replacing a
    /// rejected app password rather than only for signing in the first time:
    /// the server has not moved, and making somebody retype their own hostname
    /// to fix a credential the server revoked invites a typo into a flow that
    /// was working.
    public init(
        pairingLink: URL? = nil,
        address: String = "",
        onConnected: @escaping @MainActor (ServerConnection) -> Void
    ) {
        self.pairingLink = pairingLink
        _model = State(
            wrappedValue: ServerSetupModel(address: address, onConnected: onConnected))
    }

    public var body: some View {
        NavigationStack {
            Form {
                pairingSection
                serverSection
                credentialSection
                statusSection
            }
            // Two short fields stretched across an iPad read as a form that
            // failed to lay out. Capped at a comfortable measure and centred,
            // which is what every system setup flow does at this width; the
            // cap is above any iPhone's width, so nothing changes there.
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .navigationTitle(.ui("Connect to plMail"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Button(.ui("Connect")) {
                            Task { await model.connect() }
                        }
                        .disabled(model.canConnect == false)
                    }
                }
            }
            .sheet(isPresented: $isShowingWebUI) { webUISheet }
            .sheet(isPresented: $isScanning) {
                PairingScannerSheet { scanned in
                    Task { await model.pair(with: scanned, deviceName: UIDevice.current.name) }
                }
            }
            .disabled(model.isBusy)
            .task(id: pairingLink) {
                guard let pairingLink else { return }

                await model.pair(
                    with: pairingLink.absoluteString, deviceName: UIDevice.current.name)
            }
        }
    }

    // MARK: - Sections

    /// The way in that does not involve retyping 71 characters of hex from one
    /// screen onto another. Offered first, and prominently, because it is the
    /// path that works — the typed one exists for servers whose web UI cannot
    /// be reached from this device.
    private var pairingSection: some View {
        Section {
            Button {
                isScanning = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.ui("Scan a pairing code"))
                            .font(.body.weight(.medium))
                        Text(.ui("In plMail: Settings → App passwords → Pair a device"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title2)
                }
            }
            .disabled(model.isBusy)
        } footer: {
            Text(.ui("Or enter the address and an app password by hand."))
        }
    }

    private var serverSection: some View {
        Section {
            TextField("nas.local", text: $model.addressText)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .address)
                .submitLabel(.next)
                .onSubmit { focus = .secret }
        } header: {
            Text(.ui("Server"))
        } footer: {
            // Before Connect can be pressed, deliberately. The app password is
            // a 71-character secret that cannot be un-sent, and a warning
            // shown afterwards — which is where the diagnostics screen puts it
            // — tells the user about something that has already happened.
            if model.warnsAboutCleartext {
                Label {
                    Text(
                        .ui(
                            "This address is unencrypted. Your app password and your mail will travel in the clear, so only use it on a network you trust."
                        ))
                } icon: {
                    Image(systemName: "lock.open.trianglebadge.exclamationmark")
                }
                .foregroundStyle(.orange)
            } else {
                Text(
                    .ui(
                        "The address you use to open plMail in a browser. https is assumed unless you type otherwise."
                    ))
            }
        }
    }

    private var credentialSection: some View {
        Section {
            // Deliberately no `.textContentType(.password)`. It makes iOS
            // offer to save this to iCloud Keychain, which is wrong twice
            // over: the app already stores it, and an app password identifies
            // one device to the server — syncing it across devices defeats
            // the point of being able to revoke one of them.
            TextField("plmail_…", text: $model.secretText, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .secret)
                .lineLimit(2...4)

            if model.secretLooksWrong {
                Label(
                    .ui("An app password starts with plmail_ and is 64 characters after that."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            DisclosureGroup(.ui("Where do I get one?")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        """
                        In plMail, open Settings → App passwords and create one. It's shown only \
                        once, so copy the whole thing.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    // App passwords are created in the web UI and there is no
                    // JMAP method for it. Rather than pretend otherwise, hand
                    // the user straight there.
                    Button(.ui("Open plMail in a browser")) { isShowingWebUI = true }
                        .disabled(model.addressText.isEmpty)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(.ui("App password"))
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.phase {
        case .editing, .connecting:
            EmptyView()

        case .confirming(let username, let accounts):
            Section {
                LabeledContent(.ui("Signed in as"), value: username)

                ForEach(accounts, id: \.self) { account in
                    Label(account, systemImage: "tray")
                }

                Button(.ui("Use this server")) { model.save() }
                    .fontWeight(.semibold)
            } header: {
                Text(.ui("Connected"))
            } footer: {
                // Shown before anything is written: someone with two NASes
                // should be able to tell which one they just reached.
                Text(.ui("Check this is the right mailbox before continuing."))
            }

        case .untrusted(let host, let fingerprint):
            Section {
                Text(
                    """
                    \(host) uses a certificate this device doesn't recognise. That's normal for a \
                    server on your own network, and expected if you issued the certificate \
                    yourself.
                    """
                )
                .font(.footnote)

                LabeledContent(.ui("Key fingerprint")) {
                    Text(fingerprint.description)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                }

                Button(.ui("Trust this certificate")) {
                    Task { await model.trustAndRetry() }
                }

                Button(.ui("Cancel"), role: .cancel) { model.editAgain() }
            } header: {
                Label(
                    .ui("Unrecognised certificate"),
                    systemImage: "lock.trianglebadge.exclamationmark")
            } footer: {
                Text(
                    .ui(
                        "Compare it against the server before trusting it. This app will refuse to connect if it ever changes."
                    ))
            }

        case .failed(let message):
            Section {
                Text(message)
                    .font(.footnote)

                Button(.ui("Try again")) { model.editAgain() }
            } header: {
                Label(.ui("Couldn't connect"), systemImage: "exclamationmark.triangle")
            }
        }
    }

    @ViewBuilder
    private var webUISheet: some View {
        if let address = try? ServerAddress.parse(model.addressText) {
            SafariView(url: address.baseURL)
                .ignoresSafeArea()
        } else {
            ContentUnavailableView(
                .ui("Enter an address first"),
                systemImage: "network",
                description: Text(.ui("Type your server's address above, then try again."))
            )
        }
    }
}

/// `SFSafariViewController`, so the web UI runs in a real browser with its own
/// cookie jar rather than inside a webview this app can see into.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

#endif
