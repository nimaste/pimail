import Testing

@testable import PLMailUI

/// The undo bar is the only control in the app with a deadline. A flat six
/// seconds excludes precisely the people who need longer: hearing the
/// announcement, finding the bar and activating it takes a VoiceOver user
/// several deliberate steps, and Switch Control scanning is slower still. The
/// action has already been applied by then, so a missed window is a mis-swipe
/// nobody can take back.
@Suite("Undo window")
struct UndoWindowTests {
    @Test("without assistive technology the window is the plain six seconds")
    func plainWindow() {
        let window = UndoWindow.duration(
            isUsingAssistiveTechnology: false, isAccessibilitySize: false)

        #expect(window == .seconds(6))
    }

    @Test("VoiceOver or Switch Control buys enough time to reach the button")
    func assistiveTechnologyExtends() {
        let window = UndoWindow.duration(
            isUsingAssistiveTechnology: true, isAccessibilitySize: false)

        #expect(window == .seconds(18))
    }

    @Test("an accessibility text size extends the window on its own")
    func accessibilitySizeExtends() {
        let window = UndoWindow.duration(
            isUsingAssistiveTechnology: false, isAccessibilitySize: true)

        #expect(window == .seconds(9))
    }

    @Test("the window never grows past the point where it is just clutter")
    func cappedAtTheCeiling() {
        let window = UndoWindow.duration(
            base: .seconds(20), isUsingAssistiveTechnology: true, isAccessibilitySize: true)

        #expect(window == UndoWindow.ceiling)
    }

    @Test("no combination of settings ever shortens the window")
    func neverShorterThanTheBase() {
        for assistive in [true, false] {
            for accessibilitySize in [true, false] {
                let window = UndoWindow.duration(
                    isUsingAssistiveTechnology: assistive,
                    isAccessibilitySize: accessibilitySize)

                #expect(window >= UndoWindow.base)
            }
        }
    }
}
