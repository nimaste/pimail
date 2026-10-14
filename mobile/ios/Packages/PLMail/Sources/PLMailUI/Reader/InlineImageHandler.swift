#if os(iOS)

import Foundation
import PLMailCore
import WebKit

/// Serves `cid:` inline images to the message renderer from local files.
///
/// A custom scheme rather than pointing the web view at the server's
/// download URL. Three reasons, all of which bite:
///
/// - The download endpoint needs an `Authorization` header, which a web
///   view's subresource loads will not carry.
/// - The server ignores the `accept` parameter and always sets
///   `nosniff`, so what comes back is not guaranteed to render inline.
/// - Handing a renderer a remote URL means the renderer decides when to
///   fetch it, which is exactly the control this app is trying to keep.
final class InlineImageHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "plmail-inline"

    /// Set before each load by the view that owns this handler.
    var parts: [AttachmentSnapshot] = []
    var accountKey: String = ""
    /// Supplies bytes for a part. Injected so this stays testable and so
    /// the handler does not have to know about the client or the session.
    var provider: (@Sendable (AttachmentSnapshot, String) async -> Data?)?

    private var running: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(task)
        running.insert(identifier)

        guard let host = task.request.url?.host(),
            let part = parts.first(where: { $0.partID == host }),
            let provider
        else {
            finish(task, identifier: identifier, data: nil, type: nil)
            return
        }

        let accountKey = accountKey

        Task { [weak self] in
            let data = await provider(part, accountKey)

            await MainActor.run {
                self?.finish(task, identifier: identifier, data: data, type: part.type)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        // Marked stopped so the async completion above does not call into
        // a task WebKit has already torn down, which traps.
        running.remove(ObjectIdentifier(task))
    }

    private func finish(
        _ task: any WKURLSchemeTask,
        identifier: ObjectIdentifier,
        data: Data?,
        type: String?
    ) {
        guard running.remove(identifier) != nil else { return }

        guard let data, let url = task.request.url else {
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: type ?? "application/octet-stream",
            expectedContentLength: data.count,
            textEncodingName: nil
        )

        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

#endif
