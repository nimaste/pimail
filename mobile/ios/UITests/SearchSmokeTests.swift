import XCTest

/// Search, pressed rather than reasoned about.
///
/// **Why this exists.** The query machinery is unit-tested to death, but none
/// of that touches the two things most likely to be wrong here, both of which
/// are invisible to `swift test` because `PLMailUI` is `#if os(iOS)` and
/// compiles away on the host:
///
/// - `.searchSuggestions` may simply not present. It is a system overlay with
///   its own rules about focus, and a suggestion list that never appears looks
///   from the code exactly like one that does.
/// - A chip has to put its operator into the *field*. That round trip — tap a
///   chip, the text changes, the parser reads it back, a token appears — spans
///   three files and a binding, and every part of it can be right while the
///   whole is wrong.
///
/// Skips without a server, like the rest of the suite, so `swift test` and a
/// plain `xcodebuild test` stay green offline.
///
///     TEST_RUNNER_PLMAIL_TEST_SERVER=http://127.0.0.1:8001 \
///     TEST_RUNNER_PLMAIL_TEST_TOKEN=plmail_… \
///     xcodebuild test -scheme plMail -destination '…'
final class SearchSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false

        try XCTSkipIf(
            server == nil || token == nil,
            "Set PLMAIL_TEST_SERVER and PLMAIL_TEST_TOKEN to run the smoke test.")

        app = XCUIApplication()
        app.launchArguments += ["-plmail.resetForUITests", "YES"]
        // English, for the same reason the other suite pins it: every
        // assertion below names a control by its English label.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]

        app.launch()
    }

    private var server: String? { ProcessInfo.processInfo.environment["PLMAIL_TEST_SERVER"] }
    private var token: String? { ProcessInfo.processInfo.environment["PLMAIL_TEST_TOKEN"] }

    /// The operators are the reason the suggestion list exists. If it does not
    /// present, nobody ever learns they are there.
    func testTypingOffersAnOperatorAndCompletesIt() throws {
        try signIn()

        let field = try searchField()

        field.tap()
        field.typeText("unr")

        // The row is the operator token itself, with its explanation beneath.
        let suggestion = app.buttons["is:unread, Only mail you haven't read"]
        XCTAssertTrue(
            suggestion.waitForExistence(timeout: 10),
            "Typing an operator fragment offered no suggestion. On screen: "
                + app.buttons.allElementsBoundByIndex.prefix(12).map { $0.label }.joined(
                    separator: " | "))

        suggestion.tap()

        // Picking a finished operator fills the field and runs the search,
        // rather than leaving a half-typed filter behind.
        XCTAssertEqual(
            field.value as? String, "is:unread",
            "Picking a suggestion did not complete the query.")
    }

    /// The whole chip design in one assertion: tapping it changes the text,
    /// which is what makes the narrowing visible instead of hidden.
    func testAChipWritesItsOperatorIntoTheField() throws {
        try signIn()

        let field = try searchField()

        field.tap()
        // Submitted with a newline rather than by tapping the keyboard's own
        // Search key: with a hardware keyboard attached — which is what a
        // simulator run gets by default — there is no software keyboard to
        // tap, and the test fails for a reason that has nothing to do with
        // search. Submitting also dismisses the suggestion overlay, which
        // otherwise covers the chips.
        field.typeText("a\n")

        let chip = app.buttons["Unread"]
        XCTAssertTrue(
            chip.waitForExistence(timeout: timeout),
            "The filter chips never appeared over the results.")

        chip.tap()

        // The operator is in the field, where a person can see and edit it.
        let text = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(
            text.contains("is:unread"),
            "Tapping Unread did not write is:unread into the query. Field reads: \(text)")
        XCTAssertTrue(
            text.contains("a"), "Tapping a chip threw away what had been typed.")

        // And tapping it again takes it back out, rather than stacking a second
        // copy of the operator.
        chip.tap()

        let cleared = try XCTUnwrap(field.value as? String)
        XCTAssertFalse(
            cleared.contains("is:unread"),
            "Tapping Unread twice left the operator behind: \(cleared)")
    }

    // MARK: - Steps

    /// The field lives on the *sidebar*, which on a phone is the root of the
    /// stack — the app opens straight into the Inbox on top of it, so getting
    /// to the search field means going back first. Without this the test races
    /// the push and passes or fails depending on which wins.
    private func searchField() throws -> XCUIElement {
        XCTAssertTrue(
            app.collectionViews.firstMatch.waitForExistence(timeout: timeout),
            "The conversation list never appeared.")

        let back = app.buttons["BackButton"]

        if back.waitForExistence(timeout: 5) {
            back.tap()
        }

        let field = app.searchFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: timeout),
            "There is no search field. Tree:\n\(app.debugDescription)")

        return field
    }

    private func signIn() throws {
        let address = app.textFields.element(boundBy: 0)

        XCTAssertTrue(address.waitForExistence(timeout: timeout), "Onboarding never appeared.")

        address.tap()
        address.typeText(try XCTUnwrap(server))

        let secret = app.secureTextFields.element(boundBy: 0)
        let field = secret.exists ? secret : app.textFields.element(boundBy: 1)

        field.tap()
        field.typeText(try XCTUnwrap(token))

        app.buttons["Connect"].tap()

        let use = app.buttons["Use this server"]
        XCTAssertTrue(
            use.waitForExistence(timeout: timeout),
            "The server was never verified — check PLMAIL_TEST_TOKEN.")

        use.tap()
    }
}
