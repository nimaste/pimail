import Foundation

/// How long the undo bar stays on screen.
///
/// This is the only control in the app with a deadline, and a fixed one
/// silently excludes exactly the people who need longer: at six seconds a
/// VoiceOver user has to hear the announcement, swipe to the bar and activate
/// it before it disappears, and Switch Control scanning is slower still. The
/// action is already applied, so a missed window is a mis-swipe that cannot be
/// taken back.
///
/// Android reads `AccessibilityManager.calculateRecommendedTimeoutMillis`.
/// iOS has no equivalent call, so the same guidance is applied by hand from
/// the `UIAccessibility` signals that indicate someone is driving the screen
/// indirectly.
///
/// > Note: ``current`` is meant to be assigned to `MailActions.undoWindow`,
/// > which is a `private let` today. Until that is opened up, nothing consumes
/// > this and the window stays flat at six seconds.
public enum UndoWindow {
    /// Long enough to notice a mistake, short enough not to hover over the
    /// next thing being read. The starting point, never the answer.
    public static let base: Duration = .seconds(6)

    /// Beyond this the bar has stopped being transient and started being
    /// clutter over the mail underneath it — and a stale offer to undo an
    /// action taken half a minute ago invites undoing the wrong one.
    public static let ceiling: Duration = .seconds(30)

    /// The window for a given set of accessibility conditions.
    ///
    /// Pure, and separate from ``current`` so the policy can be tested without
    /// a device that has VoiceOver switched on.
    ///
    /// - Parameters:
    ///   - base: The window a user with no assistive technology gets.
    ///   - isUsingAssistiveTechnology: VoiceOver, Switch Control, Full
    ///     Keyboard Access or AssistiveTouch. All of them mean reaching a
    ///     control takes several deliberate steps rather than one tap.
    ///   - isAccessibilitySize: The text is at an accessibility Dynamic Type
    ///     size. Not assistive technology, but it does mean the message wraps
    ///     to more lines and takes longer to read before the decision starts.
    /// - Returns: Never shorter than `base`, never longer than ``ceiling``.
    public static func duration(
        base: Duration = base,
        isUsingAssistiveTechnology: Bool,
        isAccessibilitySize: Bool
    ) -> Duration {
        var seconds = Double(base.components.seconds)

        if isUsingAssistiveTechnology { seconds *= 3 }
        if isAccessibilitySize { seconds *= 1.5 }

        return .seconds(
            min(
                max(seconds, Double(base.components.seconds)),
                Double(ceiling.components.seconds)))
    }
}

#if os(iOS)

public import PLMailCore

import SwiftUI

/// The undo bar.
///
/// Every destructive action in this app is undoable, and this is where
/// that promise is kept. It sits at the bottom, out of the way of what is
/// being read, and it goes away by itself — an undo you have to dismiss is
/// another thing to do rather than an offer.
///
/// Glass rather than a fixed dark fill, so it belongs to the same surface
/// family as the reply bar and the compose button. Its text takes the default
/// foreground for the same reason: glass adapts to whatever scrolls beneath
/// it, and hardcoded white stops being legible the moment that is a pale
/// newsletter.
struct UndoToast: View {
    let actions: MailActions

    var body: some View {
        if let failure = actions.failure {
            // A refusal outranks an undo offer: there is nothing left to undo,
            // because the optimistic change has already been put back.
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(failure)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button(.ui("OK")) { actions.dismissFailure() }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        } else if let pending = actions.pending {
            HStack(spacing: 12) {
                Text(pending.message)
                    .font(.subheadline)

                Spacer(minLength: 8)

                Button(.ui("Undo")) {
                    Task { await actions.undo() }
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            // Clear of the home indicator, per the safe-area rule.
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(.ui("\(pending.message). Double tap Undo to reverse.")))
            // Combining the children makes the button unreachable as its own
            // element, so the one thing this bar is for gets a named action.
            // Without it, undo is only available by guessing that activating
            // the whole bar presses the button inside it.
            .accessibilityAction(named: Text(.ui("Undo"))) {
                Task { await actions.undo() }
            }
        }
    }
}

/// The undo bar's curve, taken from the environment instead of written twice.
///
/// A `ViewModifier` because ``SwiftUI/View/undoOverlay(_:)`` is a free function
/// with no environment of its own, and Reduce Motion could therefore not reach
/// the one animation in the app that slides a bar up over the list a thumb is
/// resting on.
///
/// The animations stay **outside** ``UndoToast``. What they drive is its
/// transition on insertion and removal; applied within its body the contents
/// would animate while the bar itself appeared instantly.
private struct UndoMotion: ViewModifier {
    @Environment(\.standardAnimation) private var standardAnimation

    let actions: MailActions

    func body(content: Content) -> some View {
        content
            .animation(standardAnimation, value: actions.pending?.id)
            .animation(standardAnimation, value: actions.failure)
    }
}

extension View {
    /// Puts the undo bar over a list.
    func undoOverlay(_ actions: MailActions) -> some View {
        overlay(alignment: .bottom) {
            UndoToast(actions: actions)
                .modifier(UndoMotion(actions: actions))
        }
    }
}

#endif

#if os(iOS)

import UIKit

extension UndoWindow {
    /// The window right now, read from the live accessibility settings.
    ///
    /// Read at the moment an action is taken rather than cached: these are
    /// settings a person can change from Control Centre mid-session, and a
    /// value captured at launch would be wrong for the rest of it.
    @MainActor
    public static func current(isAccessibilitySize: Bool = false) -> Duration {
        duration(
            isUsingAssistiveTechnology: UIAccessibility.isVoiceOverRunning
                || UIAccessibility.isSwitchControlRunning
                || UIAccessibility.isAssistiveTouchRunning,
            isAccessibilitySize: isAccessibilitySize
        )
    }
}

#endif
