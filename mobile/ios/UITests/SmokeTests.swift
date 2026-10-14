import XCTest

/// The path a person takes in the first thirty seconds: sign in, look at the
/// list, open something, write something.
///
/// **Why this exists.** Two real bugs shipped that every unit test, the
/// compiler and a read of the diff all missed — tapping a conversation on a
/// phone marked it read and never opened the reader, and the compose button
/// covered Forward. Both were invisible to anything that did not actually
/// press the screen. Neither would survive this test for a minute.
///
/// It needs a real server, because the failures it is looking for live in the
/// seams between the store, the sync engine and navigation, and a mocked
/// transport removes exactly those seams. Without one it skips rather than
/// fails, so `swift test` and a plain `xcodebuild test` stay green offline.
///
///     PLMAIL_TEST_SERVER=http://127.0.0.1:8001 \
///     PLMAIL_TEST_TOKEN=plmail_… \
///     xcodebuild test -scheme plMail -destination '…'
final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

    /// Generous, because the first launch against a real server pages the
    /// inbox over the network. Every wait below is for a specific element
    /// appearing, never a sleep — a fixed delay is either flaky or slow, and
    /// usually manages both.
    private let timeout: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false

        try XCTSkipIf(
            server == nil || token == nil,
            "Set PLMAIL_TEST_SERVER and PLMAIL_TEST_TOKEN to run the smoke test.")

        app = XCUIApplication()
        // A clean container every time. A test that only passes on the second
        // run, because the first one left an account behind, is worse than no
        // test.
        app.launchArguments += ["-plmail.resetForUITests", "YES"]

        // English, explicitly. Every assertion below names a button by its
        // English label, so on a German device — which is what this Mac
        // produces after `simctl erase` — the test looked for "Connect" while
        // the screen said "Verbinden". It passed for weeks only because the
        // app happened to have been launched with a language override by hand.
        //
        // Pinned rather than translated: a smoke test should fail when a
        // button disappears, not when it changes language.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]

        app.launch()
    }

    private var server: String? { ProcessInfo.processInfo.environment["PLMAIL_TEST_SERVER"] }
    private var token: String? { ProcessInfo.processInfo.environment["PLMAIL_TEST_TOKEN"] }

    // MARK: - The walk

    func testSignInReadAndCompose() throws {
        try signIn()

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(
            list.waitForExistence(timeout: timeout), "The conversation list never appeared.")

        let firstRow = list.buttons.element(boundBy: 0)
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: timeout),
            "The inbox is empty — the smoke test needs a server with mail in it.")

        let subject = firstRow.label

        firstRow.tap()

        // The regression, stated as an assertion. Before the fix, tapping a
        // row on a phone marked it read and left you on the list: the reader
        // has its own column on iPad, but a collapsed split view only pushes
        // for a `List(selection:)`, and these rows are buttons so multi-select
        // can work. Nothing else in the suite noticed.
        let replyButton = app.buttons["Reply"]
        XCTAssertTrue(
            replyButton.waitForExistence(timeout: timeout),
            "Tapping a conversation did not open it. Subject was: \(subject)")

        XCTAssertTrue(app.buttons["Forward"].exists, "Forward is missing from the reader.")

        // The other bug: the floating compose button used to sit on top of
        // Forward. Asserted as "the button is not on screen" rather than
        // "Forward is hittable" — the first version of this check used
        // `isHittable` and passed happily with the overlap restored, because
        // Forward's centre point stayed clear even while its label was
        // covered. Absence is the thing actually intended here, and unlike
        // hit-testing it is unambiguous.
        XCTAssertFalse(
            app.buttons["New message"].exists,
            "The compose button is over the reader, where it covers Forward.")

        // Back genuinely means back.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: timeout), "Back did not return to the list.")

        try compose()
    }

    /// Formatting is applied through the same path ⌘B takes, and the bar it
    /// lives on is easy to lose: it used to be on the keyboard accessory bar,
    /// where it renders nothing at all if a hardware keyboard is attached.
    func testComposerOffersFormatting() throws {
        try signIn()

        XCTAssertTrue(
            app.collectionViews.firstMatch.waitForExistence(timeout: timeout),
            "The conversation list never appeared.")

        app.buttons["New message"].tap()

        for control in ["Bold", "Italic", "Underline", "Strikethrough"] {
            XCTAssertTrue(
                app.buttons[control].waitForExistence(timeout: 5),
                "\(control) is missing from the composer.")
            XCTAssertTrue(app.buttons[control].isHittable, "\(control) cannot be pressed.")
        }

        app.buttons["Cancel"].tap()
    }

    // MARK: - Steps

    private func signIn() throws {
        let address = app.textFields.element(boundBy: 0)

        XCTAssertTrue(
            address.waitForExistence(timeout: timeout), "Onboarding never appeared.")

        address.tap()
        address.typeText(try XCTUnwrap(server))

        // Typed rather than pasted: the pasteboard is unreliable in a
        // simulator and fails silently, which would make this look like an
        // app bug.
        let secret = app.secureTextFields.element(boundBy: 0)
        let field = secret.exists ? secret : app.textFields.element(boundBy: 1)

        field.tap()
        field.typeText(try XCTUnwrap(token))

        app.buttons["Connect"].tap()

        // The server is checked before anything is saved, and the account it
        // found is shown for confirmation.
        let use = app.buttons["Use this server"]
        XCTAssertTrue(
            use.waitForExistence(timeout: timeout),
            "The server was never verified — check PLMAIL_TEST_TOKEN.")

        use.tap()
    }

    private func compose() throws {
        app.buttons["New message"].tap()

        let to = app.textFields.element(boundBy: 0)
        XCTAssertTrue(to.waitForExistence(timeout: timeout), "The composer never opened.")

        to.tap()
        to.typeText("nobody@example.invalid")

        let body = app.textViews.element(boundBy: 0)
        XCTAssertTrue(body.waitForExistence(timeout: 5), "The composer has no body field.")

        body.tap()

        // Typed at the app rather than the element. The rich `TextEditor` does
        // not report keyboard focus on its own accessibility element the way a
        // `TextField` does, so `body.typeText` fails with "neither element nor
        // any descendant has keyboard focus" even though the caret is plainly
        // in it. Typing at the app sends to whatever actually has focus.
        app.typeText("Written by the smoke test.")

        // Deliberately not sent. This runs against a live server and a test
        // that mails a stranger every time it runs is a test people turn off.
        app.buttons["Cancel"].tap()

        XCTAssertTrue(
            app.collectionViews.firstMatch.waitForExistence(timeout: timeout),
            "Dismissing the composer did not return to the list.")
    }
}
