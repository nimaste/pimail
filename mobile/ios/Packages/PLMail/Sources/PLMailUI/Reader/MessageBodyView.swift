#if os(iOS)

public import PLMailCore

import JMAPKit
import SafariServices
import SwiftUI
import WebKit

/// Renders one message's HTML.
///
/// The single most failure-prone view in the app, and every rule here is
/// load-bearing:
///
/// - **Dark mode is chosen per message, never applied blindly.** Mail is
///   authored for white, so one strategy cannot serve every message: a plain
///   reply is restyled outright, a designed newsletter is inverted with its
///   imagery inverted back so photos and logos stay right, and a message that
///   already ships dark styles is simply told the scheme and left alone.
///   Inverting everything is the one approach that reliably looks broken —
///   photos come out as negatives and adaptive mail double-inverts. See
///   ``PLMailCore/MessageRenderStyle``.
/// - **A way back to the original.** Inversion gets some messages wrong, and
///   when it does the reader needs to see what was actually sent.
/// - **Remote content blocked** until asked for. A remote image in mail is a
///   tracking pixel far more often than it is a picture.
/// - **`cid:` served from the local cache** through a scheme handler, so the
///   download URL is never handed to a web view. That matters because the
///   server ignores `accept`, always sets `nosniff`, and serves only
///   `image/*` inline.
/// - **No nested scrolling.** The web view reports its content height and
///   sizes to it, so the message scrolls with the thread around it.
struct MessageBodyView: View {
    let html: String
    let inlineParts: [AttachmentSnapshot]
    let accountKey: String
    let loadRemoteContent: Bool
    let renderStyle: MessageRenderStyle
    /// Supplies bytes for a `cid:` part. Without this the inline image handler
    /// has nothing to serve and every inline image renders broken.
    let inlineProvider: @Sendable (AttachmentSnapshot, String) async -> Data?
    let onRemoteContentBlocked: () -> Void

    /// Where to paint find highlights, as UTF-16 offsets into
    /// ``PLMailCore/ThreadFind/plainText(fromHTML:)`` of this same body. The
    /// web view never searches; see ``PLMailCore/ThreadFind``.
    var findMatches: [ThreadFindMatch] = []
    /// Which of them is the current one, or nil when the current match is in
    /// another message.
    var currentFindOccurrence: Int?
    /// How far down this body the current match sits, as a fraction of the
    /// content height. The thread's scroll view is the one that scrolls — this
    /// view is sized to its content and scrolls not at all — so putting a match
    /// on screen is something only the reader above can do.
    var onCurrentMatchPositioned: (CGFloat) -> Void = { _ in }

    @State private var height: CGFloat = 1

    var body: some View {
        WebBody(
            html: html,
            inlineParts: inlineParts,
            accountKey: accountKey,
            loadRemoteContent: loadRemoteContent,
            renderStyle: renderStyle,
            inlineProvider: inlineProvider,
            height: $height,
            onRemoteContentBlocked: onRemoteContentBlocked,
            findMatches: findMatches,
            currentFindOccurrence: currentFindOccurrence,
            onCurrentMatchPositioned: onCurrentMatchPositioned
        )
        .frame(height: height)
    }
}

