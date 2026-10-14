import XCTest

/// Temporary: drives the app to the attachment grid so a person can look at
/// it. Delete once the screenshots are taken.
final class ThumbnailLookTests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 60

    private var server: String? { ProcessInfo.processInfo.environment["PLMAIL_TEST_SERVER"] }
    private var token: String? { ProcessInfo.processInfo.environment["PLMAIL_TEST_TOKEN"] }

    override func setUpWithError() throws {
        continueAfterFailure = false

        try XCTSkipIf(server == nil || token == nil, "Needs a server.")

        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLookAtTheAttachmentGrid() throws {
        let address = app.textFields.element(boundBy: 0)

        guard address.waitForExistence(timeout: 10) else {
            try openTheGrid()
            return
        }

        address.tap()
        address.typeText(try XCTUnwrap(server))

        let secure = app.secureTextFields.element(boundBy: 0)
        let field = secure.exists ? secure : app.textFields.element(boundBy: 1)
        field.tap()
        field.typeText(try XCTUnwrap(token))

        app.buttons["Connect"].tap()

        let use = app.buttons["Use this server"]
        XCTAssertTrue(use.waitForExistence(timeout: timeout), "Server never verified.")
        use.tap()

        try openTheGrid()
    }

    private func openTheGrid() throws {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: timeout), "No list.")

        let row = list.buttons.element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "No rows.")
        shot("01-list")

        row.tap()

        let previews = app.buttons["Show previews"]
        XCTAssertTrue(previews.waitForExistence(timeout: timeout), "No grid control.")
        app.swipeUp()
        shot("02-grid-before-fetch")

        previews.tap()
        Thread.sleep(forTimeInterval: 8)
        shot("03-grid-after-fetch")

        app.swipeUp()
        shot("04-grid-after-fetch-scrolled")
    }
}
