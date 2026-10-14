import CryptoKit
import Foundation
import JMAPKit
import OSLog

/// Stores downloaded attachment bytes on disk.
///
/// Deliberately not in SwiftData: a 20MB PDF in a SQLite row bloats every
/// query that touches the table, and the bytes are re-fetchable. `Library/
/// Caches` is the honest location — the OS may reclaim it under pressure, and
/// everything here survives that by being downloadable again.
public actor BlobCache {
    private let directory: URL
    private let session: URLSession
    private let byteBudget: Int
    private let logger = Logger(subsystem: "de.plmail", category: "blobs")

    /// In-flight downloads, so two views opening the same attachment at once
    /// cause one request rather than two writes racing for the same file.
    private var inFlight: [String: Task<URL, any Error>] = [:]

    public init(
        serverID: String,
        session: URLSession = .shared,
        byteBudget: Int = 256 * 1024 * 1024
    ) {
        directory = URL.cachesDirectory
            .appending(path: "plmail-blobs")
            .appending(path: Self.slug(serverID))
        self.session = session
        self.byteBudget = byteBudget

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// The local file for a blob, downloading it if it isn't cached.
    ///
    /// - Parameters:
    ///   - blobID: Opaque and namespaced server-side; hashed for the filename
    ///     rather than used directly, because it is not a safe path component
    ///     and the spec forbids parsing it.
    ///   - accountID: Which account the blob belongs to. Blobs are scoped to
    ///     an account server-side, so this is part of the identity.
    ///   - name: The attachment's filename, used only for the extension so
    ///     Quick Look can pick a preview.
    ///   - type: The declared content type, used as a fallback extension.
    ///   - downloadURL: The template from the live session. Never built by
    ///     hand: the server may sit behind a reverse proxy on any path.
    ///   - credential: Sent as an `Authorization` header.
    /// - Returns: A file URL that exists.
    /// - Throws: ``JMAPKit/JMAPError`` when the download fails, or a file
    ///   error if the result cannot be written.
    public func file(
        blobID: BlobID,
        accountID: AccountID,
        name: String?,
        type: String,
        downloadURL: URLTemplate,
        credential: Credential
    ) async throws -> URL {
        // The blob id is opaque and not a safe path component, so it is
        // hashed into a directory name — but the *file* inside keeps the
        // attachment's real name, because that is what Quick Look and the
        // share sheet show. A hash on screen reads as a bug.
        let key = Self.slug("\(accountID.rawValue)-\(blobID.rawValue)")
        let folder = directory.appending(path: key)
        let destination = folder.appending(path: Self.fileName(name: name, type: type))

        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            touch(destination)
            return destination
        }

        if let existing = inFlight[key] { return try await existing.value }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let task = Task<URL, any Error> {
            try await download(
                blobID: blobID,
                accountID: accountID,
                name: name,
                type: type,
                downloadURL: downloadURL,
                credential: credential,
                to: destination
            )
        }
        inFlight[key] = task

        defer { inFlight[key] = nil }

        let url = try await task.value
        evictIfNeeded()

        return url
    }

    /// The local file for a blob **only if it is already on disk**.
    ///
    /// The whole thumbnail grid rests on this call. Drawing a message's
    /// attachments asks this and nothing else, so appearing on screen can
    /// never cost a request — a thumbnail is drawn for exactly those blobs the
    /// user already pulled down by opening or saving them, and that stays true
    /// with the phone in aeroplane mode.
    ///
    /// **Changes nothing about eviction or caching.** It does not download, it
    /// does not create the folder, and it deliberately does not ``touch(_:)``
    /// the file: drawing a tile is not using an attachment, and a peek that
    /// warmed the LRU would let a scroll through an old thread hold newer
    /// downloads out of the cache. Reading the file to render it updates the
    /// access date on its own, which is the honest signal.
    ///
    /// - Returns: A file URL that exists, or nil. Nil is an ordinary answer —
    ///   the blob was never fetched, or eviction reclaimed it.
    public func cachedFile(
        blobID: BlobID,
        accountID: AccountID,
        name: String?,
        type: String
    ) -> URL? {
        let key = Self.slug("\(accountID.rawValue)-\(blobID.rawValue)")
        let destination =
            directory
            .appending(path: key)
            .appending(path: Self.fileName(name: name, type: type))

        guard FileManager.default.fileExists(atPath: destination.path(percentEncoded: false))
        else { return nil }

        return destination
    }

    private func download(
        blobID: BlobID,
        accountID: AccountID,
        name: String?,
        type: String,
        downloadURL: URLTemplate,
        credential: Credential,
        to destination: URL
    ) async throws -> URL {
        // Expanded from the session's own template. Never constructed by hand:
        // the server may live behind a reverse proxy on any path.
        guard
            let url = downloadURL.expanded([
                "accountId": accountID.rawValue,
                "blobId": blobID.rawValue,
                "name": name ?? "attachment",
                "type": type,
            ])
        else {
            throw JMAPError.malformedResponse("Could not build a download URL for \(blobID).")
        }

        var request = URLRequest(url: url)
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")

        let (temporary, response) = try await session.download(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw JMAPError.malformedResponse("Not an HTTP response.")
        }

        guard http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)

            if http.statusCode == 401 { throw JMAPError.notAuthenticated(detail: nil) }
            throw JMAPError.unexpectedStatus(code: http.statusCode)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)

        return destination
    }

    // MARK: - Eviction

    /// Drops the least recently used files once the budget is exceeded.
    ///
    /// Approximate on purpose: this runs after a download, not on a timer, and
    /// being a little over budget between two attachments is cheaper than
    /// walking the directory more often.
    private func evictIfNeeded() {
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .fileSizeKey]

        guard
            let folders = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys)
            )
        else { return }

        // One directory per blob, so eviction removes the directory and the
        // file it holds together.
        let described = folders.compactMap { folder -> (URL, Date, Int)? in
            guard
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: Array(keys)),
                let file = contents.first,
                let values = try? file.resourceValues(forKeys: keys),
                let size = values.fileSize
            else { return nil }

            return (folder, values.contentAccessDate ?? .distantPast, size)
        }

        var total = described.reduce(0) { $0 + $1.2 }

        guard total > byteBudget else { return }

        for (url, _, size) in described.sorted(by: { $0.1 < $1.1 }) {
            guard total > byteBudget else { break }

            try? FileManager.default.removeItem(at: url)
            total -= size
        }

        logger.info("Evicted blobs down to \(total) bytes.")
    }

    /// Marks a file as recently used, so eviction sees it as warm.
    private nonisolated func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date.now], ofItemAtPath: url.path(percentEncoded: false))
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Naming

    /// A filesystem-safe name for an opaque id.
    static func slug(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The on-disk filename: the sender's own, made safe.
    ///
    /// Path separators are stripped rather than escaped — a filename is
    /// attacker-controlled, and the only safe reading of `../` in one is that
    /// it is not a directory traversal.
    static func fileName(name: String?, type: String) -> String {
        let cleaned =
            (name ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)

        let ext = fileExtension(name: name, type: type)

        guard cleaned.isEmpty == false, cleaned != ".", cleaned != ".." else {
            return ext.isEmpty ? "Attachment" : "Attachment.\(ext)"
        }

        // Quick Look picks its previewer from the extension, so one is added
        // when the sender did not supply it.
        if cleaned.contains("."), ext.isEmpty == false, cleaned.hasSuffix(ext) {
            return String(cleaned)
        }

        return ext.isEmpty ? String(cleaned) : "\(cleaned).\(ext)"
    }

    /// Quick Look picks a previewer from the extension, so one is worth
    /// deriving even when the filename has none.
    static func fileExtension(name: String?, type: String) -> String {
        if let name, let ext = name.split(separator: ".").last, name.contains("."), ext.count <= 5 {
            return String(ext).lowercased()
        }

        return switch type.lowercased() {
        case "application/pdf": "pdf"
        case "image/png": "png"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/gif": "gif"
        case "image/heic": "heic"
        case "text/plain": "txt"
        case "text/html": "html"
        case "text/calendar": "ics"
        default: ""
        }
    }
}
