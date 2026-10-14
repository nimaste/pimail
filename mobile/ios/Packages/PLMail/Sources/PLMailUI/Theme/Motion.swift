import SwiftUI

/// How the app moves.
///
/// Written down because it was not: `.snappy(duration: 0.2)` appears in about
/// ten files with a `0.15` and a `0.25` mixed in, which is a thing nobody can
/// change and nobody can honour a preference through. Two preferences have to
/// reach every one of those call sites — the server's `motion` property and the
/// system's `Reduce Motion` — and **`accessibilityReduceMotion` was consulted
/// nowhere in this codebase.** One enum is how that gets fixed once instead of
/// ten times.
///
/// It is fixed now: every animation in `PLMailUI` comes from here or from one
/// of the three environment values below, and `accessibilityReduceMotion` is
/// read in exactly one place — the shell, which publishes the reconciled
/// result to everything under it.
///
/// Reduce Motion wins over the server. Somebody who set it did so because
/// movement makes them ill, and a theme is not entitled to override an
/// accessibility setting.
public enum Motion {
    /// A row settling, a disclosure opening — the default everywhere.
    public static func standard(_ level: MotionLevel, reduced: Bool) -> Animation? {
        animation(.snappy(duration: 0.2), level: level, reduced: reduced)
    }

    /// A toggle, a checkmark: short enough that a slower curve reads as lag.
    public static func fast(_ level: MotionLevel, reduced: Bool) -> Animation? {
        animation(.snappy(duration: 0.15), level: level, reduced: reduced)
    }

    /// A pane appearing, a sheet of content changing wholesale.
    public static func slow(_ level: MotionLevel, reduced: Bool) -> Animation? {
        animation(.snappy(duration: 0.25), level: level, reduced: reduced)
    }

    /// Nil means "no animation", which is what SwiftUI's `withAnimation(_:)`
    /// and `.animation(_:value:)` both want for an instant change. Returning
    /// a zero-duration animation instead would still run a transaction and
    /// still animate anything implicit inside it.
    private static func animation(
        _ base: Animation, level: MotionLevel, reduced: Bool
    )
        -> Animation?
    {
        if reduced || level == .none { return nil }

        return level == .minimal ? .linear(duration: 0.1) : base
    }
}

extension EnvironmentValues {
    /// The animation a view should use, already reconciled between the
    /// server's preference and Reduce Motion.
    ///
    /// An environment value rather than a free function so a call site cannot
    /// forget to pass one of the two inputs — which is precisely how Reduce
    /// Motion goes unhonoured in a codebase that believes it honours it.
    @Entry public var standardAnimation: Animation? = .snappy(duration: 0.2)

    /// The short curve, for a toggle or a checkmark.
    @Entry public var fastAnimation: Animation? = .snappy(duration: 0.15)

    /// The long one, for a pane appearing or a body of content changing
    /// wholesale.
    ///
    /// Three entries rather than one because the call sites already used three
    /// durations, and collapsing them here would be a redesign wearing a
    /// refactor's clothes: an expanding quoted-history block that suddenly
    /// settles at the same speed as a checkbox is a visible change nobody
    /// asked for.
    ///
    /// Each default is the literal the call sites used before they read the
    /// environment, so a view below a root that never called
    /// ``SwiftUI/View/resolvedMotion(_:reduced:)`` still animates exactly as it
    /// shipped — an unpopulated environment must look right, not frozen.
    @Entry public var slowAnimation: Animation? = .snappy(duration: 0.25)
}

#if os(iOS)

extension View {
    /// Puts the reconciled animation into the environment for everything below.
    ///
    /// Applied at the app's root, and again by `MailView` so the mail tree is
    /// covered whether or not the root remembered. Views read
    /// `\.standardAnimation`, `\.fastAnimation` or `\.slowAnimation` and never
    /// `\.accessibilityReduceMotion` directly, so there is one place the two
    /// preferences meet.
    ///
    /// All three are set together. Setting only the standard one would leave
    /// the 0.15 and 0.25 call sites animating through Reduce Motion, which is
    /// the failure this whole type exists to prevent and the harder one to
    /// notice, because most of the app would have gone still.
    public func resolvedMotion(_ level: MotionLevel, reduced: Bool) -> some View {
        environment(\.standardAnimation, Motion.standard(level, reduced: reduced))
            .environment(\.fastAnimation, Motion.fast(level, reduced: reduced))
            .environment(\.slowAnimation, Motion.slow(level, reduced: reduced))
    }
}

#endif
