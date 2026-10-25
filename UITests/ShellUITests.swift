import XCTest

/// Simulator tests, run in CI (scripts/simulator-test.sh): the sign-in path against the real server up to Access's
/// login, then the app against the stub server (StubServer/, http://127.0.0.1:8787): the empty chat, the
/// conversation list, a sent message with a streamed Markdown reply and a file card, and a photo attachment.
/// Screenshots (light and dark) are kept as attachments. The build's backend (TEST_RUNNER_PWA_BACKEND) picks the
/// variant: `server` (YYC AI's kind: New chat, delete and restore) or `jarvis4` (pairing, a list of sessions, one
/// conversation each, resuming a paused one).
final class ShellUITests: XCTestCase {
    let stub = "http://127.0.0.1:8787"
    let jarvis4 = ProcessInfo.processInfo.environment["PWA_BACKEND"] == "jarvis4"

    override func setUp() {
        continueAfterFailure = false
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Light screenshots in the flow tests; test5DarkMode walks the same screens in dark mode.
    private func both(_ name: String) { keep(name + (dark ? "-dark" : "-light")) }
    private var dark = false

    private func launch(stubbed: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-HK)", "-AppleLocale", "zh_HK"]
        if dark { app.launchArguments += ["-PWAColorScheme", "dark"] }
        if stubbed { app.launchArguments += ["-PWASiteURLOverride", stub, "-PWATestToken", "stub-token"] }
        app.launch()
        return app
    }

    private func button(_ app: XCUIApplication, labels: [String]) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    /// Jarvis 4: back to the session list (the app opens on it) and into the running session.
    private func openRunningSession(_ app: XCUIApplication) {
        guard jarvis4 else { return }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Release notes'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the session list did not load")
        row.tap()
        XCTAssertTrue(app.staticTexts["Decisions"].waitForExistence(timeout: 15), "the session's conversation did not load")
    }

