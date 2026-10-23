import Foundation

struct ActionAvailability: Equatable {
    let isAvailable: Bool
    let reason: String?

    init(isAvailable: Bool, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.reason = isAvailable ? nil : reason
    }
}

struct ActionContext {
    let sourcePID: Int32
    let sourceBundleID: String
    let sourceName: String
    let capturedAt: Date
    let selectedText: String?
    let fileURLs: [URL]
    let unavailableReason: String?

    init(sourcePID: Int32, sourceBundleID: String, sourceName: String,
         capturedAt: Date, selectedText: String? = nil, fileURLs: [URL] = [],
         unavailableReason: String? = nil) {
        self.sourcePID = sourcePID
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.capturedAt = capturedAt
        self.selectedText = selectedText
        self.fileURLs = fileURLs
        self.unavailableReason = unavailableReason
    }

    func availability(for requirement: ActionInputRequirement) -> ActionAvailability {
        guard requirement != .none else { return .init(isAvailable: true) }
        guard sourcePID > 0 else {
            return .init(isAvailable: false, reason: "无法确认内容来自哪个 App。")
        }
        switch requirement {
        case .none:
            return .init(isAvailable: true)
        case .selectedText:
            if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .init(isAvailable: true)
            }
            return .init(isAvailable: false, reason: unavailableReason ?? "请先选中文字。")
        case .selectedFiles:
            guard !fileURLs.isEmpty else {
                return .init(isAvailable: false, reason: unavailableReason ?? "请先选中文件。")
            }
            guard fileURLs.allSatisfy(\.isFileURL) else {
                return .init(isAvailable: false, reason: "所选内容不是本地文件。")
            }
            return .init(isAvailable: true)
        case .selectedImages:
            guard !fileURLs.isEmpty else {
                return .init(isAvailable: false, reason: unavailableReason ?? "请先选中图片文件。")
            }
            guard fileURLs.allSatisfy(Self.isImageFile) else {
                return .init(isAvailable: false, reason: "请只选择图片文件。")
            }
            return .init(isAvailable: true)
        }
    }

    private static func isImageFile(_ url: URL) -> Bool {
        let extensions: Set<String> = [
            "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff",
            "webp", "bmp", "ico", "avif", "svg"
        ]
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
