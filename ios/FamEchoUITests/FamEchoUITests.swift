import XCTest

/// 初回の名前選択 → 送信 → 履歴 → 履歴からボタン保存 → 初期ボタンの編集・削除 までを通しで確かめる。
///
/// 名前候補は起動引数 --uitest-family で一般名（家族A・家族B）を差し込む（実際の名前はソースに置かない）。
/// 送信先は環境変数で差し込める（xcodebuild には TEST_RUNNER_ を付けて渡す。例 TEST_RUNNER_FAM_ECHO_URL）:
///   FAM_ECHO_URL / FAM_ECHO_TOKEN  テスト用 relay（偽 HA 向け）の URL とトークン。無ければビルドに埋めた送信先を使う
///   FAM_ECHO_HA_DOWN_URL           HA に届かない relay の URL（「Home Assistant が止まっている」表示用）。無ければその試験は飛ばす
/// 手元で一式を回すには ios/scripts/uitest-local.sh（偽 HA と relay を空いているポートで起動して make uitest）。
final class FamEchoUITests: XCTestCase {
    var app: XCUIApplication!
    static let family = ["家族A", "家族B"]
    private let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// url / token が nil なら環境変数（無ければビルドに埋めた値）を使う。"" を渡すと未設定として起動する
    private func launch(url: String? = nil, token: String? = nil, family: [String] = FamEchoUITests.family) {
        var args = ["--uitest-reset", "--uitest-family", family.joined(separator: ",")]
        if let url = url ?? env["FAM_ECHO_URL"] { args += ["--uitest-url", url] }
        if let token = token ?? env["FAM_ECHO_TOKEN"] { args += ["--uitest-token", token] }
        app.launchArguments = args
        app.launch()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func status() -> XCUIElement { app.descendants(matching: .any)["send-status"] }

    private func waitForStatus(containing text: String, timeout: TimeInterval = 15) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let el = app.descendants(matching: .any).matching(identifier: "send-status").matching(predicate).firstMatch
        XCTAssertTrue(el.waitForExistence(timeout: timeout), "status に「\(text)」が出ない")
    }

    func testFullFlow() throws {
        launch()
        // 1. 初回の名前選択（候補は起動引数で差し込んだ一般名）
        XCTAssertTrue(app.staticTexts["あなたは誰？"].waitForExistence(timeout: 5))
        for name in Self.family {
            XCTAssertTrue(app.buttons["name-\(name)"].exists, name)
        }
        shot("01-onboarding")
        app.buttons["name-家族A"].tap()

        // 2. メイン画面: 初期ボタン2つ
        XCTAssertTrue(app.buttons["preset-ご飯"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["preset-起床"].exists)
        shot("02-main")

        // 3. ボタンをタップで即送信
        app.buttons["preset-ご飯"].tap()
        waitForStatus(containing: "届きました")
        shot("03-main-sent")

        // 4. 入力欄: Return では送信されない（改行が入るだけ）→ 送信ボタンで送る
        let composer = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
        composer.tap()
        composer.typeText("お風呂沸いたよ")
        composer.typeText("\n")
        sleep(1)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "send-status")
            .matching(NSPredicate(format: "label CONTAINS %@", "お風呂")).firstMatch.exists,
            "Return で送信されてしまった")
        XCTAssertTrue((composer.value as? String ?? "").contains("お風呂沸いたよ"), "Return で入力が消えた")
        app.buttons["send-button"].tap()
        waitForStatus(containing: "お風呂沸いたよ")
        XCTAssertEqual(composer.value as? String ?? "", composer.placeholderValue ?? "", "送信後に入力欄が空にならない")

