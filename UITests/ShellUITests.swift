import XCTest

/// Simulator tests run in CI. They need no account: they check that the shell renders a page, that the
/// configured site (behind Cloudflare Access) brings up the native sign-in screen, and that its button
/// opens the Access login in the system sign-in sheet. Screenshots are kept as test attachments.
final class ShellUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The shell shows an ordinary page full screen (example.com, not the configured site).
    func testShellLoadsAPage() {
        let app = XCUIApplication()
        app.launchArguments = ["-PWASiteURLOverride", "https://example.com/"]
        app.launch()
        let heading = app.webViews.staticTexts["Example Domain"]
        XCTAssertTrue(heading.waitForExistence(timeout: 60), "example.com did not render in the web view")
        keep("01-shell-example-page")
    }

    /// The configured site answers with Cloudflare Access's login; the app shows its own sign-in screen.
    func testSignInScreenForTheSite() {
        let app = XCUIApplication()
        app.launch()
        let button = app.buttons["signin-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 60), "the native sign-in screen did not appear")
        keep("02-sign-in-screen")

        // The button opens the Access login in the system sign-in sheet (after iOS's consent prompt).
        button.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Continue"]
        if allow.waitForExistence(timeout: 15) {
            keep("03-sign-in-consent")
            allow.tap()
        }
        let sheet = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let codeButton = sheet.buttons["Send login code"]
        let found = codeButton.waitForExistence(timeout: 45) || app.buttons["Send login code"].exists
        keep("04-access-login-sheet")
        XCTAssertTrue(found, "the Access login page did not open in the sign-in sheet")
    }
}
