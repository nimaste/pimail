#if os(iOS)

public import PLMailCore

import JMAPKit
import SwiftUI

/// What the user picked, in this app's vocabulary.
///
/// **A typealias, not a second enum.** This started as three cases — system,
/// light, dark — because every token in the app was stated as a light value
/// and a dark one and nothing else, so light/dark/system was the whole of what
/// the theme could honour. The token layer now resolves a real palette per
/// theme, and the server has a vocabulary of its own, so the choice and the
/// palette have to be the same value: two enums with the same six cases is the
/// parallel set that guarantees one of them is eventually missing a case the
/// other has.
public typealias AppearanceChoice = ThemeChoice

extension ThemeChoice: Identifiable {
    public var id: String { rawValue }
}

extension ThemeChoice {
    /// The three original cases still come first and in their original order,
    /// so an existing user's picker does not rearrange itself under them.
    var title: LocalizedStringResource {
        switch self {
        case .system: .ui("Match the system")
        case .light: .ui("Light")
        case .dark: .ui("Dark")
        case .nord: .ui("Nord")
        case .dusk: .ui("Dusk")
        case .solar: .ui("Solar")
        }
    }

    var symbol: String {
        switch self {
        case .system: "iphone"
        case .light: "sun.max"
        case .dark: "moon"
        case .nord: "snowflake"
        case .dusk: "moon.haze"
        case .solar: "sun.horizon"
        }
    }
}

/// Which appearance the user picked, and the palette the app is wearing.
///
/// In `UserDefaults` for the same reason the swipe edges are: the store's
/// standing rule is that everything in it may be deleted on a migration
/// failure, and a repaint on next launch is a worse first frame than a cached
/// theme is a risk.
///
/// **The server wins where it has an opinion, and that is the point.** A user
/// with three accounts has one theme, chosen once and honoured everywhere they
/// read plMail. What is cached here is the *last known* answer, so the first
/// frame after a cold launch is the right colour rather than the system
/// default flashing before `Appearance/get` lands. An instance without the
/// appearance extension never sets one, and the local pick stands alone —
/// which is a supported instance, not a degraded one.
///
/// One shared instance, because the thing that reads it is the app's root view
/// and the thing that writes it is a settings screen several levels down. A
/// value passed through the tree would have to be threaded past every view in
/// between, none of which cares.
@MainActor
@Observable
public final class AppearancePreference {
    public static let shared = AppearancePreference()

    /// Namespaced and defined once, so a second spelling cannot quietly become
    /// a preference that saves and never loads.
    private static let key = "de.plmail.appearance"

    /// The raw server theme, cached separately from ``choice`` so a value this
    /// build cannot draw survives an upgrade that can. Without it, a user on
    /// `ocean` who launches an older build has `system` cached and the newer
    /// build has nothing to restore.
    private static let wireKey = "de.plmail.appearance.wire"

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    public var choice: AppearanceChoice {
        didSet {
            defaults.set(choice.rawValue, forKey: Self.key)
            theme.choice = choice
        }
    }

    /// Everything resolved: the palette, the accent, the motion level, the
    /// list knobs. What views read.
    public private(set) var theme: ResolvedTheme

    /// Whether the current theme came from the server. False means the picker
    /// is a device-local choice and nothing will be written back.
    public private(set) var isServerDriven = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Following the system is the only defensible default: it is what the
        // user already told iOS they wanted, and an app that overrides that on
        // first launch is answering a question nobody asked. An unreadable
        // value falls back rather than throwing — a preference is not worth a
        // crash.
        let stored = AppearanceChoice(rawValue: defaults.string(forKey: Self.key) ?? "") ?? .system

        choice = stored

        var resolved = ResolvedTheme()
        resolved.choice = stored
        resolved.themeWireValue = defaults.string(forKey: Self.wireKey)
        theme = resolved
    }

    /// Adopts the server's answer.
    ///
    /// Cached under ``choice`` too, so the next cold launch paints the right
    /// palette on the first frame. That cache is deliberately indistinguishable
    /// from a local pick: if the server later stops offering appearance, the
    /// last thing the user actually chose is the honest fallback.
    public func adopt(_ resolved: ResolvedTheme) {
        theme = resolved
        isServerDriven = true

        if choice != resolved.choice { choice = resolved.choice }

        theme = resolved
        defaults.set(resolved.themeWireValue, forKey: Self.wireKey)
    }

    /// Puts the client back on its own palette, for a server that turned out
    /// not to offer one.
    public func standAlone() {
        isServerDriven = false
        theme.choice = choice
    }
}

/// Where the appearance is chosen.
///
/// Two sources, one screen. When the server carries the appearance extension
/// the picker writes through to it, because a user with three accounts has one
/// theme and expects the phone and the browser to agree. When it does not, the
/// same picker is a device-local preference. The footer says which, because a
/// control that silently means two different things is the thing people file
/// bugs about.
struct AppearanceView: View {
    @Bindable var preference: AppearancePreference

