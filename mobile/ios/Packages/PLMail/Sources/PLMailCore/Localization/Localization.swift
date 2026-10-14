import Foundation

extension LocalizedStringResource {
    /// A string from **PLMailCore's** catalogue, named explicitly.
    ///
    /// The shim `PLMailUI` has always had, moved down to the module the widget
    /// extension can actually reach. `Widget/PLMailWidget.swift` links
    /// `PLMailCore` and nothing else — `PLMailUI` calls `UIApplication.shared`,
    /// which is unavailable to an app extension — so every word on the home
    /// screen was a bare literal, shipped in English to a German phone with no
    /// signal that anything was wrong.
    ///
    /// Naming the bundle is the whole point. SwiftUI resolves a plain
    /// `LocalizedStringKey` against **`Bundle.main`** no matter what a package
    /// declares as its `defaultLocalization`, and for a widget `Bundle.main` is
    /// the *extension*, which has no `de.lproj` at all. The lookup misses and
    /// the key falls through as the English literal: it compiles, it runs, and
    /// it looks exactly like a deliberate untranslated term.
    ///
    /// **Not a second spelling of `PLMailUI`'s `.ui(_:)`, and not a merge of
    /// the two catalogues.** A `LocalizedStringResource` binds exactly one
    /// bundle, and `Bundle.module` is generated per module and is internal to
    /// it, so one shim physically cannot serve two `.strings` tables. Two
    /// shims, named after the module whose catalogue each reads, is what that
    /// leaves — and the alternative, hoisting 453 keys out of `PLMailUI` so a
    /// widget could reach eleven of them, would move every string in the app to
    /// a catalogue no view is near.
    public static func core(_ key: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
    }
}
