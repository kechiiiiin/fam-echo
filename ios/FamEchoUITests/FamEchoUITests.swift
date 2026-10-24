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
    private func launch(url: String? = nil, token: String? = nil, family: [String] = FamEchoUITests.family, fixedName: String? = nil) {
        var args = ["--uitest-reset", "--uitest-family", family.joined(separator: ",")]
        if let url = url ?? env["FAM_ECHO_URL"] { args += ["--uitest-url", url] }
        if let token = token ?? env["FAM_ECHO_TOKEN"] { args += ["--uitest-token", token] }
        if let fixedName { args += ["--uitest-fixed-name", fixedName] }
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

    private func waitForStatus(containing text: String, timeout: TimeInterval = 30) {
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
        XCTAssertTrue(app.buttons["preset-ご飯できたよ"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["preset-起きる時間だよ"].exists)
        XCTAssertTrue(app.buttons["add-preset-button"].exists)
        shot("02-main")

        // 3. ボタンをタップで即送信
        app.buttons["preset-ご飯できたよ"].tap()
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
        let saveText = app.textViews["editor-text"].exists ? app.textViews["editor-text"] : app.textFields["editor-text"]
        XCTAssertTrue(saveText.waitForExistence(timeout: 5))
        XCTAssertTrue((saveText.value as? String ?? "").contains("お風呂沸いたよ"), "履歴の文が入力欄に入っていない")
        app.buttons["editor-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["saved-notice"].waitForExistence(timeout: 5))

        // 6. 履歴を1件削除（スワイプ）
        app.cells.containing(.staticText, identifier: "ご飯できたよ").firstMatch.swipeLeft()
        app.buttons["削除"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["ご飯できたよ"].waitForExistence(timeout: 1))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 7. 初期ボタンの編集と削除
        XCTAssertTrue(app.buttons["preset-お風呂沸いたよ"].waitForExistence(timeout: 5), "履歴から保存したボタンが無い")
        app.buttons["open-settings"].tap()
        app.buttons["edit-presets"].tap()
        app.buttons["preset-row-ご飯できたよ"].tap()
        let editText = app.textViews["editor-text"].exists ? app.textViews["editor-text"] : app.textFields["editor-text"]
        XCTAssertTrue(editText.waitForExistence(timeout: 5))
        // 欄の右下端をタップしてカーソルを末尾に置いてから足す（先頭に入るのを避ける）
        editText.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
        editText.typeText("ー")
        app.buttons["editor-save"].tap()
        XCTAssertTrue(app.buttons["preset-row-ご飯できたよー"].waitForExistence(timeout: 5))

        app.buttons["preset-row-起きる時間だよ"].swipeLeft()
        app.buttons["削除"].firstMatch.tap()
        XCTAssertFalse(app.buttons["preset-row-起きる時間だよ"].waitForExistence(timeout: 1))
        shot("05-presets-edited")

        app.navigationBars.buttons.element(boundBy: 0).tap()  // 設定へ
        app.navigationBars.buttons.element(boundBy: 0).tap()  // メインへ
        XCTAssertTrue(app.buttons["preset-ご飯できたよー"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["preset-お風呂沸いたよ"].exists)
        XCTAssertFalse(app.buttons["preset-起きる時間だよ"].exists)
        shot("06-main-after-edit")

        // 8. 編集後のボタンの本文で送れる
        app.buttons["preset-ご飯できたよー"].tap()
        waitForStatus(containing: "ご飯できたよー")  // 編集で末尾に足した「ー」入りの本文が送られる
    }

    /// メイン画面でボタンを足す（＋ 追加）・長押しで編集・長押しで削除と取り消し。押しても送信されない
    func testMainScreenPresetActions() throws {
        launch()
        XCTAssertTrue(app.buttons["name-家族A"].waitForExistence(timeout: 5))
        app.buttons["name-家族A"].tap()
        XCTAssertTrue(app.buttons["add-preset-button"].waitForExistence(timeout: 5))

        // 追加: 入力欄は「読み上げる文」1つだけ。下に読み上げのプレビュー
        app.buttons["add-preset-button"].tap()
        let text = app.textViews["editor-text"].exists ? app.textViews["editor-text"] : app.textFields["editor-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["editor-label"].exists, "ボタン名の入力欄が残っている")
        XCTAssertFalse(app.buttons["editor-save"].isEnabled, "空のまま保存できてしまう")
        text.typeText("お風呂沸いたよ")
        let preview = app.descendants(matching: .any).matching(identifier: "editor-preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertTrue(preview.label.contains("家族Aから。お風呂沸いたよ"), "プレビューが出ない: \(preview.label)")
        shot("10-add-sheet")
        app.buttons["editor-save"].tap()
        let added = app.buttons["preset-お風呂沸いたよ"]
        XCTAssertTrue(added.waitForExistence(timeout: 5), "追加したボタンが無い")

        // 長押しメニュー → 編集
        added.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["編集"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["削除"].exists)
        shot("11-preset-menu")
        app.buttons["編集"].tap()
        let edit = app.textViews["editor-text"].exists ? app.textViews["editor-text"] : app.textFields["editor-text"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
        edit.typeText("ー")
        app.buttons["editor-save"].tap()
        let edited = app.buttons["preset-お風呂沸いたよー"]
        XCTAssertTrue(edited.waitForExistence(timeout: 5), "編集が反映されない")
        XCTAssertFalse(app.buttons["preset-お風呂沸いたよ"].exists)

        // 長押し → 削除 → 元に戻す
        edited.press(forDuration: 1.2)
        app.buttons["削除"].tap()
        XCTAssertFalse(app.buttons["preset-お風呂沸いたよー"].waitForExistence(timeout: 1))
        shot("12-preset-deleted-undo")
        app.buttons["undo-delete"].tap()
        XCTAssertTrue(app.buttons["preset-お風呂沸いたよー"].waitForExistence(timeout: 3), "元に戻せない")

        // ここまで一度も送っていない
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "send-status")
            .matching(NSPredicate(format: "label CONTAINS %@", "届きました")).firstMatch.exists)
    }

    /// 送れなかったときの表示。「起きる時間だよ」ボタンを押して、理由が出ることを確かめる
    private func sendAndExpectError(_ text: String, shotName: String) {
        XCTAssertTrue(app.buttons["name-家族B"].waitForExistence(timeout: 20))
        app.buttons["name-家族B"].tap()
        XCTAssertTrue(app.buttons["preset-起きる時間だよ"].waitForExistence(timeout: 20))
        app.buttons["preset-起きる時間だよ"].tap()
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

    /// 名前を焼き込んだビルド相当。名前選びが出ず、設定では名前を見られるだけで変えられない
    func testFixedName() throws {
        launch(fixedName: "  家族C ")  // 前後の空白は除かれる。候補（家族A・家族B）があっても名前選びは出ない
        XCTAssertTrue(app.buttons["preset-ご飯できたよ"].waitForExistence(timeout: 5), "名前選びを飛ばしてメイン画面に入れない")
        XCTAssertFalse(app.staticTexts["あなたは誰？"].exists, "焼き込みなのに名前選びが出ている")
        XCTAssertFalse(app.buttons["name-家族A"].exists)

        let sending = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "家族C")).firstMatch
        XCTAssertTrue(sending.waitForExistence(timeout: 5), "焼き込んだ名前で送る表示が出ない")

        app.buttons["open-settings"].tap()
        let fixed = app.descendants(matching: .any).matching(identifier: "fixed-name").firstMatch
        XCTAssertTrue(fixed.waitForExistence(timeout: 5))
        XCTAssertTrue(fixed.label.contains("家族C") || fixed.value as? String == "家族C"
                      || app.staticTexts["家族C"].exists, "設定に焼き込んだ名前が出ない: \(fixed.label)")
        XCTAssertFalse(app.buttons["change-name"].exists, "焼き込みなのに名前の変更手段が出ている")
        XCTAssertFalse(app.descendants(matching: .any)["custom-name-field"].exists)
        // 家族向けに余計な情報は出さない
        XCTAssertTrue(app.buttons["Echo につながるか確かめる"].exists)
        XCTAssertTrue(app.buttons["edit-presets"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "バージョン")).firstMatch.exists)
        for hidden in ["送信先", "トークン", "ios/Secrets.xcconfig", "この iPhone の中だけ"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", hidden)).firstMatch.exists, "\(hidden) が出ている")
        }
        shot("09-fixed-name-settings")
    }
}
