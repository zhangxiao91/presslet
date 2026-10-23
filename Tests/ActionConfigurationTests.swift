import Foundation

@main
struct ActionConfigurationTestRunner {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else { fputs("FAIL line \(line): \(message)\n", stderr); exit(1) }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forcepress-config-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/actions.json")
        let defaults = ActionConfiguration.defaults
        expect(defaults.validationErrors.isEmpty, "Presets validate")
        expect(defaults.profiles.count == 3, "A small set of three profiles")
        expect(defaults.profiles.flatMap(\.actions).allSatisfy { $0.kind != .workflow }, "No invented workflow preset")
        expect(defaults.profile(for: "com.microsoft.edgemac")?.interceptForceClick == true, "Edge keeps interception")
        expect(defaults.profile(for: "com.apple.finder")?.bundleID == "com.apple.finder", "Exact profile wins")
        expect(defaults.profile(for: "com.unknown.app")?.bundleID == "*", "Other apps use global profile")
        var disabled = defaults
        disabled.profiles[1].isEnabled = false
        expect(disabled.profile(for: "com.microsoft.edgemac")?.isEnabled == false, "Disabled exact profile does not fall through")
        expect(ActionConfiguration(profiles: []).profile(for: "com.unknown.app") == nil, "Missing global is handled")

        let store = ActionConfigurationStore(url: url)
        expect(store.configuration == defaults && store.loadError == nil, "Missing file uses defaults")
        expect(store.needsSave && store.migrationError == nil, "First launch should save defaults")
        expect(!FileManager.default.fileExists(atPath: directory.path), "Initialization does not create or write files")
        try store.save(disabled)
        expect(store.configuration == disabled, "Successful save updates memory")
        expect(!store.needsSave, "Successful save clears pending save")
        let reloaded = ActionConfigurationStore(url: url)
        expect(reloaded.configuration == disabled && reloaded.loadError == nil, "Save reload round trip")
        expect(!reloaded.needsSave, "Existing valid file does not need saving")
        let serialized = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(ActionConfiguration.self, from: serialized)
        expect(decoded == disabled, "JSON round trip retains all fields")

