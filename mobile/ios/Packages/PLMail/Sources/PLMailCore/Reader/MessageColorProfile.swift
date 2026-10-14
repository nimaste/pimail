import Foundation

/// What a message's HTML says about its own colours.
///
/// Mail is not one kind of document. A reply typed into a compose box is bare
/// HTML that will take any styling you give it. A marketing newsletter is a
/// designed artefact with its own palette, its own background images and a
/// logo that means something. Rendering both the same way in dark mode is what
/// makes dark mail readers look broken — so this decides which one is in hand.
public struct MessageColorProfile: Hashable, Sendable {
    /// The message sets colours or backgrounds of its own.
    public let declaresOwnColors: Bool
    /// The message already ships dark-mode styles, so it will adapt itself if
    /// simply told the scheme is dark.
    public let supportsDarkMode: Bool
    /// The message contains imagery that inversion would turn into a negative.
    public let hasImagery: Bool

    public init(declaresOwnColors: Bool, supportsDarkMode: Bool, hasImagery: Bool) {
        self.declaresOwnColors = declaresOwnColors
        self.supportsDarkMode = supportsDarkMode
        self.hasImagery = hasImagery
    }

    /// Reads the profile off the HTML.
    ///
    /// Deliberately textual rather than a DOM walk: this runs before the
    /// document is handed to the renderer, on the main thread, for every
    /// message in a thread. Scanning for the handful of markers that matter is
    /// enough to choose a strategy, and being wrong falls back to a strategy
    /// that is merely suboptimal rather than unreadable.
    public static func profile(of html: String) -> MessageColorProfile {
        let lowered = html.lowercased()

        // A message that already handles dark mode has done the work; it needs
        // to be told the scheme, not overridden.
        let supportsDarkMode =
            lowered.contains("prefers-color-scheme")
            || lowered.contains("color-scheme")

        let colorMarkers = [
            "bgcolor=",
            "background-color",
            "background:",
            "background-image",
            "color:",
            "<style",
        ]

        let declaresOwnColors = colorMarkers.contains { lowered.contains($0) }

        let hasImagery =
            lowered.contains("<img")
            || lowered.contains("<picture")
            || lowered.contains("<svg")
            || lowered.contains("background-image")

        return MessageColorProfile(
            declaresOwnColors: declaresOwnColors,
            supportsDarkMode: supportsDarkMode,
            hasImagery: hasImagery
        )
    }
}

/// How a message body should be painted.
public enum MessageRenderStyle: Hashable, Sendable {
    /// The original, on white. What every mail client did before dark mode,
    /// and still the truest rendering of a designed message.
    case original

    /// Restyled natively: the app's dark surface and ink, applied to a message
    /// that brought no colours of its own. No inversion, so nothing can look
    /// like a negative — the best possible result, available only for plain
    /// messages.
    case darkRestyled

    /// Inverted, with imagery inverted back so photos and logos stay right.
    /// For messages with their own palette, where restyling would fight the
    /// design and lose.
    case darkInverted

    /// The message's own dark styles, simply switched on.
    case darkNative

    /// Chooses a strategy.
    ///
    /// - Parameters:
    ///   - profile: What the HTML declares about itself.
    ///   - isDark: Whether the reader is in dark appearance.
    ///   - prefersOriginal: The per-message escape hatch. Inversion gets some
    ///     messages wrong, and when it does the user needs a way to see what
    ///     was actually sent rather than being told it is fine.
    /// - Returns: The strategy to paint this message with.
    public static func choose(
        profile: MessageColorProfile,
        isDark: Bool,
        prefersOriginal: Bool
    ) -> MessageRenderStyle {
        guard isDark, prefersOriginal == false else { return .original }

        if profile.supportsDarkMode { return .darkNative }
        if profile.declaresOwnColors { return .darkInverted }

        return .darkRestyled
    }

    /// Whether the user should be offered a way back to the original.
    ///
    /// Only worth offering where the rendering actually changed something that
    /// could be wrong. A restyled plain-text-ish message has nothing to get
    /// wrong, so the control would be noise.
    public var isTransformed: Bool {
        self == .darkInverted
    }
}
