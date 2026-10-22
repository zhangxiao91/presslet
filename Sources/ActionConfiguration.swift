import Foundation

enum ActionKind: String, Codable, CaseIterable {
    case shortcut, open, workflow

    var displayName: String {
        switch self {
        case .shortcut: return "键盘快捷键"
        case .open: return "打开 App 或网址"
        case .workflow: return "运行快捷指令"
        }
    }
}

struct MenuAction: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var kind: ActionKind
    var value: String
    var isEnabled: Bool

    init(id: String = UUID().uuidString, title: String, kind: ActionKind,
         value: String, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.kind = kind
        self.value = value
        self.isEnabled = isEnabled
    }

    // Shared by validation and execution: the final element is the key.
    var shortcutComponents: [String]? {
        guard kind == .shortcut else { return nil }
        return Self.parseShortcut(value)
    }

    static func parseShortcut(_ value: String) -> [String]? {
        let raw = value.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard raw.count >= 2, raw.allSatisfy({ !$0.isEmpty }) else { return nil }
        let modifierAliases = ["cmd": "cmd", "command": "cmd", "shift": "shift",
                               "option": "option", "alt": "option", "ctrl": "ctrl", "control": "ctrl"]
        var modifiers: [String] = []
        for component in raw.dropLast() {
            guard let modifier = modifierAliases[component], !modifiers.contains(modifier) else { return nil }
            modifiers.append(modifier)
        }
        let keyAliases = ["esc": "escape", "return": "return", "enter": "return", "space": "space",
                          "tab": "tab", "escape": "escape", "delete": "delete", "backspace": "delete",
                          "left": "left", "right": "right", "up": "up", "down": "down",
                          "home": "home", "end": "end", "pageup": "pageup", "pagedown": "pagedown",
                          "forwarddelete": "forwarddelete"]
        let inputKey = raw.last!
        let key: String
        if inputKey.count == 1, inputKey.unicodeScalars.allSatisfy({
            (97...122).contains(Int($0.value)) || (48...57).contains(Int($0.value))
        }) {
            key = inputKey
        } else if let alias = keyAliases[inputKey] {
            key = alias
        } else if inputKey.hasPrefix("f"), let number = Int(inputKey.dropFirst()),
                  (1...20).contains(number), inputKey == "f\(number)" {
            key = inputKey
        } else {
            return nil
        }
        return modifiers + [key]
    }
}

struct AppProfile: Codable, Equatable, Identifiable {
    var id: String
    var bundleID: String
    var appName: String
    var isEnabled: Bool
    var interceptForceClick: Bool
    var actions: [MenuAction]

    init(id: String = UUID().uuidString, bundleID: String, appName: String,
         isEnabled: Bool = true, interceptForceClick: Bool = false, actions: [MenuAction]) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.isEnabled = isEnabled
        self.interceptForceClick = interceptForceClick
        self.actions = actions
    }
}

struct ActionConfiguration: Codable, Equatable {
    var schemaVersion: Int
    var profiles: [AppProfile]

