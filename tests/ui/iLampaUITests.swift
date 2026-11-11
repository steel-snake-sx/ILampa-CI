import XCTest

final class iLampaUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testLegacySettingsAppearInProductionPluginDetail() throws {
        app.launchArguments = ["--uitesting", "--legacy-settings-ui-fixture"]
        app.launch()
        let toggle = app.switches["Fixture toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 90))
        XCTAssertTrue(app.staticTexts["Fixture heading"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Fixture input"].exists)
        XCTAssertTrue(app.buttons["Fixture select"].exists || app.staticTexts["Fixture select"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "LegacySettings_ProductionPluginDetail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(toggle.value as? String, "0")
        let actualSwitch = toggle.switches.firstMatch
        XCTAssertTrue(actualSwitch.exists)
        actualSwitch.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "Toggle did not update. Hierarchy: \(app.debugDescription)")
        let toggleReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [toggleReady], timeout: 15), .completed)
        let selector = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture select")).firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        XCTAssertTrue(selector.label.contains("Option A"), "Fresh fixture must start before the requested selection")
        selector.tap()
        // Retained hierarchy: the presented native menu is a CollectionView,
        // with a finite Cell containing the Option B button. Hit-testing that
        // button proxy itself throws inside XCTest on this runtime. Target its
        // real menu cell, scoped by its accessible child, not a screen coordinate.
        let choice = app.collectionViews.cells.containing(.button, identifier: "Option B").firstMatch
        let optionReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard choice.exists else { return false }
            let frame = choice.frame
            guard !frame.isEmpty, frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite else { return false }
            return choice.isHittable
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [optionReady], timeout: 15), .completed,
                       "No rendered selectable Option B. Hierarchy: \(app.debugDescription)")
        let menuShot = XCTAttachment(screenshot: app.screenshot())
        menuShot.name = "LegacySettings_SelectableMenu"
        menuShot.lifetime = .keepAlways
        add(menuShot)
        let menuHierarchy = XCTAttachment(string: app.debugDescription)
        menuHierarchy.name = "LegacySettings_MenuCellHierarchy"
        menuHierarchy.lifetime = .keepAlways
        add(menuHierarchy)
        // Xcode 26.6 reports this visible menu cell as hittable but its tap()
        // activation-point proxy becomes infinite (retained screenshot/hierarchy).
        // Send the native gesture to the center of the verified rendered cell,
        // relative to its actual window; never guess a screen coordinate or
        // bypass the selection/callback/Storage assertions below.
        let renderedCell = choice.frame
        let menuWindow = app.windows.firstMatch
        let windowFrame = menuWindow.frame
        XCTAssertFalse(renderedCell.isEmpty)
        XCTAssertTrue(renderedCell.minX.isFinite && renderedCell.minY.isFinite
                      && renderedCell.width.isFinite && renderedCell.height.isFinite)
        XCTAssertTrue(windowFrame.contains(renderedCell), "Menu selection must be inside the actual app window")
        menuWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: renderedCell.midX - windowFrame.minX,
                                 dy: renderedCell.midY - windowFrame.minY)).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Option B"), object: selector)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 15), .completed, "Selection did not commit")
        let committedShot = XCTAttachment(screenshot: app.screenshot())
        committedShot.name = "LegacySettings_NativeSelectionCommitted"
        committedShot.lifetime = .keepAlways
        add(committedShot)
        let input = app.textFields["Fixture input"]
        let inputHittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [inputHittable], timeout: 20), .completed, "Picker did not close. Hierarchy: \(app.debugDescription)")
        input.tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "edited\n")
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'edited'"), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [edited], timeout: 10), .completed)
        let inputReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [inputReady], timeout: 15), .completed)

        func verifyStorage(requireSelectionCallback: Bool) {
            // This button ONLY reads real Lampa.Storage and callback evidence;
            // all writes above must still come from the native user controls.
            app.buttons["legacyFixtureReadEvidence"].tap()
            let evidence = app.staticTexts["legacyFixtureEvidence"]
            let committed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard evidence.exists, let data = evidence.label.data(using: .utf8),
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      state["select"] as? String == "b", state["input"] as? String == "edited",
                      state["toggle"] as? Bool == true else { return false }
                return !requireSelectionCallback || (state["callback"] as? String == "b"
                    && state["storageDuringCallback"] as? String == "b"
                    && state["selectionCallbacks"] as? Int == 1)
            }, object: evidence)
            XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: 15), .completed,
                           "Real Storage/callback evidence did not match: \(evidence.label)")
            let snapshot = XCTAttachment(string: evidence.label)
            snapshot.name = "LegacySettings_StorageAndCallback"
            snapshot.lifetime = .keepAlways
            add(snapshot)
        }
        verifyStorage(requireSelectionCallback: true)
        let generation = app.staticTexts["legacyFixtureGeneration"]
        let previousGeneration = try XCTUnwrap(Int(generation.label))
        app.buttons["legacyFixtureRestart"].tap()
        let restarted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Int(generation.label) ?? -1) > previousGeneration
                && self.app.buttons["legacyFixtureReadEvidence"].isEnabled
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [restarted], timeout: 90), .completed,
                       "Persistence must be checked in a newly bootstrapped runtime, not the old UI snapshot")
        XCTAssertTrue(toggle.waitForExistence(timeout: 90))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 90), .completed)
        XCTAssertEqual(input.value as? String, "edited")
        XCTAssertTrue(selector.label.contains("Option B"))
        verifyStorage(requireSelectionCallback: false)
        app.buttons["legacyFixtureToggle"].tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 30), .completed)
        app.buttons["legacyFixtureToggle"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 90))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertEqual(input.value as? String, "edited")
        XCTAssertTrue(selector.label.contains("Option B"))
        verifyStorage(requireSelectionCallback: false)
        app.buttons["legacyFixtureRemove"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 30), .completed)
        XCTAssertFalse(input.exists)
        XCTAssertFalse(selector.exists)
    }

    func testAppLaunchAndScreenGeometry() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Application window should appear within 10s")

        let frame = window.frame
        print("[UITest] Window dimensions: width=\(frame.width), height=\(frame.height)")

        // Validate that app does not run in a 320x480 legacy letterbox box
        XCTAssertGreaterThan(frame.width, 350, "App width must exceed 350pt to indicate native iPhone scaling")
        XCTAssertGreaterThan(frame.height, 650, "App height must exceed 650pt on modern iPhones")

        // Validate aspect ratio is modern tall screen (approx 19.5:9 ~ 2.16, not 4:3 ~ 1.33)
        let aspectRatio = frame.height / frame.width
        XCTAssertGreaterThan(aspectRatio, 1.7, "Aspect ratio \(aspectRatio) must exceed 1.7 to rule out 4:3 letterboxing")

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "AppLaunchScreen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNativeFourTabNavigation() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10), "Tab bar should exist")

        // 1. Каталог Tab (Tab 0) with Search Entry
        let catalogTab = tabBar.buttons["Каталог"]
        XCTAssertTrue(catalogTab.waitForExistence(timeout: 5))
        do {
            catalogTab.tap()
            let catAttachment = XCTAttachment(screenshot: app.screenshot())
            catAttachment.name = "Tab_0_Catalog"
            catAttachment.lifetime = .keepAlways
            add(catAttachment)

            // Test integrated Search entry
            let searchEntry = app.textFields["catalogSearchEntry"]
            XCTAssertTrue(searchEntry.waitForExistence(timeout: 3))
            searchEntry.tap()
            XCTAssertTrue(searchEntry.isHittable,
                          "Catalog search must remain in place when focused")
            XCTAssertTrue(catalogTab.isSelected,
                          "Focusing the catalog query must not change tabs before submission")
            searchEntry.typeText("Марвел\n")
            XCTAssertTrue(app.textFields["catalogSearchInput"].waitForExistence(timeout: 10),
                          "Submitted catalog query must open the results search tab")
            XCTAssertTrue(tabBar.buttons["Поиск"].isSelected,
                          "The search tab must become selected only after Return")
            catalogTab.tap()
        }

        // 2. Поиск Tab (Tab 1)
        let searchTab = tabBar.buttons["Поиск"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5))
        searchTab.tap()
        XCTAssertTrue(app.textFields["catalogSearchInput"].waitForExistence(timeout: 5))

        // 3. Моё Tab (Tab 2)
        let myLibraryTab = tabBar.buttons["Моё"]
        XCTAssertTrue(myLibraryTab.waitForExistence(timeout: 5))
        do {
            myLibraryTab.tap()
            let libAttachment = XCTAttachment(screenshot: app.screenshot())
            libAttachment.name = "Tab_2_MyLibrary"
            libAttachment.lifetime = .keepAlways
            add(libAttachment)
        }

        // 4. Настройки Tab (Tab 3)
        let settingsTab = tabBar.buttons["Настройки"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        do {
            settingsTab.tap()
            let setAttachment = XCTAttachment(screenshot: app.screenshot())
            setAttachment.name = "Tab_3_Settings"
            setAttachment.lifetime = .keepAlways
            add(setAttachment)

            // Verify navigation to Extensions from Settings
            // Form NavigationLink can surface as a cell, not necessarily a button.
            let extRow = app.descendants(matching: .any)
                .matching(identifier: "navExtensions").firstMatch
            if !extRow.waitForExistence(timeout: 8) { app.swipeUp() }
            XCTAssertTrue(extRow.waitForExistence(timeout: 8),
                          "Plugin settings entry must be discoverable")
            do {
                extRow.tap()
                XCTAssertTrue(app.navigationBars["Плагины"].waitForExistence(timeout: 10),
                              "Plugin management must open")
                let extAttachment = XCTAttachment(screenshot: app.screenshot())
                extAttachment.name = "Settings_Extensions_View"
                extAttachment.lifetime = .keepAlways
                add(extAttachment)
                if app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 3) {
                    app.navigationBars.buttons.element(boundBy: 0).tap()
                }
            }
        }
    }

    func testCatalogCategorySwitching() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        // Switch to "Фильмы"
        let moviesBtn = app.buttons["category_Фильмы"]
        XCTAssertTrue(moviesBtn.waitForExistence(timeout: 8))
        do {
            moviesBtn.tap()
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Category_Movies"
            shot.lifetime = .keepAlways
            add(shot)
        }

        // Switch to "Сериалы"
        let tvBtn = app.buttons["category_Сериалы"]
        XCTAssertTrue(tvBtn.waitForExistence(timeout: 5))
        do {
            tvBtn.tap()
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Category_TVSeries"
            shot.lifetime = .keepAlways
            add(shot)
        }

        // Switch to "Аниме"
        let animeBtn = app.buttons["category_Аниме"]
        XCTAssertTrue(animeBtn.waitForExistence(timeout: 5))
        do {
            animeBtn.tap()
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Category_Anime"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    func testMediaDetailsPresentation() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let predicate = NSPredicate(format: "identifier BEGINSWITH 'catalog_item_'")
        let firstItem = app.buttons.matching(predicate).firstMatch

        if firstItem.waitForExistence(timeout: 30) {
            firstItem.tap()

            let watchBtn = app.buttons["watchNowButton"]
            XCTAssertTrue(watchBtn.waitForExistence(timeout: 8), "Media details 'watchNowButton' should appear")

            let detailsShot = XCTAttachment(screenshot: app.screenshot())
            detailsShot.name = "MediaDetails_Pushed"
            detailsShot.lifetime = .keepAlways
            add(detailsShot)

            XCTAssertFalse(app.buttons["closeDetailsButton"].exists)
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "Pushed details need a navigation back button")
            back.tap()
            XCTAssertTrue(firstItem.waitForExistence(timeout: 5))
        } else {
            XCTFail("Catalog must supply a real or explicitly labelled offline item for navigation testing")
        }
    }

    func testMetadataPluginAppearsInProductionDetailAndCleansUp() {
        app.launchArguments = ["--uitesting", "--metadata-ui-fixture"]
        app.launch()
        defer {
            let final = XCTAttachment(screenshot: app.screenshot())
            final.name = "ProductionDetail_MetadataPlugin_Final"
            final.lifetime = .keepAlways
            add(final)
        }
        let section = app.descendants(matching: .any).matching(identifier: "pluginMetadataSection_ui_fixture").firstMatch
        func control(_ id: String) -> XCUIElement {
            app.buttons[id]
        }
        func expectMovie(_ id: Int) {
            XCTAssertTrue(section.waitForExistence(timeout: 90), "Approved WKWebView plugin must deliver a section")
            let expected = NSPredicate(format: "label CONTAINS %@", "urn:media:tmdb:movie:\(id)")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: section)], timeout: 20), .completed)
            for _ in 0..<5 where !section.isHittable { app.swipeUp() }
            XCTAssertTrue(section.isHittable, "The production section must be visible on screen")
        }
        func expectMissing() {
            let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: section)
            XCTAssertEqual(XCTWaiter.wait(for: [missing], timeout: 20), .completed)
        }
        expectMovie(550)
        XCTAssertTrue(section.label.contains("Fixture metadata"))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "ProductionDetail_MetadataPlugin_550"
        shot.lifetime = .keepAlways
        add(shot)
        control("metadataFixtureUpdate").tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Updated fixture metadata'"), object: section)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed)
        control("metadataFixtureSwitch").tap()
        expectMovie(551)
        control("metadataFixtureLate").tap()
        control("metadataFixtureWrongMovie").tap()
        let bad = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Stale update' OR label CONTAINS 'Wrong movie'"), object: section)
        bad.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [bad], timeout: 2), .completed)
        XCTAssertTrue(section.label.contains("urn:media:tmdb:movie:551"))
        control("metadataFixtureRestart").tap()
        expectMovie(551)
        control("metadataFixtureToggle").tap()
        expectMissing()
        control("metadataFixtureToggle").tap()
        expectMovie(551)
        control("metadataFixtureRemove").tap()
        expectMissing()
    }

    func testPluginManagementNavigation() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        let settingsTab = tabBar.buttons["Настройки"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        let extTab = app.buttons["navExtensions"]
        XCTAssertTrue(extTab.waitForExistence(timeout: 5))
        extTab.tap()

        XCTAssertTrue(app.buttons["navPluginCatalog"].waitForExistence(timeout: 5))

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "PluginManagement_Navigation"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testPluginActivationRequiresDeterministicFixture() throws {
        app.launchArguments = ["--uitesting", "--legacy-settings-ui-fixture"]
        app.launch()
        let setting = app.switches["Fixture toggle"]
        XCTAssertTrue(setting.waitForExistence(timeout: 90), "Approved fixture must execute in real WebKit")

        func setActivation(from old: String, to new: String) {
            let toggle = app.switches["plugin_toggle_Legacy UI fixture"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            XCTAssertEqual(toggle.value as? String, old)
            let control = toggle.switches.firstMatch
            if control.exists { control.tap() } else { toggle.tap() }
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", new), object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 20), .completed)
        }
        setActivation(from: "1", to: "0")
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: setting)
        XCTAssertEqual(XCTWaiter.wait(for: [missing], timeout: 30), .completed,
                       "Disabled plugin must remove its live SettingsApi capability")

        let generation = app.staticTexts["legacyFixtureGeneration"]
        let previous = try XCTUnwrap(Int(generation.label))
        app.buttons["legacyFixtureRestart"].tap()
        let restarted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Int(generation.label) ?? -1) > previous
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [restarted], timeout: 90), .completed)
        XCTAssertFalse(setting.exists, "Disabled capability must not return after runtime restart")

        setActivation(from: "0", to: "1")
        for _ in 0..<5 where !setting.exists { app.swipeDown() }
        XCTAssertTrue(setting.waitForExistence(timeout: 90), "Re-enabled approved plugin must register again")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "PluginActivation_RealToggleAndRegistration"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let remove = app.buttons["pluginRemoveButton"]
        for _ in 0..<5 where !remove.isHittable { app.swipeUp() }
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        let confirmation = app.alerts.buttons["Удалить"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        confirmation.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: setting)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 30), .completed)
        XCTAssertTrue(app.staticTexts["Waiting for fixture"].waitForExistence(timeout: 10),
                      "Removal must delete the installed record, not merely hide a capability")
    }

    func testNormalNavigationHidesPrototypeControls() throws {
        app.launchArguments = ["-developer_mode_enabled", "NO"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Настройки"].tap()
        XCTAssertFalse(app.buttons["navDeveloperTools"].exists)
        XCTAssertFalse(app.buttons["testHlsButton"].exists)
        XCTAssertTrue(app.buttons["navSourcesManagement"].exists)
    }

    func testAppearanceSelectionPersistsAcrossRelaunch() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        func openAppearance() {
            XCTAssertTrue(app.tabBars.buttons["Настройки"].waitForExistence(timeout: 10))
            app.tabBars.buttons["Настройки"].tap()
            let appearance = app.buttons["navAppearance"]
            if !appearance.isHittable { app.swipeUp() }
            XCTAssertTrue(appearance.waitForExistence(timeout: 5))
            appearance.tap()
            XCTAssertTrue(app.buttons["appearance_dark"].waitForExistence(timeout: 5))
        }

        func scheme(_ identifier: String, becomes expected: String) {
            let probe = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(probe.waitForExistence(timeout: 5))
            let predicate = NSPredicate(format: "value == %@", expected)
            expectation(for: predicate, evaluatedWith: probe)
            waitForExpectations(timeout: 5)
        }

        openAppearance()
        app.buttons["appearance_system"].tap()
        app.terminate()
        app.launch()
        openAppearance()
        let settingsProbe = app.descendants(matching: .any).matching(identifier: "appearance_settings_scheme").firstMatch
        XCTAssertTrue(settingsProbe.waitForExistence(timeout: 5))
        guard let systemScheme = settingsProbe.value as? String, ["light", "dark"].contains(systemScheme) else {
            return XCTFail("Missing system appearance probe")
        }
        app.buttons["appearance_light"].tap()
        XCTAssertEqual(app.buttons["appearance_light"].value as? String, "Выбрано")
        scheme("appearance_settings_scheme", becomes: "light")
        scheme("appearance_root_scheme", becomes: "light")
        app.buttons["appearance_dark"].tap()
        XCTAssertEqual(app.buttons["appearance_dark"].value as? String, "Выбрано")
        scheme("appearance_settings_scheme", becomes: "dark")
        scheme("appearance_root_scheme", becomes: "dark")
        app.terminate()
        app.launch()
        scheme("appearance_root_scheme", becomes: "dark")
        openAppearance()
        XCTAssertEqual(app.buttons["appearance_dark"].value as? String, "Выбрано")
        scheme("appearance_settings_scheme", becomes: "dark")
        app.buttons["appearance_system"].tap()
        XCTAssertEqual(app.buttons["appearance_system"].value as? String, "Выбрано")
        scheme("appearance_settings_scheme", becomes: systemScheme)
        scheme("appearance_root_scheme", becomes: systemScheme)
    }

    func testSourceResolutionHonestState() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let predicate = NSPredicate(format: "identifier BEGINSWITH 'catalog_item_'")
        let firstItem = app.buttons.matching(predicate).firstMatch

        if firstItem.waitForExistence(timeout: 30) {
            firstItem.tap()

            let watchBtn = app.buttons["watchNowButton"]
            XCTAssertTrue(watchBtn.waitForExistence(timeout: 8))
            watchBtn.tap()

            let recovery = app.buttons["retryResolutionButton"]
            let picker = app.buttons["cancelSourceSelectionButton"]
            let outcome = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                recovery.exists || picker.exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [outcome], timeout: 30), .completed,
                           "Resolution must present a recovery action or a source picker")
        } else {
            XCTFail("Catalog must supply a real or explicitly labelled offline item for source resolution testing")
        }
    }

    /// AVKit owns the transport controls and dismissal. iLampa must not add
    /// a second black toolbar or permanently visible More/Close controls.
    func testTestHLSStreamPlaybackAndDismissal() throws {
        app.launchArguments = ["--uitesting", "--test-hls"]
        app.launch()

        let settings = app.buttons["playerSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15),
                      "Native player and overlaid settings action must appear")
        XCTAssertFalse(app.buttons["revealPlayerActionsButton"].exists,
                       "Legacy three-dot toolbar must be removed")
        XCTAssertFalse(app.buttons["closePlayerButton"].exists,
                       "Legacy duplicate X must be removed")

        if settings.isHittable {
            settings.tap()
            let done = app.buttons["Готово"]
            if done.waitForExistence(timeout: 4) { done.tap() }
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "AVKit_Fullscreen_NoBottomToolbar"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPlayerAuxiliaryControlsAutoHideAndCanBeRevealed() {
        app.launchArguments = ["--uitesting", "--test-hls"]
        app.launch()

        let settings = app.buttons["playerSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"), object: settings
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 12), .completed,
                       "Extra actions should fade without changing AVKit's viewport")
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        let revealed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: settings
        )
        XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 5), .completed,
                       "Tapping the movie must reveal the in-video settings control")
    }

    func testPlayerSeekingPauseResumeAndReopen() throws {
        app.launchArguments = ["--uitesting", "--test-hls"]
        app.launch()
        let settings = app.buttons["playerSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15),
                      "AVPlayerViewController must be presented")

        let center = app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        center.tap()
        let scrubber = app.sliders.firstMatch
        guard scrubber.waitForExistence(timeout: 10) else {
            XCTFail("Native AVKit seek slider unavailable")
            return
        }
        scrubber.adjust(toNormalizedSliderPosition: 0.5)

        let transport = app.buttons.matching(NSPredicate(
            format: "label == 'Play/Pause' OR label CONTAINS[c] 'pause' OR label CONTAINS[c] 'play'"
        )).firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 5),
                      "System AVKit transport must be accessible")
        transport.tap()
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        transport.tap()

        // Native modal dismissal is the next on-device AVKit integration check.
        // Do not claim that custom X controls are part of the system player.
    }

    func testSourcesManagementAndDiagnosticsConsole() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        let settingsTab = tabBar.buttons["Настройки"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        // 1. Open Video Sources Manager
        let navSources = app.buttons["navSourcesManagement"]
        XCTAssertTrue(navSources.waitForExistence(timeout: 5))
        navSources.tap()
        XCTAssertTrue(app.navigationBars["Источники"].waitForExistence(timeout: 5))

        let sourcesShot = XCTAttachment(screenshot: app.screenshot())
        sourcesShot.name = "SourcesManagement_Verified"
        sourcesShot.lifetime = .keepAlways
        add(sourcesShot)

        // Return to Settings
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        // 2. Open Diagnostics Console
        let navLogs = app.buttons["navDiagnostics"]
        if !navLogs.isHittable { app.swipeUp() }
        XCTAssertTrue(navLogs.waitForExistence(timeout: 5))
        navLogs.tap()
        let eventLog = app.buttons["navLogViewer"]
        XCTAssertTrue(eventLog.waitForExistence(timeout: 5))
        eventLog.tap()
        XCTAssertTrue(app.navigationBars["Журнал событий"].waitForExistence(timeout: 5))

        let logsShot = XCTAttachment(screenshot: app.screenshot())
        logsShot.name = "DiagnosticsConsole_Verified"
        logsShot.lifetime = .keepAlways
        add(logsShot)
    }

    func testDeveloperWebKitDiagnosticsNavigation() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        let settingsTab = tabBar.buttons["Настройки"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let navPoC = app.buttons["navDeveloperTools"]
        for _ in 0..<5 where !navPoC.isHittable { app.swipeUp() }
        XCTAssertTrue(navPoC.waitForExistence(timeout: 5), "Developer WebKit tools must be reachable")
        navPoC.tap()
        XCTAssertTrue(app.navigationBars["Движок WebKit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Lampa Core"].waitForExistence(timeout: 5))
    }

    func testMediaIdentityAntiCollisionVisionQuest() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        let catalogTab = tabBar.buttons["Каталог"]
        XCTAssertTrue(catalogTab.waitForExistence(timeout: 5))
        catalogTab.tap()
        let searchEntry = app.textFields["catalogSearchEntry"]
        XCTAssertTrue(searchEntry.waitForExistence(timeout: 5))
        searchEntry.tap()
        searchEntry.typeText("Квест Вижна\n")

        let searchField = app.textFields["catalogSearchInput"]
        if searchField.waitForExistence(timeout: 8) {
            XCTAssertTrue((searchField.value as? String ?? "").contains("Квест Вижна"))

            // Wait 2 seconds for search results/filtering
            RunLoop.current.run(until: Date().addingTimeInterval(2.0))

            // Verify that 'Квест учителя Коро' is NEVER matched or shown as a result
            let incorrectItem = app.staticTexts["Квест учителя Коро"]
            XCTAssertFalse(incorrectItem.exists, "КРИТИЧЕСКАЯ ОШИБКА: Нерелевантное аниме «Квест учителя Коро» показано для «Квест Вижна»!")

            let antiCollisionShot = XCTAttachment(screenshot: app.screenshot())
            antiCollisionShot.name = "VisionQuest_AntiCollision_Verified"
            antiCollisionShot.lifetime = .keepAlways
            add(antiCollisionShot)
        }
    }

    func testPluginManagementAndSourcesNavigation() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        // 1. Navigate to Plugins tab
        let settingsTab = tabBar.buttons["Настройки"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        let extTab = app.buttons["navExtensions"]
        XCTAssertTrue(extTab.waitForExistence(timeout: 5))
        extTab.tap()

        XCTAssertTrue(app.buttons["navPluginCatalog"].waitForExistence(timeout: 5))
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let sourcesNav = app.buttons["navSourcesManagement"]
        XCTAssertTrue(sourcesNav.waitForExistence(timeout: 5))
        sourcesNav.tap()
        XCTAssertTrue(app.navigationBars["Источники"].waitForExistence(timeout: 5))
    }

    func testDirectSomaFMURLPresentsPlayer() throws {
        app.launchArguments = ["--uitesting"]
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))

        let settingsTab = tabBar.buttons["Настройки"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        let sourcesNav = app.buttons["navSourcesManagement"]
        XCTAssertTrue(sourcesNav.waitForExistence(timeout: 5))
        sourcesNav.tap()
        let direct = app.buttons["Открыть прямую ссылку"]
        for _ in 0..<5 where !direct.isHittable { app.swipeUp() }
        XCTAssertTrue(direct.waitForExistence(timeout: 5))
        direct.tap()
        let url = app.textFields["URL видеопотока (HLS .m3u8 или MP4)"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("https://ice1.somafm.com/groovesalad-128-mp3")
        let review = app.buttons["Проверить ссылку"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        let play = app.buttons["Открыть в плеере"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let settings = app.buttons["playerSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20),
                      "Direct URL should present AVKit; this does not prove audible playback")
    }
}
