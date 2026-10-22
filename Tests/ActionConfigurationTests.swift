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
        print("PASS: \(assertions) action configuration assertions")
    }
}