    init(schemaVersion: Int = 1, profiles: [AppProfile]) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }

    func profile(for bundleID: String) -> AppProfile? {
        profiles.first(where: { $0.bundleID == bundleID }) ?? profiles.first(where: { $0.bundleID == "*" })
    }

    static let defaults = ActionConfiguration(profiles: [
        AppProfile(id: "default-global", bundleID: "*", appName: "其他 App", actions: [
            MenuAction(id: "global-copy", title: "复制", kind: .shortcut, value: "cmd+c"),
            MenuAction(id: "global-calculator", title: "打开计算器", kind: .open, value: "com.apple.calculator")
        ]),
        AppProfile(id: "default-edge", bundleID: "com.microsoft.edgemac", appName: "Microsoft Edge",
                   interceptForceClick: true, actions: [
            MenuAction(id: "edge-address", title: "地址栏", kind: .shortcut, value: "cmd+l"),
            MenuAction(id: "edge-reload", title: "重新载入", kind: .shortcut, value: "cmd+r"),
            MenuAction(id: "edge-new-tab", title: "新建标签页", kind: .shortcut, value: "cmd+t")
        ]),
        AppProfile(id: "default-finder", bundleID: "com.apple.finder", appName: "Finder", actions: [
            MenuAction(id: "finder-info", title: "显示简介", kind: .shortcut, value: "cmd+i"),
            MenuAction(id: "finder-go", title: "前往文件夹", kind: .shortcut, value: "cmd+shift+g")
        ])
    ])

    var validationErrors: [String] {
        var errors: [String] = []
        if schemaVersion != 1 { errors.append("配置版本不受支持，请使用当前版本重新保存。") }
        var profileIDs = Set<String>()
        var bundleIDs = Set<String>()
        for profile in profiles {
            let label = profile.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = label.isEmpty ? "未命名 App" : label
            if label.isEmpty { errors.append("请填写 App 名称。") }
            if profile.id.isEmpty || !profileIDs.insert(profile.id).inserted {
                errors.append("\(prefix)：配置编号重复或为空，请重新添加此 App。")
            }
            if profile.bundleID != "*" && !Self.isBundleID(profile.bundleID) {
                errors.append("\(prefix)：请填写有效的 App 标识，例如 com.apple.finder。")
            }
            if !bundleIDs.insert(profile.bundleID).inserted {
                errors.append("\(prefix)：同一个 App 只能配置一次。")
            }
            if profile.actions.filter({ $0.isEnabled }).count > 9 {
                errors.append("\(prefix)：最多启用 9 个动作。")
            }
            var actionIDs = Set<String>()
            for action in profile.actions {
                if action.id.isEmpty || !actionIDs.insert(action.id).inserted {
                    errors.append("\(prefix)：动作编号重复或为空，请重新添加此动作。")
                }
                let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty || title.count > 40 {
                    errors.append("\(prefix)：动作名称需为 1 至 40 个字。")
                }
                let value = action.value.trimmingCharacters(in: .whitespacesAndNewlines)
                switch action.kind {
                case .shortcut:
                    if MenuAction.parseShortcut(value) == nil {
                        errors.append("\(prefix)「\(title)」：快捷键格式有误，例如 cmd+c 或 cmd+shift+g。")
                    }
                case .open:
                    if !Self.isOpenTarget(value) {
                        errors.append("\(prefix)「\(title)」：请填写 App 标识、完整 .app 路径，或 http / https 网址。")
                    }
                case .workflow:
                    if value.isEmpty || value.contains("\n") || value.contains("\r") || value.contains("\0") {
                        errors.append("\(prefix)「\(title)」：请填写已存在的快捷指令名称。")
                    }
                }
            }
        }
        return errors
    }

    func validate() -> [String] { validationErrors }

    static func isBundleID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#,
                    options: .regularExpression) != nil
    }

    static func isOpenTarget(_ value: String) -> Bool {
        guard !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else { return false }
        if value.hasPrefix("/") { return value.lowercased().hasSuffix(".app") }
        if isBundleID(value) { return true }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return false }
        return components.url != nil
    }
}

enum ActionConfigurationError: LocalizedError {
    case invalid([String])
    var errorDescription: String? {
        switch self { case .invalid(let errors): return errors.joined(separator: "\n") }
    }
}

final class ActionConfigurationStore {
    let fileURL: URL
    private(set) var configuration: ActionConfiguration = .defaults
    private(set) var loadError: String?
    private(set) var migrationError: String?
    private(set) var needsSave = false

    init(url: URL? = nil, legacyURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = url ?? support.appendingPathComponent("dev.zxlab.Presslet", isDirectory: true)
            .appendingPathComponent("actions.json")
        let oldURL = legacyURL ?? (url == nil
            ? support.appendingPathComponent("dev.zxlab.ForcePressBlockTest", isDirectory: true)
                .appendingPathComponent("actions.json")
            : nil)
        let sourceURL: URL
        let migrating: Bool
        if FileManager.default.fileExists(atPath: fileURL.path) {
            sourceURL = fileURL
            migrating = false
        } else if let oldURL = oldURL, FileManager.default.fileExists(atPath: oldURL.path) {
            sourceURL = oldURL
            migrating = true
        } else {
            needsSave = true
            return
        }
        do {
            let loaded = try JSONDecoder().decode(ActionConfiguration.self, from: Data(contentsOf: sourceURL))
            let errors = loaded.validationErrors
            guard errors.isEmpty else { throw ActionConfigurationError.invalid(errors) }
            configuration = loaded
            needsSave = migrating
        } catch {
            if migrating {
                migrationError = "无法导入旧版配置，暂时使用预设。旧文件已保留，请检查后再保存。\n\(error.localizedDescription)"
                loadError = migrationError
            } else {
                loadError = "无法读取已保存的配置，暂时使用预设。原文件已保留。\n\(error.localizedDescription)"
            }
        }
    }

    func save(_ config: ActionConfiguration) throws {
        let errors = config.validationErrors
        guard errors.isEmpty else { throw ActionConfigurationError.invalid(errors) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        configuration = config
        loadError = nil
        migrationError = nil
        needsSave = false
    }
}