        // 5. 履歴（新しい順）→ 「ボタンに保存」
        app.buttons["open-history"].tap()
        XCTAssertTrue(app.staticTexts["お風呂沸いたよ"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ご飯できたよ"].exists)
        let firstText = app.cells.element(boundBy: 0).staticTexts.element(boundBy: 0).label
        XCTAssertEqual(firstText, "お風呂沸いたよ", "履歴が新しい順でない")
        shot("04-history")

        app.buttons["save-as-preset-お風呂沸いたよ"].tap()
        let label = app.textFields["editor-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        label.tap()
        label.press(forDuration: 1.0)
        if app.menuItems["すべてを選択"].waitForExistence(timeout: 2) { app.menuItems["すべてを選択"].tap() }
        else if app.menuItems["Select All"].waitForExistence(timeout: 1) { app.menuItems["Select All"].tap() }
        label.typeText(XCUIKeyboardKey.delete.rawValue)
        label.typeText("お風呂")
        app.buttons["editor-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["saved-notice"].waitForExistence(timeout: 5))

        // 6. 履歴を1件削除（スワイプ）
        app.cells.containing(.staticText, identifier: "ご飯できたよ").firstMatch.swipeLeft()
        app.buttons["削除"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["ご飯できたよ"].waitForExistence(timeout: 1))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 7. 初期ボタンの編集と削除
        XCTAssertTrue(app.buttons["preset-お風呂"].waitForExistence(timeout: 5), "履歴から保存したボタンが無い")
        app.buttons["open-settings"].tap()
        app.buttons["edit-presets"].tap()
        app.buttons["preset-row-ご飯"].tap()
        let editLabel = app.textFields["editor-label"]
        XCTAssertTrue(editLabel.waitForExistence(timeout: 5))
        editLabel.tap()
        editLabel.typeText("だよ")  // 末尾に足して「ご飯だよ」
        let editText = app.textViews["editor-text"].exists ? app.textViews["editor-text"] : app.textFields["editor-text"]
        // 欄の右下端をタップしてカーソルを末尾に置いてから足す（先頭に入るのを避ける）
        editText.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
        editText.typeText("ー")
        app.buttons["editor-save"].tap()
        XCTAssertTrue(app.buttons["preset-row-ご飯だよ"].waitForExistence(timeout: 5))

        app.buttons["preset-row-起床"].swipeLeft()
        app.buttons["削除"].firstMatch.tap()
        XCTAssertFalse(app.buttons["preset-row-起床"].waitForExistence(timeout: 1))
        shot("05-presets-edited")

        app.navigationBars.buttons.element(boundBy: 0).tap()  // 設定へ
        app.navigationBars.buttons.element(boundBy: 0).tap()  // メインへ
        XCTAssertTrue(app.buttons["preset-ご飯だよ"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["preset-お風呂"].exists)
        XCTAssertFalse(app.buttons["preset-起床"].exists)
        shot("06-main-after-edit")

        // 8. 編集後のボタンの本文で送れる
        app.buttons["preset-ご飯だよ"].tap()
        waitForStatus(containing: "ご飯できたよー")  // 編集で末尾に足した「ー」入りの本文が送られる
    }

    /// 送れなかったときの表示。起床ボタンを押して、理由が出ることを確かめる
    private func sendAndExpectError(_ text: String, shotName: String) {
        XCTAssertTrue(app.buttons["name-家族B"].waitForExistence(timeout: 5))
        app.buttons["name-家族B"].tap()
        XCTAssertTrue(app.buttons["preset-起床"].waitForExistence(timeout: 5))
        app.buttons["preset-起床"].tap()
        waitForStatus(containing: text)
        shot(shotName)
    }

    /// relay が 401（トークン違い）を返す
    func testErrorUnauthorized() throws {
        let url = env["FAM_ECHO_URL"] ?? ""
        try XCTSkipIf(url.isEmpty, "FAM_ECHO_URL（テスト用 relay）が無いので飛ばします")
        launch(url: url, token: "wrong-token-for-uitest-0000000000")
        sendAndExpectError("合言葉（トークン）が違います", shotName: "07-error-unauthorized")
    }

    /// relay が 502 ha_unreachable を返す（HA に届かない relay を別に立てておく）
    func testErrorHADown() throws {
        let url = env["FAM_ECHO_HA_DOWN_URL"] ?? ""
        try XCTSkipIf(url.isEmpty, "FAM_ECHO_HA_DOWN_URL（HA に届かない relay）が無いので飛ばします")
        launch(url: url)
        sendAndExpectError("Home Assistant が止まっているようです", shotName: "07-error-ha_down")
    }

    /// relay に届かない（誰も待っていないポート）
    func testErrorUnreachable() throws {
        launch(url: "http://127.0.0.1:9", token: "unreachable-token-for-uitest")
        sendAndExpectError("家の Mac の窓口に届きません", shotName: "07-error-unreachable")
    }

    /// 送信先・トークン・名前候補がすべて空のビルド相当。名前は自由入力だけになり、送信できない旨が出る
    func testUnconfigured() throws {
        launch(url: "", token: "", family: [])
        XCTAssertTrue(app.staticTexts["あなたは誰？"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["name-家族A"].exists, "候補が空なのに名前ボタンが出ている")
        let field = app.textFields["custom-name-field"]
        field.tap()
        field.typeText("家族A")
        app.buttons["custom-name-done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["config-missing"].waitForExistence(timeout: 5), "未設定の表示が出ない")
        XCTAssertFalse(app.buttons["send-button"].isEnabled)
        shot("08-unconfigured")
    }
}
