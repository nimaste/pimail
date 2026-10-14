#if os(iOS)

import Foundation

extension LocalizedStringResource {
    /// A string from this module's own catalogue.
    ///
    /// SwiftUI's `Text(.ui("…"))` and friends resolve a `LocalizedStringKey`
    /// against **`Bundle.main`** — the app — no matter what the package
    /// declares as its `defaultLocalization`. In a package that means the
    /// translations ship, get embedded, and are never consulted: the app
    /// bundle has no `de.lproj`, the lookup misses, and the key falls through
    /// as the English literal. It fails silently and looks exactly like a
    /// missing translation.
    ///
    /// So every localised string here goes through this, which names the
    /// bundle explicitly. `Text(.ui("Archive"))` rather than `Text(.ui("Archive"))`.
    static func ui(_ key: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
    }
}

#endif