        let legacyActionJSON = Data(#"{"id":"old-copy","title":"Copy","kind":"shortcut","value":"cmd+c","isEnabled":true}"#.utf8)
        let legacyAction = try JSONDecoder().decode(MenuAction.self, from: legacyActionJSON)
        expect(legacyAction.inputRequirement == .none, "Actions saved before input support need no context")
        expect(MenuAction(title: "Copy", kind: .shortcut, value: "cmd+c").inputRequirement == .none,
               "Existing action initializers retain their behavior")
        for requirement in ActionInputRequirement.allCases {
            let action = MenuAction(title: "Process selection", kind: .workflow,
                                    value: "My Shortcut", inputRequirement: requirement)
            let actionData = try JSONEncoder().encode(action)
            let roundTrip = try JSONDecoder().decode(MenuAction.self, from: actionData)
            expect(roundTrip == action, "JSON preserves the \(requirement.rawValue) input requirement")
            let actionObject = try JSONSerialization.jsonObject(with: actionData) as? [String: Any]
            expect(actionObject?["inputRequirement"] as? String == requirement.rawValue,
                   "Saved JSON explicitly records the input requirement")
            expect(!requirement.displayName.isEmpty, "Every input requirement has a display name")
        }
        var configuredInput = disabled
        configuredInput.profiles[0].actions[0].inputRequirement = .selectedText
        try store.save(configuredInput)
        expect(ActionConfigurationStore(url: url).configuration == configuredInput,
               "Input requirements persist through store save and reload")
        try store.save(disabled)

        let legacyObject = try JSONSerialization.jsonObject(with: serialized) as! [String: Any]
        var legacyConfiguration = legacyObject
        var legacyProfiles = legacyObject["profiles"] as! [[String: Any]]
        for profileIndex in legacyProfiles.indices {
            var legacyActions = legacyProfiles[profileIndex]["actions"] as! [[String: Any]]
            for actionIndex in legacyActions.indices { legacyActions[actionIndex].removeValue(forKey: "inputRequirement") }
            legacyProfiles[profileIndex]["actions"] = legacyActions
        }
        legacyConfiguration["profiles"] = legacyProfiles
        let legacyConfigurationData = try JSONSerialization.data(withJSONObject: legacyConfiguration)
        let decodedLegacyConfiguration = try JSONDecoder().decode(ActionConfiguration.self, from: legacyConfigurationData)
        expect(decodedLegacyConfiguration == disabled, "A complete legacy configuration loads without migration loss")
        let unknownInputJSON = Data(#"{"id":"unknown","title":"Unknown","kind":"workflow","value":"Test","isEnabled":true,"inputRequirement":"future-type"}"#.utf8)
        do {
            _ = try JSONDecoder().decode(MenuAction.self, from: unknownInputJSON)
            expect(false, "Unknown input requirements must not silently execute without input")
        } catch { expect(true, "Unknown input requirements are rejected") }

        func context(text: String? = nil, files: [URL] = [], pid: Int32 = 123,
                     reason: String? = nil) -> ActionContext {
            ActionContext(sourcePID: pid, sourceBundleID: "example.source", sourceName: "Source",
                          capturedAt: Date(timeIntervalSince1970: 100), selectedText: text,
                          fileURLs: files, unavailableReason: reason)
        }
        let noSelection = context()
        expect(noSelection.availability(for: .none).isAvailable, "Actions without input remain available")
        expect(context(pid: 0, reason: "Reading").availability(for: .none).isAvailable,
               "No-input actions do not wait for content capture")
        expect(!noSelection.availability(for: .selectedText).isAvailable, "Text actions require a selection")
        expect(!noSelection.availability(for: .selectedFiles).isAvailable, "File actions require a selection")
        expect(!noSelection.availability(for: .selectedImages).isAvailable, "Image actions require a selection")
        expect(noSelection.availability(for: .selectedText).reason != nil, "Missing selection explains unavailability")
        expect(context(text: " \n\t ").availability(for: .selectedText).isAvailable == false,
               "Whitespace-only selection is empty")
        let spacedText = "  Selected text\n"
        let selectedTextContext = context(text: spacedText)
        expect(selectedTextContext.availability(for: .selectedText).isAvailable,
               "Actual selected text enables text actions")
        expect(selectedTextContext.selectedText == spacedText, "Input text retains its original whitespace")
        expect(selectedTextContext.availability(for: .selectedText).reason == nil,
               "Available actions have no unavailable reason")
        expect(context(reason: "正在读取所选内容…").availability(for: .selectedText).reason == "正在读取所选内容…",
               "Providers can distinguish loading from an empty selection")
        expect(context(reason: "此 App 暂不支持读取选区。").availability(for: .selectedText).reason == "此 App 暂不支持读取选区。",
               "Providers can explain unsupported selection capture")
        expect(context(text: "Selected", reason: "No files").availability(for: .selectedText).isAvailable,
               "One available input type is not blocked by another missing type")
        for pid: Int32 in [0, -1] {
            expect(!context(text: "Selected", pid: pid).availability(for: .selectedText).isAvailable,
                   "Context-dependent actions require a valid source process")
        }

        let imagesDirectory = directory.appendingPathComponent("image-inputs")
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let png = imagesDirectory.appendingPathComponent("first.png")
        let jpeg = imagesDirectory.appendingPathComponent("second.JPG")
        let document = imagesDirectory.appendingPathComponent("notes.txt")
        let imageNamedDirectory = imagesDirectory.appendingPathComponent("folder.png", isDirectory: true)
        for file in [png, jpeg, document] { try Data().write(to: file) }
        try FileManager.default.createDirectory(at: imageNamedDirectory, withIntermediateDirectories: true)
        expect(context(files: [png]).availability(for: .selectedFiles).isAvailable,
               "Image files can also be used as ordinary file input")
        expect(context(files: [png, jpeg]).availability(for: .selectedImages).isAvailable,
               "A selection consisting entirely of recognized image extensions is available")
        expect(!context(files: [png, document]).availability(for: .selectedImages).isAvailable,
               "Mixed image and document selections cannot run image-only actions")
        expect(context(files: [png, document]).availability(for: .selectedFiles).isAvailable,
               "Mixed local files remain valid ordinary file input")
        expect(!context(files: [imageNamedDirectory]).availability(for: .selectedImages).isAvailable,
               "Directories with image suffixes are not images")
        expect(context(files: [imageNamedDirectory]).availability(for: .selectedFiles).isAvailable,
               "A directory is valid Finder file input")
        expect(!context(files: [imagesDirectory.appendingPathComponent("missing.png")]).availability(for: .selectedImages).isAvailable,
               "A nonexistent image path cannot be confirmed as an image file")
        let remoteImage = URL(string: "https://example.com/image.png")!
        expect(!context(files: [remoteImage]).availability(for: .selectedImages).isAvailable,
               "Remote image URLs are not selected local image files")
        expect(!context(files: [remoteImage]).availability(for: .selectedFiles).isAvailable,
               "Remote URLs are not local file input")
        expect(!context(files: [png], pid: 0).availability(for: .selectedFiles).isAvailable,
               "Selected file input also requires a valid source process")
        expect(selectedTextContext.sourcePID == 123 && selectedTextContext.sourceBundleID == "example.source"
                && selectedTextContext.sourceName == "Source"
                && selectedTextContext.capturedAt == Date(timeIntervalSince1970: 100),
               "Context retains its source identity and capture time")

        var duplicate = defaults
        duplicate.profiles.append(defaults.profiles[1])
        expect(duplicate.validationErrors.count >= 2, "Duplicate app and profile ids rejected")
        do {
            try store.save(duplicate)
            expect(false, "Invalid data should not save")
        } catch {
            expect(store.configuration == disabled, "Invalid save does not mutate memory")
            let afterInvalidSave = try Data(contentsOf: url)
            expect(afterInvalidSave == serialized, "Invalid save preserves existing file")
        }
        try Data("broken JSON".utf8).write(to: url)
        let corrupt = ActionConfigurationStore(url: url)
        expect(corrupt.configuration == defaults && corrupt.loadError != nil, "Corrupt file reports error and uses defaults")
        let preservedCorrupt = try String(contentsOf: url, encoding: .utf8)
        expect(preservedCorrupt == "broken JSON", "Corrupt file not overwritten on load")
        try corrupt.save(defaults)
        expect(corrupt.loadError == nil, "Explicit valid save repairs file")
        expect(ActionConfigurationStore(url: url).configuration == defaults, "Repaired file reloads")

        let migrationURL = directory.appendingPathComponent("presslet/actions.json")
        let legacyURL = directory.appendingPathComponent("legacy/actions.json")
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialized.write(to: legacyURL)
        let migrated = ActionConfigurationStore(url: migrationURL, legacyURL: legacyURL)
        expect(migrated.configuration == disabled, "Valid legacy configuration is loaded")
        expect(migrated.loadError == nil && migrated.migrationError == nil && migrated.needsSave,
               "Legacy import requests a save without load errors")
        expect(!FileManager.default.fileExists(atPath: migrationURL.path), "Loading legacy data does not write the destination")
        let legacyBeforeSave = try Data(contentsOf: legacyURL)
        expect(legacyBeforeSave == serialized, "Legacy original is preserved")
        try migrated.save(migrated.configuration)
        expect(!migrated.needsSave, "Saving completes migration")
        let legacyAfterSave = try Data(contentsOf: legacyURL)
        expect(legacyAfterSave == serialized, "Migration save preserves the legacy original")
        try Data("broken legacy JSON".utf8).write(to: legacyURL)
        let currentWins = ActionConfigurationStore(url: migrationURL, legacyURL: legacyURL)
        expect(currentWins.configuration == disabled && currentWins.loadError == nil, "Current configuration takes precedence")
        try FileManager.default.removeItem(at: migrationURL)
        let corruptLegacy = ActionConfigurationStore(url: migrationURL, legacyURL: legacyURL)
        expect(corruptLegacy.configuration == defaults && corruptLegacy.migrationError != nil,
               "Corrupt legacy data exposes a migration error")
        expect(corruptLegacy.loadError != nil && !corruptLegacy.needsSave,
               "Corrupt legacy data prevents automatic save of fallback defaults")
        expect(!FileManager.default.fileExists(atPath: migrationURL.path), "Corrupt legacy data creates no destination")
        let corruptLegacyOriginal = try String(contentsOf: legacyURL, encoding: .utf8)
        expect(corruptLegacyOriginal == "broken legacy JSON", "Corrupt legacy original preserved")
        try serialized.write(to: legacyURL)
        try Data("broken current JSON".utf8).write(to: migrationURL)
        let corruptCurrent = ActionConfigurationStore(url: migrationURL, legacyURL: legacyURL)
        expect(corruptCurrent.loadError != nil && corruptCurrent.migrationError == nil && !corruptCurrent.needsSave,
               "Corrupt current file does not fall back to a legacy file")
        let noLegacyURL = directory.appendingPathComponent("fresh/actions.json")
        let noLegacy = ActionConfigurationStore(url: noLegacyURL, legacyURL: directory.appendingPathComponent("missing.json"))
        expect(noLegacy.configuration == defaults && noLegacy.needsSave && noLegacy.loadError == nil,
               "Missing legacy configuration uses first launch defaults")

        var unknownVersion = defaults
        unknownVersion.schemaVersion = 2
        let unknownData = try JSONEncoder().encode(unknownVersion)
        try unknownData.write(to: url)
        let unsupported = ActionConfigurationStore(url: url)
        expect(unsupported.loadError != nil, "Unsupported schema produces a visible load error")
        let preservedUnsupported = try Data(contentsOf: url)
        expect(preservedUnsupported == unknownData, "Unsupported version preserved")

        let validShortcuts: [(String, [String])] = [
            ("cmd+c", ["cmd", "c"]), ("Command + Shift + G", ["cmd", "shift", "g"]),
            ("control+alt+enter", ["ctrl", "option", "return"]),
            ("cmd+esc", ["cmd", "escape"]), ("cmd+space", ["cmd", "space"]),
            ("option+left", ["option", "left"]), ("cmd+1", ["cmd", "1"]),
            ("cmd+f20", ["cmd", "f20"]), ("cmd+home", ["cmd", "home"]),
            ("ctrl+forwarddelete", ["ctrl", "forwarddelete"])
        ]
        for (raw, expected) in validShortcuts { expect(MenuAction.parseShortcut(raw) == expected, "Parses \(raw)") }
        for raw in ["", "c", "cmd", "cmd+", "+c", "cmd++c", "cmd+command+c", "cmd+c+shift", "shell+c", "cmd+é"] {
            expect(MenuAction.parseShortcut(raw) == nil, "Rejects \(raw)")
        }
        for value in ["https://example.com/a?q=b", "http://localhost:8080", "com.apple.calculator", "/Applications/Calculator.app"] {
            expect(ActionConfiguration.isOpenTarget(value), "Accept open target \(value)")
        }
        for value in ["javascript:alert(1)", "file:///etc/passwd", "shortcuts://run-shortcut", "ftp://example.com", "https:", "https:///", "https://user:pass@example.com", "/tmp/tool.sh", "calculator", "com.apple\n.foo"] {
            expect(!ActionConfiguration.isOpenTarget(value), "Reject open target \(value)")
        }
        var tooMany = defaults
        tooMany.profiles[0].actions = (0..<10).map { MenuAction(title: "Action \($0)", kind: .shortcut, value: "cmd+c") }
        expect(!tooMany.validationErrors.isEmpty, "No more than nine enabled actions")
        tooMany.profiles[0].actions[9].isEnabled = false
        expect(tooMany.validationErrors.isEmpty, "Disabled action does not count toward menu limit")
        tooMany.profiles[0].actions[0].title = "  "
        expect(!tooMany.validationErrors.isEmpty, "Blank title rejected")
        var workflow = defaults
        workflow.profiles[0].actions = [MenuAction(title: "My Shortcut", kind: .workflow, value: "我的快捷指令")]
        expect(workflow.validationErrors.isEmpty, "User supplied workflow names supported")
        workflow.profiles[0].actions[0].value = "\n"
        expect(!workflow.validationErrors.isEmpty, "Blank workflow name rejected")
        workflow.profiles[0].actions[0].value = "foo\0bar"
        expect(!workflow.validationErrors.isEmpty, "Nul in workflow name rejected")
        for requirement in ActionInputRequirement.allCases {
            var configured = defaults
            configured.profiles[0].actions = [MenuAction(title: "Workflow", kind: .workflow,
                                                        value: "My Shortcut", inputRequirement: requirement)]
            expect(configured.validationErrors.isEmpty, "Workflows support \(requirement.rawValue) input")
            configured.profiles[0].actions = [MenuAction(title: "Shortcut", kind: .shortcut,
                                                        value: "cmd+c", inputRequirement: requirement)]
            expect(configured.validationErrors.isEmpty, "Keyboard shortcuts may use any input as a precondition")
        }
        var openInput = defaults
        openInput.profiles[0].actions = [MenuAction(title: "Open text", kind: .open,
                                                 value: "com.apple.TextEdit", inputRequirement: .selectedText)]
        expect(!openInput.validationErrors.isEmpty, "Open actions cannot promise to consume selected text")
        for requirement in [ActionInputRequirement.selectedFiles, .selectedImages] {
            openInput.profiles[0].actions[0].inputRequirement = requirement
            for appTarget in ["com.apple.Preview", "/Applications/Preview.app"] {
                openInput.profiles[0].actions[0].value = appTarget
                expect(openInput.validationErrors.isEmpty, "App targets can open selected local files or images")
            }
            for webTarget in ["https://example.com", "http://example.com"] {
                openInput.profiles[0].actions[0].value = webTarget
                expect(!openInput.validationErrors.isEmpty, "Web targets cannot consume selected local files or images")
            }
        }
        print("PASS: \(assertions) action configuration assertions")
    }
}
