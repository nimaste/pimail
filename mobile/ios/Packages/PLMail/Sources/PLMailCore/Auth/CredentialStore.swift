import Foundation
import JMAPKit
import Security

/// Stores the one thing the app cannot re-fetch.
///
/// Everything else — mail, threads, mailboxes, sync cursors — is a cache that
/// can be deleted and rebuilt from the server. The address and the app
/// password cannot, so they go to the Keychain and nowhere else.
///
/// The item is a `kSecClassInternetPassword`, which is what this actually is —
/// a credential for a host — and which means it shows up sensibly in Keychain
/// Access if someone goes looking. Note that class has **no** `kSecAttrService`
/// attribute; that belongs to generic passwords, and passing it yields
/// `errSecNoSuchAttr` rather than being ignored. The app's own tag lives in
/// `kSecAttrLabel`, which is valid for every class and is searchable.
public struct CredentialStore: Sendable {
    private let label: String

    public init(label: String = "de.plmail.server") {
        self.label = label
    }

    public enum StoreError: Error, Equatable, Sendable {
        case keychain(OSStatus)
        case malformedEntry
    }

    // MARK: - Reading

    /// The saved connection, if the user has completed onboarding.
    public func load() throws -> ServerConnection? {
        var query = identityQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }

        guard let entry = item as? [String: Any],
            let secretData = entry[kSecValueData as String] as? Data,
            let secret = String(data: secretData, encoding: .utf8)
        else {
            throw StoreError.malformedEntry
        }

        // The address, the pin and the username ride along in the comment.
        // None of them is a secret, but all of them are useless without the
        // credential and stale the moment it is revoked — so keeping them in
        // the same item means one write, one delete, and no way for them to
        // disagree with each other.
        let metadata = Metadata(encoded: entry[kSecAttrComment as String] as? String)

        guard let addressText = metadata.address,
            let address = try? ServerAddress.parse(addressText)
        else {
            throw StoreError.malformedEntry
        }

        return ServerConnection(
            address: address,
            credential: .appPassword(secret),
            pinnedFingerprint: metadata.fingerprint,
            username: metadata.username
        )
    }

    // MARK: - Writing

    /// Saves a connection, replacing any existing one.
    ///
    /// The app talks to one server; signing into another replaces the first
    /// rather than accumulating, and the cache is dropped alongside it.
    public func save(_ connection: ServerConnection) throws {
        try? delete()

        let metadata = Metadata(
            address: connection.address.baseURL.absoluteString,
            fingerprint: connection.pinnedFingerprint,
            username: connection.username
        )

        var attributes = identityQuery
        attributes[kSecAttrServer as String] = connection.host
        attributes[kSecAttrAccount as String] = connection.username ?? connection.host
        attributes[kSecAttrComment as String] = metadata.encoded
        // AfterFirstUnlock rather than WhenUnlocked: a background refresh
        // fires while the phone is in a pocket, and WhenUnlocked would make
        // every one of those fail with an opaque Keychain error.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        // An app password identifies one device to the server, and the
        // server's own lastUsedAt model assumes that. Syncing it through
        // iCloud would make that meaningless and would put the secret
        // somewhere the user did not choose to put it.
        attributes[kSecAttrSynchronizable as String] = false
        attributes[kSecValueData as String] = Data(connection.credential.secret.utf8)

        let status = SecItemAdd(attributes as CFDictionary, nil)

        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    /// Forgets the connection. The caller is responsible for deleting the
    /// cached mail that belonged to it.
    public func delete() throws {
        let status = SecItemDelete(identityQuery as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    /// What identifies this app's item, used identically for add, find and
    /// delete so the three can never drift apart.
    private var identityQuery: [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
        ]
    }
}

/// The non-secret parts of a connection, packed into one Keychain attribute.
private struct Metadata {
    var address: String?
    var fingerprint: KeyFingerprint?
    var username: String?

    init(address: String? = nil, fingerprint: KeyFingerprint? = nil, username: String? = nil) {
        self.address = address
        self.fingerprint = fingerprint
        self.username = username
    }

    init(encoded: String?) {
        guard let encoded else { return }

        for field in encoded.split(separator: "\n") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            switch parts[0] {
            case "url": address = String(parts[1])
            case "pin": fingerprint = KeyFingerprint(hex: String(parts[1]))
            case "user": username = String(parts[1])
            default: break
            }
        }
    }

    var encoded: String {
        var fields: [String] = []

        // Newline-separated: a URL can contain almost any other separator, and
        // a mail address can never contain a newline.
        if let address { fields.append("url=\(address)") }
        if let fingerprint { fields.append("pin=\(fingerprint.hex)") }
        if let username { fields.append("user=\(username)") }

        return fields.joined(separator: "\n")
    }
}