private struct WebBody: UIViewRepresentable {
    let html: String
    let inlineParts: [AttachmentSnapshot]
    let accountKey: String
    let loadRemoteContent: Bool
    let renderStyle: MessageRenderStyle
    let inlineProvider: @Sendable (AttachmentSnapshot, String) async -> Data?
    @Binding var height: CGFloat
    let onRemoteContentBlocked: () -> Void
    let findMatches: [ThreadFindMatch]
    let currentFindOccurrence: Int?
    let onCurrentMatchPositioned: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            height: $height,
            onRemoteContentBlocked: onRemoteContentBlocked,
            onCurrentMatchPositioned: onCurrentMatchPositioned
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            context.coordinator.inlineHandler, forURLScheme: InlineImageHandler.scheme)

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.heightMessage)
        controller.add(context.coordinator, name: Coordinator.findPositionMessage)

        for script in [Self.heightReportingScript, Self.findScript] {
            controller.addUserScript(
                WKUserScript(
                    source: script,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }

        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let document = Self.document(html: html, inlineParts: inlineParts, style: renderStyle)

        // Set before the early return: the handler must be able to serve
        // inline images even when the document itself has not changed.
        context.coordinator.inlineHandler.parts = inlineParts
        context.coordinator.inlineHandler.accountKey = accountKey
        context.coordinator.inlineHandler.provider = inlineProvider
        context.coordinator.blocksRemoteContent = loadRemoteContent == false

        guard
            context.coordinator.renderedDocument != document
                || context.coordinator.renderedRemoteSetting != loadRemoteContent
        else {
            // Typing in the find bar changes nothing about the document, so
            // this is the path a search actually takes. Applying the highlight
            // after the early return would mean it only ever landed on a
            // message that happened to be reloading for another reason.
            context.coordinator.applyFind(
                matches: findMatches, current: currentFindOccurrence, to: webView)
            return
        }

        // The web view's own scheme has to match the strategy, or the gap
        // around a short message keeps the other appearance's colour.
        webView.overrideUserInterfaceStyle = renderStyle == .original ? .light : .dark
        webView.backgroundColor = UIColor(renderStyle.pageBackground)
        webView.scrollView.backgroundColor = webView.backgroundColor

        context.coordinator.renderedDocument = document
        context.coordinator.renderedRemoteSetting = loadRemoteContent

        // Held for the load to finish: a highlight applied now would be thrown
        // away with the document it was painted on.
        context.coordinator.pendingFind = (findMatches, currentFindOccurrence)

        // No base URL, so a relative reference in the message cannot
        // resolve to anything at all.
        webView.loadHTMLString(document, baseURL: nil)
    }

    // MARK: - Document

    /// Wraps the server's already-sanitised HTML.
    private static func document(
        html: String, inlineParts: [AttachmentSnapshot], style: MessageRenderStyle
    ) -> String {
        var body = html

        // Rewrite cid: references onto the custom scheme, so they are
        // served from the local cache rather than fetched.
        for part in inlineParts {
            guard let cid = part.cid else { continue }

            body = body.replacingOccurrences(
                of: "cid:\(cid)",
                with: "\(InlineImageHandler.scheme)://\(part.partID)"
            )
        }

        return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="\(style.declaredScheme)">
            <style>
              :root { color-scheme: \(style.declaredScheme); }
              html, body {
                margin: 0; padding: 0;
                font: -apple-system-body;
                -webkit-text-size-adjust: 100%;
              }
              body { padding: 0 16px 8px; overflow-wrap: break-word; }
              img, video, table { max-width: 100% !important; height: auto; }
              /* Wide tables scroll themselves rather than widening the page. */
              table { display: block; overflow-x: auto; }
              pre { overflow-x: auto; }
              \(style.css)
              \(style.findHighlightCSS)
            </style>
            </head>
            <body>\(body)</body>
            </html>
            """
    }

    /// Reports content height so SwiftUI can size the view.
    ///
    /// A `ResizeObserver` rather than a one-shot measurement: images and
    /// web fonts land after `DOMContentLoaded`, and a height taken before
    /// them clips the message.
    private static let heightReportingScript = """
        (function () {
          function report() {
            window.webkit.messageHandlers.\(Coordinator.heightMessage)
              .postMessage(document.documentElement.scrollHeight);
          }
          new ResizeObserver(report).observe(document.documentElement);
          window.addEventListener('load', report);
          report();
        })();
        """

    /// Paints find highlights at offsets computed natively.
    ///
    /// The script does no matching of its own — see ``PLMailCore/ThreadFind``
    /// for why that split is the whole design. Its two jobs are to rebuild the
    /// flat projection the offsets are stated against, and to turn an offset
    /// range back into a DOM `Range`.
    ///
    /// `flatten` is a transcription of `ThreadFind.collapsingWhitespace`, and
    /// has to stay one. The parallel arrays are indexed by UTF-16 unit, which
    /// is what `NSRange` counts in — iterating by code point instead would put
    /// every offset after the first emoji two places out.
    ///
    /// Highlighting is all-or-nothing on purpose. If an offset does not fit the
    /// projection the two sides have drifted, and a highlight on the wrong word
    /// is worse than no highlight at all: it is a wrong answer presented with
    /// the same confidence as a right one.
    private static let findScript = """
        (function () {
          var ALL = 'plmail-find';
          var CURRENT = 'plmail-find-current';

          function isSpace(ch) {
            return ch === ' ' || ch === '\\u00A0' || ch === '\\n' || ch === '\\r'
              || ch === '\\t' || ch === '\\u000B' || ch === '\\u000C';
          }

          function flatten() {
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
              acceptNode: function (node) {
                var name = node.parentNode ? node.parentNode.nodeName : '';
                if (name === 'SCRIPT' || name === 'STYLE') return NodeFilter.FILTER_REJECT;
                return NodeFilter.FILTER_ACCEPT;
              }
            });

            var text = '', nodes = [], offsets = [], node;

            while ((node = walker.nextNode())) {
              var data = node.data;
              for (var i = 0; i < data.length; i++) {
                if (isSpace(data[i])) {
                  if (text.length !== 0 && text[text.length - 1] !== ' ') {
                    text += ' '; nodes.push(node); offsets.push(i);
                  }
                } else {
                  text += data[i]; nodes.push(node); offsets.push(i);
                }
              }
            }

            if (text[text.length - 1] === ' ') {
              text = text.slice(0, -1); nodes.pop(); offsets.pop();
            }

            return { text: text, nodes: nodes, offsets: offsets };
          }

          window.plmailFind = function (matches, current) {
            if (typeof CSS === 'undefined' || !CSS.highlights) return;
            if (typeof Highlight === 'undefined') return;

            CSS.highlights.delete(ALL);
            CSS.highlights.delete(CURRENT);

            if (!matches || matches.length === 0) return;

            var flat = flatten(), all = [], currentRange = null;

            for (var m = 0; m < matches.length; m++) {
              var start = matches[m][0], length = matches[m][1], end = start + length - 1;

              if (length <= 0 || start < 0 || end >= flat.text.length) return;

              var range = document.createRange();
              range.setStart(flat.nodes[start], flat.offsets[start]);
              range.setEnd(flat.nodes[end], flat.offsets[end] + 1);

              if (m === current) currentRange = range; else all.push(range);
            }

            if (all.length) CSS.highlights.set(ALL, new Highlight(...all));
            if (!currentRange) return;

            CSS.highlights.set(CURRENT, new Highlight(currentRange));

            // Where the reader has to scroll to, as a fraction of this body's
            // height. This view cannot scroll itself — it is sized to its
            // content and the thread scrolls around it.
            var box = currentRange.getBoundingClientRect();
            var total = document.documentElement.scrollHeight;

            if (total > 0) {
              window.webkit.messageHandlers.\(Coordinator.findPositionMessage)
                .postMessage((box.top + window.scrollY) / total);
            }
          };
        })();
        """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let heightMessage = "plmailHeight"
        static let findPositionMessage = "plmailFindPosition"

        let inlineHandler = InlineImageHandler()
        var renderedDocument: String?
        var renderedRemoteSetting: Bool?
        var blocksRemoteContent = true
        /// Find state waiting for a document to finish loading.
        var pendingFind: ([ThreadFindMatch], Int?)?

        private let height: Binding<CGFloat>
        private let onRemoteContentBlocked: () -> Void
        private let onCurrentMatchPositioned: (CGFloat) -> Void
        /// What was last handed to the script, so a `ResizeObserver` tick or a
        /// SwiftUI re-render does not re-run the DOM walk for no reason.
        private var appliedFind: String?

        init(
            height: Binding<CGFloat>,
            onRemoteContentBlocked: @escaping () -> Void,
            onCurrentMatchPositioned: @escaping (CGFloat) -> Void
        ) {
            self.height = height
            self.onRemoteContentBlocked = onRemoteContentBlocked
            self.onCurrentMatchPositioned = onCurrentMatchPositioned
        }

        /// Hands the script the offsets to paint.
        func applyFind(matches: [ThreadFindMatch], current: Int?, to webView: WKWebView) {
            let pairs = matches.map { "[\($0.start),\($0.length)]" }.joined(separator: ",")
            let call = "window.plmailFind && window.plmailFind([\(pairs)], \(current ?? -1));"

            guard call != appliedFind else { return }

            appliedFind = call
            webView.evaluateJavaScript(call)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let (matches, current) = pendingFind else { return }

            pendingFind = nil
            // The document is new, so whatever was applied to the old one is
            // not a reason to skip this.
            appliedFind = nil
            applyFind(matches: matches, current: current, to: webView)
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let value = message.body as? NSNumber else { return }

            if message.name == Self.findPositionMessage {
                onCurrentMatchPositioned(CGFloat(value.doubleValue))
                return
            }

            let measured = CGFloat(value.doubleValue)

            // Only grow on a real change: ResizeObserver fires often, and
            // rewriting the binding every time makes SwiftUI churn.
            if abs(measured - height.wrappedValue) > 1 {
                height.wrappedValue = measured
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The initial loadHTMLString and the local scheme are the only
            // things allowed to load.
            guard let url = action.request.url else {
                return decisionHandler(.allow)
            }

            if action.navigationType == .linkActivated {
                // Never navigate in place: the message would be replaced by
                // whatever the link points at, inside a view with no
                // address bar and no way back.
                Self.open(url)
                return decisionHandler(.cancel)
            }

            if url.scheme == InlineImageHandler.scheme || url.scheme == "about" {
                return decisionHandler(.allow)
            }

            if blocksRemoteContent, url.scheme == "http" || url.scheme == "https" {
                onRemoteContentBlocked()
                return decisionHandler(.cancel)
            }

            decisionHandler(.allow)
        }

        @MainActor
        private static func open(_ url: URL) {
            guard url.scheme == "http" || url.scheme == "https" else {
                UIApplication.shared.open(url)
                return
            }

            guard
                let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive })
                    as? UIWindowScene,
                let presenter = scene.keyWindow?.rootViewController
            else { return }

            let safari = SFSafariViewController(url: url)
            presenter.topmost.present(safari, animated: true)
        }
    }
}

extension UIViewController {
    fileprivate var topmost: UIViewController {
        presentedViewController?.topmost ?? self
    }
}

#endif