    /// The real server's sign-in: the app's screen, iOS's consent, then Access's own login (YYC AI: its Google button;
    /// Jarvis 4's pairing: Access's login page).
    func test1SignInReachesAccessGoogleButton() {
        let app = launch(stubbed: false)
        let signIn = app.buttons["signin-button"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 30), "the sign-in screen did not appear")
        keep("01-sign-in")
        signIn.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = button(springboard, labels: ["Continue", "繼續"])
        if allow.waitForExistence(timeout: 15) {
            keep("02-sign-in-consent")
            allow.tap()
        }
        let sheet = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let google = NSPredicate(format: "label CONTAINS 'Google'")
        var found: Bool
        if jarvis4 {
            // Deyao's Access login: an emailed code (an email field) or an identity provider's button
            found = sheet.textFields.firstMatch.waitForExistence(timeout: 45) || sheet.buttons.matching(google).firstMatch.exists
                || sheet.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Cloudflare' OR label CONTAINS[c] 'email'")).firstMatch.exists
        } else {
            found = sheet.buttons.matching(google).firstMatch.waitForExistence(timeout: 45)
                || sheet.links.matching(google).firstMatch.exists || app.buttons.matching(google).firstMatch.exists
        }
        keep("03-access-login")
        XCTAssertTrue(found, "Access's login did not open")
    }

    func test2EmptyChatAndList() {
        let app = launch()
        if jarvis4 {
            // the session list first (no New chat); a paused session says so
            let paused = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Paused research'")).firstMatch
            XCTAssertTrue(paused.waitForExistence(timeout: 30), "the session list did not load")
            XCTAssertFalse(app.buttons["sidebar-new-chat"].exists, "Jarvis 4 has no New chat")
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS '最近刪除'")).firstMatch.exists)
            both("05-session-list")
            openRunningSession(app)
            XCTAssertTrue(app.textViews["composer-input"].exists || app.textFields["composer-input"].exists, "no composer")
            XCTAssertFalse(app.buttons["share-button"].exists, "Jarvis 4 has no share links")
            XCTAssertTrue(app.buttons["files-button"].exists, "no Files button")
            both("06-history")
            return
        }
        let greeting = app.staticTexts["empty-greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 30), "the empty chat did not appear")
        XCTAssertTrue(app.textViews["composer-input"].exists || app.textFields["composer-input"].exists, "no composer")
        Thread.sleep(forTimeInterval: 2)
        both("04-empty-chat")
        // the conversation list (the sidebar; on iPhone behind the back button)
        let back = app.navigationBars.buttons["BackButton"].exists ? app.navigationBars.buttons["BackButton"]
            : app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Meeting notes'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the conversation list did not load")
        both("05-conversation-list")
        row.tap()
        XCTAssertTrue(app.staticTexts["Decisions"].waitForExistence(timeout: 15), "history did not render")
        both("06-history")
    }

    func test3SendMessageStreamedMarkdownAndFileCard() {
        let app = launch()
        openRunningSession(app)
        let input = app.textViews["composer-input"].exists ? app.textViews["composer-input"] : app.textFields["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 30))
        input.tap()
        input.typeText("幫我整理第三季數字")
        app.buttons["send-button"].tap()
        XCTAssertTrue(app.otherElements["user-message"].waitForExistence(timeout: 15) || app.staticTexts["幫我整理第三季數字"].exists,
                      "the sent message did not show")
        if app.staticTexts["preparing-indicator"].waitForExistence(timeout: 5) || app.otherElements["preparing-indicator"].exists {
            keep("07-preparing")
        }
        XCTAssertTrue(app.staticTexts["第三季摘要"].waitForExistence(timeout: 40), "the Markdown reply did not render")
        XCTAssertTrue(app.staticTexts["46.1"].waitForExistence(timeout: 10), "the table did not render")
        let card = app.buttons["file-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the file card did not appear")
        // keyboard away for the screenshot
        let transcript = app.scrollViews["transcript"]
        if transcript.exists { transcript.swipeDown() } else if app.scrollViews.firstMatch.exists { app.scrollViews.firstMatch.swipeDown() }
        Thread.sleep(forTimeInterval: 2)
        both("08-reply-markdown-file-card")
        if dark { return }
        card.tap()
        Thread.sleep(forTimeInterval: 4)
        keep("09-file-quick-look")
    }

    func test4AttachPhoto() {
        let app = launch()
        openRunningSession(app)
        let attach = app.buttons["attach-button"]
        XCTAssertTrue(attach.waitForExistence(timeout: 30))
        attach.tap()
        let photos = button(app, labels: ["相片圖庫", "Photo Library"])
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        photos.tap()
        let image = app.images.matching(NSPredicate(format: "label CONTAINS[c] 'photo' OR label CONTAINS '相片' OR label CONTAINS '照片'")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 30), "the photo picker showed no photo")
        keep("10-photo-picker")
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = button(app, labels: ["Add", "加入", "新增", "完成", "Done"])
        if add.waitForExistence(timeout: 5) { add.tap() }
        XCTAssertTrue(app.otherElements["pending-attachment"].waitForExistence(timeout: 20)
                      || app.images.matching(NSPredicate(format: "identifier == 'pending-attachment'")).firstMatch.exists,
                      "the photo did not show as a removable thumbnail")
        keep("11-attachment-thumbnail")
        let input = app.textViews["composer-input"].exists ? app.textViews["composer-input"] : app.textFields["composer-input"]
        input.tap()
        input.typeText("這張相是甚麼？")
        app.buttons["send-button"].tap()
        XCTAssertTrue(app.images["圖片"].waitForExistence(timeout: 20) || app.images["Image"].exists, "the sent photo did not show in the message")
        XCTAssertTrue(app.staticTexts["第三季摘要"].waitForExistence(timeout: 40))
        Thread.sleep(forTimeInterval: 1)
        keep("12-sent-photo")
    }

    func test5DarkMode() {
        dark = true
        test2EmptyChatAndList()
        XCUIApplication().terminate()
        test3SendMessageStreamedMarkdownAndFileCard()
    }

    /// Delete moves a conversation to 最近刪除 (with the days left), from where it is restored. Jarvis 4 instead: a
    /// paused session opens on Resume, and comes back running.
    func test6DeleteToRecentlyDeletedAndRestore() {
        let app = launch()
        if jarvis4 {
            let paused = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Paused research'")).firstMatch
            XCTAssertTrue(paused.waitForExistence(timeout: 30), "the session list did not load")
            paused.tap()
            let resume = app.buttons["resume-button"]
            XCTAssertTrue(resume.waitForExistence(timeout: 15), "a paused session did not offer Resume")
            XCTAssertFalse(app.textViews["composer-input"].exists || app.textFields["composer-input"].exists, "a paused session has no composer")
            keep("13-paused-session")
            resume.tap()
            XCTAssertTrue(app.staticTexts["Decisions"].waitForExistence(timeout: 40), "the resumed session's conversation did not load")
            keep("14-resumed-session")
            return
        }
        XCTAssertTrue(app.staticTexts["empty-greeting"].waitForExistence(timeout: 30))
        let back = app.navigationBars.buttons["BackButton"].exists ? app.navigationBars.buttons["BackButton"]
            : app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS '新聞稿草稿'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.swipeLeft()
        app.buttons["刪除"].firstMatch.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "identifier == 'confirm-delete' OR label == '刪除'"))
        let sheetDelete = confirm.element(boundBy: max(0, confirm.count - 1))
        XCTAssertTrue(sheetDelete.waitForExistence(timeout: 10))
        keep("13-delete-confirm")
        sheetDelete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 15), "the deleted conversation stayed in the list")
        app.buttons.matching(NSPredicate(format: "label CONTAINS '最近刪除'")).firstMatch.tap()
        let deleted = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'deleted-row' AND label CONTAINS '新聞稿草稿'")).firstMatch
        XCTAssertTrue(deleted.waitForExistence(timeout: 15), "it is not in Recently deleted")
        XCTAssertTrue(deleted.label.contains("日後永久刪除"), "no days-left line")
        keep("14-recently-deleted")
        deleted.swipeLeft()
        app.buttons["還原"].firstMatch.tap()
        XCTAssertTrue(deleted.waitForNonExistence(timeout: 15), "restore did not take it out of Recently deleted")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the restored conversation is not back in the list")
    }
}
