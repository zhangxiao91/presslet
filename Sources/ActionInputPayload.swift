import Foundation
import Darwin

struct ActionInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ActionInputPayload {
    let inputURLs: [URL]
    let temporaryDirectory: URL?
    private let lock = NSLock()
    private var cleaned = false

    private init(inputURLs: [URL], temporaryDirectory: URL? = nil) {
        self.inputURLs = inputURLs
        self.temporaryDirectory = temporaryDirectory
    }

    static func validate(_ requirement: ActionInputRequirement, context: ActionContext?, targetPID: Int32?) throws {
        if let context {
            guard let targetPID, context.sourcePID == targetPID, targetPID > 0 else {
                throw ActionInputError(message: "所选内容来自另一个 App，请回到原来的 App 重新重按。")
            }
        }
        guard requirement != .none else { return }
        guard let context else {
            throw ActionInputError(message: "没有获取到所选内容，请先选择内容，再重新重按。")
        }
        let availability = context.availability(for: requirement)
        guard availability.isAvailable else {
            throw ActionInputError(message: availability.reason ?? "没有获取到这个动作需要的所选内容。")
        }
        if requirement == .selectedFiles || requirement == .selectedImages {
            guard context.fileURLs.allSatisfy({ $0.isFileURL && FileManager.default.isReadableFile(atPath: $0.path) }) else {
                throw ActionInputError(message: "所选文件已移动或无法读取，请重新选择后再试。")
            }
        }
    }

    static func prepare(_ requirement: ActionInputRequirement, context: ActionContext?,
                        targetPID: Int32?, temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> ActionInputPayload {
        try validate(requirement, context: context, targetPID: targetPID)
        switch requirement {
        case .none:
            return ActionInputPayload(inputURLs: [])
        case .selectedText:
            guard let text = context?.selectedText else {
                throw ActionInputError(message: "没有获取到所选文字，请重新选择后再试。")
            }
            let directory = temporaryRoot.appendingPathComponent("ForcePressInput-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("SelectedText.txt")
                try Data(text.utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return ActionInputPayload(inputURLs: [file], temporaryDirectory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw ActionInputError(message: "无法准备所选文字：\(error.localizedDescription)")
            }
        case .selectedFiles, .selectedImages:
            let urls = context?.fileURLs ?? []
            guard !urls.isEmpty, urls.allSatisfy({ $0.isFileURL && FileManager.default.isReadableFile(atPath: $0.path) }) else {
                throw ActionInputError(message: "所选文件已移动、关闭或无法读取，请重新选择后再试。")
            }
            return ActionInputPayload(inputURLs: urls)
        }
    }

    func workflowArguments(name: String) throws -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.hasPrefix("-") else {
            throw ActionInputError(message: "请填写有效的快捷指令名称，名称不能以短横线开头。")
        }
        // `shortcuts run --help` documents input-path as a variadic option.
        return ["run", trimmed] + (inputURLs.isEmpty ? [] : ["--input-path"] + inputURLs.map(\.path))
    }

    func cleanup() {
        lock.lock()
        let shouldClean = !cleaned
        cleaned = true
        lock.unlock()
        if shouldClean, let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    deinit { cleanup() }
}

final class BoundedActionOutput {
    private let lock = NSLock()
    private var bytes = Data()
    private(set) var truncated = false
    private let limit: Int

    init(limit: Int = 16_384) { self.limit = max(0, limit) }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - bytes.count)
        if data.count > remaining { truncated = true }
        bytes.append(data.prefix(remaining))
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func displayedText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !bytes.isEmpty, !bytes.contains(0) else { return nil }
        // Remove only an incomplete final UTF-8 scalar caused by the byte cap.
        var candidate = bytes
        var decoded = String(data: candidate, encoding: .utf8)
        if decoded == nil && truncated {
            for _ in 0..<3 where decoded == nil && !candidate.isEmpty {
                candidate.removeLast()
                decoded = String(data: candidate, encoding: .utf8)
            }
        }
        guard let text = decoded?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let visible = String(text.prefix(2_000))
        return visible + ((truncated || text.count > 2_000) ? "\n（结果较长，仅显示前一部分。）" : "")
    }
}

final class ActionPipeReader {
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private let output: BoundedActionOutput

    init(handle: FileHandle, output: BoundedActionOutput, group: DispatchGroup) {
        self.descriptor = handle.fileDescriptor
        self.output = output
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                              queue: DispatchQueue(label: "app.presslet.action-output.\(UUID().uuidString)", qos: .utility))
        group.enter()
        source.setEventHandler { [weak self] in self?.consume() }
        source.setCancelHandler {
            try? handle.close()
            group.leave()
        }
        source.activate()
    }

    private func consume() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Return regularly so cancellation can close an endlessly-written pipe.
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                output.append(Data(bytes.prefix(count)))
            } else if count == 0 {
                source.cancel()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                source.cancel()
                return
            }
        }
    }

    func stop() { source.cancel() }
    deinit { source.cancel() }
}
