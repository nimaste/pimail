#if os(iOS)

import PLMailCore
import SwiftUI

extension MessageRenderStyle {
    /// What the document declares to CSS, so `prefers-color-scheme` inside
    /// the message resolves the way this strategy expects.
    var declaredScheme: String {
        self == .original ? "light" : "dark"
    }

    /// The colour behind the message, matched by the web view itself so a
    /// short message doesn't sit on a mismatched strip.
    var pageBackground: Color {
        self == .original ? Color.white : Color(red: 0.11, green: 0.11, blue: 0.12)
    }

    /// The strategy's stylesheet.
    var css: String {
        switch self {
        case .original: Self.originalCSS
        case .darkRestyled: Self.restyledCSS
        case .darkInverted: Self.invertedCSS
        case .darkNative: Self.nativeCSS
        }
    }

    /// What a find highlight looks like inside the message.
    ///
    /// Amber rather than the system's find yellow, because it is the palette's
    /// own warm hue — the one ``ActionTint/star`` is drawn from — and a pure
    /// yellow next to cream paper reads as a highlighter pen someone left on the
    /// page. The current match is the saturated end of the same hue: one colour
    /// family, two weights, so "this one of those" needs no legend.
    ///
    /// Painted through the CSS Custom Highlight API, which styles ranges without
    /// touching the DOM. That matters more here than it looks: wrapping matches
    /// in `<mark>` elements would edit the sender's markup, and a message whose
    /// nodes are re-parented between renders is one where `cid:` rewriting and
    /// the height observer both have the ground moved under them.
    var findHighlightCSS: String {
        """
        ::highlight(plmail-find) {
          background-color: \(findTint);
          color: \(findInk);
        }
        ::highlight(plmail-find-current) {
          background-color: \(currentFindTint);
          color: \(currentFindInk);
        }
        """
    }

    /// The inverted case is the awkward one: `invert(1) hue-rotate(180deg)` is
    /// applied to the whole document, so a colour stated here is not the colour
    /// that appears. These two are the pre-images — solve the filter's matrix
    /// backwards for the amber we want and this is what goes in. Amber turns out
    /// to be just outside the reachable gamut (the exact pre-image needs a
    /// negative blue), so clamping lands on a slightly sandier amber, which is
    /// close enough to belong to the same family as the other three.
    private var findTint: String {
        self == .original ? "#f8d67a" : (self == .darkInverted ? "#4a3000" : "#7a5c1c")
    }

    private var findInk: String {
        self == .original ? "#1c1c1e" : (self == .darkInverted ? "#141414" : "#f5f5f7")
    }

    private var currentFindTint: String {
        self == .original ? "#e0a020" : (self == .darkInverted ? "#774a00" : "#d9a93a")
    }

    private var currentFindInk: String {
        self == .original ? "#1c1c1e" : (self == .darkInverted ? "#f0f0f0" : "#1c1c1e")
    }

    /// The message as sent, on white — the truest rendering of anything
    /// designed, and what light appearance always gets.
    private static let originalCSS = """
        html, body { background: #ffffff; color: #1c1c1e; }
        a { color: #0b57d0; }
        blockquote {
          margin: 8px 0; padding-left: 12px;
          border-left: 2px solid #d1d1d6; color: #48484a;
        }
        """

    /// For messages that brought no colours of their own.
    ///
    /// Nothing is inverted, so nothing can come out looking like a
    /// negative — this is simply the message painted in the app's dark
    /// palette, and it is the best result available. It applies only where
    /// the analysis found no colours to fight with.
    ///
    /// The `!important` overrides catch the one thing that still bites: a
    /// stray `color: #000` on a signature line, which would otherwise be
    /// black on near-black.
    private static let restyledCSS = """
        html, body { background: #1c1c1e; color: #e5e5e7; }
        [style*="color"], font[color] { color: #e5e5e7 !important; }
        a, a[style*="color"] { color: #7aa7ff !important; }
        blockquote {
          margin: 8px 0; padding-left: 12px;
          border-left: 2px solid #48484a; color: #aeaeb2;
        }
        hr { border-color: #3a3a3c; }
        """

    /// For messages with a design of their own.
    ///
    /// Inverting lightness and rotating hue turns a light layout dark while
    /// keeping colour relationships roughly intact, which is the only thing
    /// that works on a message whose palette is load-bearing.
    ///
    /// The second rule is the part everyone forgets: **media is inverted
    /// back**, so photographs stay photographs and a logo keeps its brand
    /// colours. Without it every image in the message is a negative, which
    /// is exactly why blanket inversion has a bad reputation.
    ///
    /// `hue-rotate` accompanies `invert` because inverting alone also
    /// inverts hue — blues would come out orange.
    private static let invertedCSS = """
        html {
          filter: invert(1) hue-rotate(180deg);
          background: #ffffff;
        }
        img, picture, video, canvas, svg, iframe, embed, object,
        [style*="background-image"], [background] {
          filter: invert(1) hue-rotate(180deg);
        }
        """

    /// The message already has dark styles; declaring the scheme is all it
    /// needs. Touching anything else would undo work the sender did.
    private static let nativeCSS = """
        html, body { background: #1c1c1e; color: #e5e5e7; }
        """
}

#endif
