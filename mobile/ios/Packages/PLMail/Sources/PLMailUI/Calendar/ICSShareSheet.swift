#if os(iOS)

import SwiftUI
import UIKit

/// One `.ics`, on its way to the share sheet.
///
/// A value rather than a URL so that presentation is driven by
/// `sheet(item:)` — a `Bool` plus a separately-held file is two pieces of state
/// that can disagree, and the way they disagree is a share sheet offering the
/// previous event.
struct ICSDocument: Identifiable, Equatable {
    let id = UUID()
    /// What the recipient sees. Derived from the title, because
    /// `10867_20260803T080000Z.ics` tells them nothing.
    let name: String
    let contents: String
}

/// `UIActivityViewController`, for a file the app generated itself.
///
/// **A temporary file rather than a `String` or `Data`.** Mail, Messages and
/// Files all decide what an item *is* from its path extension: handed a string,
/// they paste iCalendar source into the body of a message; handed a
/// `.ics` file, they attach it and the receiving calendar offers to add the
/// event. The whole value of this feature is in the extension.
///
/// The file goes in the temporary directory, which the system reclaims. Nothing
/// here is irreplaceable — it is regenerated from the cache on the next share —
/// so it has no business in Application Support beside the outbox.
struct ICSShareSheet: UIViewControllerRepresentable {
    let document: ICSDocument

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items(), applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    /// The file if it could be written, and the text if it could not.
    ///
    /// A failed write must not produce an empty share sheet: the contents are
    /// still perfectly good iCalendar and a person can paste them somewhere
    /// useful, which is a smaller failure than a sheet that opens with nothing
    /// in it and no explanation.
    private func items() -> [Any] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(document.name)

        do {
            try document.contents.write(to: url, atomically: true, encoding: .utf8)

            return [url]
        } catch {
            return [document.contents]
        }
    }
}

#endif
