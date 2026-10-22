import XCTest

/// Simulator tests, run in CI (scripts/simulator-test.sh): the sign-in path against the real server up to Access's
/// Google button, then the app against the stub server (StubServer/, http://127.0.0.1:8787): the empty chat, the
/// conversation list, a sent message with a streamed Markdown reply and a file card, and a photo attachment.
/// Screenshots (light and dark) are kept as attachments.
final class ShellUITests: XCTestCase {
    let stub = "http://127.0.0.1:8787"

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

    /// The real server's sign-in: the app's screen, iOS's consent, then Access's own login with its Google button.
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
        let found = sheet.buttons.matching(google).firstMatch.waitForExistence(timeout: 45)
            || sheet.links.matching(google).firstMatch.exists || app.buttons.matching(google).firstMatch.exists
        keep("03-access-login")
        XCTAssertTrue(found, "Access's login with the Google button did not open")
    }

    func test2EmptyChatAndList() {
        let app = launch()
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

    /// Delete moves a conversation to 最近刪除 (with the days left), from where it is restored.
    func test6DeleteToRecentlyDeletedAndRestore() {
        let app = launch()
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