    /// Nil on a caller that has no server to talk to, which is what the
    /// previews and the tests use.
    var settings: AppearanceSettings?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                Picker(selection: themeBinding) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Label {
                            Text(choice.title)
                        } icon: {
                            Image(systemName: choice.symbol)
                        }
                        .tag(choice)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text(.ui("Theme"))
            } footer: {
                Text(sourceExplanation)
            }

            if let unsupported = unrepresentableTheme {
                Section {
                    LabeledContent {
                        Text(unsupported)
                    } label: {
                        Label(.ui("Set on your server"), systemImage: "globe")
                    }
                } footer: {
                    // Said rather than hidden. Somebody who set "ocean" in the
                    // browser and sees "Match the system" ticked here is
                    // looking at a bug, unless they are told the choice is
                    // intact and simply not drawn yet.
                    Text(
                        .ui(
                            "This app can't draw that theme yet, so it uses the system appearance. Your choice is left alone — it won't be overwritten."
                        ))
                }
            }

            if let settings, settings.isSupported {
                Section {
                    Toggle(isOn: avatarBinding) {
                        Label(.ui("Sender avatars"), systemImage: "person.circle")
                    }

                    Stepper(value: previewLineBinding, in: 0...2) {
                        LabeledContent {
                            Text(preference.theme.previewLines.formatted())
                        } label: {
                            Label(.ui("Preview lines"), systemImage: "text.alignleft")
                        }
                    }
                } header: {
                    Text(.ui("List"))
                } footer: {
                    if let failure = settings.saveFailure {
                        Text(message(for: failure))
                            .foregroundStyle(
                                preference.theme.palette(for: colorScheme).danger.color)
                    }
                }
            }

            Section {
                LabeledContent {
                    Circle()
                        .fill(preference.theme.palette(for: colorScheme).accent.color)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                } label: {
                    Label(.ui("Accent"), systemImage: "paintpalette")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(.ui("Accent")))
            } footer: {
                // Said here rather than left to be discovered: someone who
                // sets the app to dark and then finds a white message is
                // looking at a bug, unless they were told first.
                Text(
                    .ui(
                        "Messages are always shown on white, whichever you pick. Mail is written for a light background, and forcing it dark gives you black text on black."
                    ))
            }
        }
        .navigationTitle(Text(.ui("Appearance")))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let settings else { return }

            await settings.load()
            adoptServerAnswer()
        }
    }

    // MARK: - Bindings

    /// Writes through to the server when there is one, and to `UserDefaults`
    /// either way.
    ///
    /// The local write happens first and is not rolled back on a refusal: a
    /// theme the server declined is still the theme the user asked for on this
    /// device, and reverting the control under their finger is worse than
    /// being briefly out of step with the browser.
    private var themeBinding: Binding<AppearanceChoice> {
        Binding {
            preference.choice
        } set: { choice in
            preference.choice = choice

            guard let settings, settings.isSupported else { return }

            Task {
                await settings.save(AppearancePatch(theme: choice.wireValue))
                adoptServerAnswer()
            }
        }
    }

    private var avatarBinding: Binding<Bool> {
        Binding {
            preference.theme.showsAvatars
        } set: { value in
            guard let settings else { return }

            Task {
                await settings.save(AppearancePatch(listAvatars: value))
                adoptServerAnswer()
            }
        }
    }

    private var previewLineBinding: Binding<Int> {
        Binding {
            preference.theme.previewLines
        } set: { value in
            guard let settings else { return }

            Task {
                // Sent unclamped on purpose: the server clamps rather than
                // refusing and reports the value it stored, and adopting that
                // answer is what keeps this stepper honest. Pre-clamping here
                // would work today and drift the moment the range changes.
                await settings.save(AppearancePatch(previewLines: value))
                adoptServerAnswer()
            }
        }
    }

    // MARK: - Helpers

    /// Folds the server's answer into the preference, or leaves the client on
    /// its own palette if there was none.
    private func adoptServerAnswer() {
        guard let settings, settings.isSupported else {
            preference.standAlone()

            return
        }

        if let appearance = settings.appearance {
            preference.adopt(ResolvedTheme(appearance: appearance))
        } else if let hint = settings.hint {
            preference.adopt(ResolvedTheme(hint: hint))
        }
    }

    /// The wire value when it is one this client cannot draw, and nil when it
    /// is one it can. Comparing against the resolved choice rather than
    /// against a list of names is what keeps this correct as themes are added.
    private var unrepresentableTheme: String? {
        guard let wire = preference.theme.themeWireValue,
            wire != ThemeChoice.paperWireValue,
            ThemeChoice(rawValue: wire) == nil
        else { return nil }

        return wire
    }

    private var sourceExplanation: LocalizedStringResource {
        preference.isServerDriven
            ? .ui("Chosen on your server, so every device you read plMail on matches.")
            : .ui("Your server doesn't offer themes, so this is a choice for this device.")
    }

    private func message(for failure: AppearanceSettings.SaveFailure) -> LocalizedStringResource {
        switch failure {
        case .refused:
            .ui("Your server wouldn't accept that.")
        case .changedElsewhere:
            .ui("Your appearance changed somewhere else. These are the new settings.")
        case .unreachable:
            .ui("Couldn't reach your server, so this is saved on this device only.")
        }
    }
}

#endif
