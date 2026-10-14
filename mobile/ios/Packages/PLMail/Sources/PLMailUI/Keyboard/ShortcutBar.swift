#if os(iOS)

import SwiftUI

/// A control that exists only so a key press has somewhere to land.
///
/// `.keyboardShortcut` is a modifier on a *button*, not a global registration,
/// so a shortcut with no visible control cannot exist. `MailView` already
/// solved this once for ⌘N by hiding a `Button` in a `.background`; this is
/// that trick named, so the next nine do not each reinvent it slightly
/// differently.
///
/// Hidden rather than merely transparent: a zero-opacity button still takes
/// hit tests, and an invisible tap target sitting over a mail list is worse
/// than no shortcut at all.
///
/// **Every one of these needs a visible equivalent elsewhere.** A shortcut is
/// an accelerator, never the only route — the actions bound here are all also
/// in a toolbar, a context menu or the sidebar.
struct HiddenShortcut: View {
    let title: LocalizedStringResource
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .hidden()
    }
}

extension View {
    /// Hangs a set of keyboard shortcuts off this view without changing it.
    ///
    /// In a `.background` rather than an `.overlay` so nothing can end up on
    /// top of the content, and sized to nothing so the layout is untouched
    /// even if a future SwiftUI stops collapsing hidden views.
    func shortcuts(@ViewBuilder _ content: () -> some View) -> some View {
        background {
            content()
                .frame(width: 0, height: 0)
        }
    }

    /// Gives a visible control a second, ⌘-modified binding.
    ///
    /// The two-bindings-one-action pattern the compose button established: a
    /// visible control takes the bare letter someone arriving from Gmail will
    /// press, and a hidden twin takes the ⌘ form — which is both what the rest
    /// of the platform expects and the only one that appears in the shortcut
    /// overlay when Command is held. Generalised so the pair stays a pair; two
    /// separate call sites drift into two code paths.
    func commandTwin(
        _ title: LocalizedStringResource,
        _ key: KeyEquivalent,
        modifiers: EventModifiers = .command,
        action: @escaping () -> Void
    ) -> some View {
        shortcuts {
            HiddenShortcut(title: title, key: key, modifiers: modifiers, action: action)
        }
    }
}

#endif
