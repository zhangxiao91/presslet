import Foundation

@main
struct ActionProviderTestRunner {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("presslet-provider-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActionConfigurationStore(url: directory.appendingPathComponent("actions.json"))
        let provider = ActionProvider(store: store)
        expect(provider.store === store, "Injected store is owned directly")
        let plain = MenuAction(id: "plain", title: "复制", kind: .shortcut, value: "cmd+c")
        let input = MenuAction(id: "input", title: "处理文字", kind: .workflow, value: "处理文字", inputRequirement: .selectedText)
        let hidden = MenuAction(id: "hidden", title: "不显示", kind: .workflow, value: "不显示", isEnabled: false, inputRequirement: .selectedFiles)
        var configuration = ActionConfiguration(profiles: [
            AppProfile(id: "all", bundleID: "*", appName: "其他 App", actions: [plain]),
            AppProfile(id: "target", bundleID: "org.example.editor", appName: "Editor", interceptForceClick: true,
                       actions: [plain, input, hidden]),
            AppProfile(id: "disabled", bundleID: "org.example.disabled", appName: "Disabled", isEnabled: false,
                       interceptForceClick: true, actions: [input]),
            AppProfile(id: "empty", bundleID: "org.example.empty", appName: "Empty", interceptForceClick: true, actions: [hidden])
        ])
        try provider.save(configuration)
        expect(provider.configuration == configuration, "Saving changes the catalog")
        expect(provider.profile(for: "org.example.editor")?.id == "target", "Exact profile wins")
        expect(provider.actions(for: "org.example.editor").map(\.id) == ["plain", "input"], "Only enabled actions, in their original positions")
        expect(provider.observesSelection(bundleID: "org.example.editor"), "Input action requests observation")
        expect(provider.shouldIntercept(bundleID: "org.example.editor"), "Enabled profile can intercept")
        expect(provider.actions(for: "org.example.unknown").map(\.id) == ["plain"], "Global fallback applies")
        expect(!provider.observesSelection(bundleID: "org.example.unknown"), "Plain shortcuts need no selection")
        expect(!provider.hasActions(bundleID: "org.example.disabled"), "Disabled profile does not fall through")
        expect(!provider.shouldIntercept(bundleID: "org.example.disabled"), "Disabled profile cannot intercept")
        expect(!provider.observesSelection(bundleID: "org.example.disabled"), "Disabled profile must not read selected content")
        expect(!provider.hasActions(bundleID: "org.example.empty"), "Disabled actions do not count as actions")
        expect(!provider.shouldIntercept(bundleID: "org.example.empty"), "No enabled actions means no interception")
        expect(!provider.observesSelection(bundleID: "org.example.empty"), "Disabled input actions do not enable reading")
        expect(ActionProvider(store: ActionConfigurationStore(url: store.fileURL)).configuration == configuration,
               "Saved catalog survives a new store")
        configuration.profiles[1].interceptForceClick = false
        try provider.save(configuration)
        expect(!provider.shouldIntercept(bundleID: "org.example.editor"), "Interception switch is respected")
        let saved = provider.configuration
        configuration.profiles.append(configuration.profiles[1])
        do { try provider.save(configuration); expect(false, "Invalid save should fail") }
        catch { expect(provider.configuration == saved, "Invalid save leaves usable configuration intact") }
        print("ActionProviderTests: \(assertions) assertions passed")
    }
}
