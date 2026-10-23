import Foundation

@main
struct ActionExecutorInputTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        assertions += 1
        guard condition() else { fputs("FAIL line \(line): \(message)\n", stderr); exit(1) }
    }

    static func expectFailure(_ message: String, _ body: () throws -> Void) {
        do { try body(); expect(false, message) }
        catch { expect(!error.localizedDescription.isEmpty, message) }
    }

    static func context(text: String? = nil, files: [URL] = [], pid: Int32 = 123) -> ActionContext {
        ActionContext(sourcePID: pid, sourceBundleID: "com.example.editor", sourceName: "Editor",
                      capturedAt: Date(), selectedText: text, fileURLs: files)
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("presslet-input-tests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }

        let none = try ActionInputPayload.prepare(.none, context: nil, targetPID: nil, temporaryRoot: root)
        expect(none.inputURLs.isEmpty && none.temporaryDirectory == nil, "No-input actions create no files")
        let noInputArguments = try none.workflowArguments(name: "测试动作")
        expect(noInputArguments == ["run", "测试动作"], "Old no-input argument shape retained")
        expectFailure("Input cannot be inferred without a context") {
            try ActionInputPayload.validate(.selectedText, context: nil, targetPID: 123)
        }
        expectFailure("Input cannot be sent without a source process") {
            try ActionInputPayload.validate(.selectedText, context: context(text: "picked"), targetPID: nil)
        }
        expectFailure("Mismatched process is rejected") {
            try ActionInputPayload.validate(.selectedText, context: context(text: "picked"), targetPID: 456)
        }
        expectFailure("Provided contexts always retain their source process") {
            try ActionInputPayload.validate(.none, context: context(), targetPID: 456)
        }
        expectFailure("Whitespace is not treated as selected text") {
            _ = try ActionInputPayload.prepare(.selectedText, context: context(text: " \n\t"), targetPID: 123, temporaryRoot: root)
        }
        expectFailure("Text does not satisfy a file requirement") {
            _ = try ActionInputPayload.prepare(.selectedFiles, context: context(text: "picked"), targetPID: 123, temporaryRoot: root)
        }
        expectFailure("Missing text does not reuse files or clipboard contents") {
            _ = try ActionInputPayload.prepare(.selectedText, context: context(), targetPID: 123, temporaryRoot: root)
        }

        let originalText = "中文、emoji 🪁\n  whitespace retained\n\t第二行"
        let payload = try ActionInputPayload.prepare(.selectedText, context: context(text: originalText), targetPID: 123, temporaryRoot: root)
        expect(payload.inputURLs.count == 1, "Text becomes one UTF-8 input file")
        let textFile = payload.inputURLs[0]
        let actual = try String(contentsOf: textFile, encoding: .utf8)
        expect(actual == originalText, "Exact selected text is retained")
        let directory = payload.temporaryDirectory!
        let directoryMode = (try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber).intValue & 0o777
        let fileMode = (try manager.attributesOfItem(atPath: textFile.path)[.posixPermissions] as! NSNumber).intValue & 0o777
        expect(directoryMode == 0o700, "Text directory is owner-only")
        expect(fileMode == 0o600, "Text file is owner-only")
        let arguments = try payload.workflowArguments(name: "工作 flow; $(echo private)")
        expect(arguments == ["run", "工作 flow; $(echo private)", "--input-path", textFile.path], "Names and paths stay separate arguments")
        for invalid in ["", " \n", "bad\0name", "--help", "-i"] {
            expectFailure("CLI options cannot masquerade as workflow names") { _ = try payload.workflowArguments(name: invalid) }
        }
        payload.cleanup()
        expect(!manager.fileExists(atPath: directory.path), "Explicit completion/cancel cleanup removes private text")
        payload.cleanup()
        expect(!manager.fileExists(atPath: directory.path), "Cleanup can be repeated")

        var abandoned: ActionInputPayload? = try ActionInputPayload.prepare(.selectedText, context: context(text: "abandoned"), targetPID: 123, temporaryRoot: root)
        let abandonedDirectory = abandoned!.temporaryDirectory!
        abandoned = nil
        expect(!manager.fileExists(atPath: abandonedDirectory.path), "Abandoned or launch-failed payload cleans on release")

        var failedDirectory: URL?
        do {
            let failed = try ActionInputPayload.prepare(.selectedText, context: context(text: "failure"), targetPID: 123, temporaryRoot: root)
            failedDirectory = failed.temporaryDirectory
            _ = try failed.workflowArguments(name: "--help")
        } catch {}
        expect(failedDirectory != nil && !manager.fileExists(atPath: failedDirectory!.path), "Argument failure removes prepared private text")

        let first = root.appendingPathComponent("selected file 'one'.txt")
        let second = root.appendingPathComponent("第二个 $(file).png")
        try Data("one".utf8).write(to: first)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: second)
        let files = try ActionInputPayload.prepare(.selectedFiles, context: context(files: [first, second]), targetPID: 123, temporaryRoot: root)
        expect(files.inputURLs == [first, second] && files.temporaryDirectory == nil, "Original file URLs are retained without copying")
        let fileArguments = try files.workflowArguments(name: "Handle files")
        expect(fileArguments == ["run", "Handle files", "--input-path", first.path, second.path], "CLI variadic input preserves multiple files and order")
        files.cleanup()
        expect(manager.fileExists(atPath: first.path) && manager.fileExists(atPath: second.path), "Cleanup never deletes user-selected files")
        let image = try ActionInputPayload.prepare(.selectedImages, context: context(files: [second]), targetPID: 123, temporaryRoot: root)
        expect(image.inputURLs == [second], "Selected images remain original files")
        expectFailure("Mixed file types do not satisfy an image-only action") {
            _ = try ActionInputPayload.prepare(.selectedImages, context: context(files: [first, second]), targetPID: 123, temporaryRoot: root)
        }
        expectFailure("Non-file URLs are rejected") {
            _ = try ActionInputPayload.prepare(.selectedFiles, context: context(files: [URL(string: "https://example.com/a")!]), targetPID: 123, temporaryRoot: root)
        }
        let removed = root.appendingPathComponent("removed.txt")
        expectFailure("File disappearance is caught before dispatch") {
            _ = try ActionInputPayload.prepare(.selectedFiles, context: context(files: [removed]), targetPID: 123, temporaryRoot: root)
        }
        expectFailure("Failed private directory creation returns an error") {
            _ = try ActionInputPayload.prepare(.selectedText, context: context(text: "text"), targetPID: 123,
                                               temporaryRoot: root.appendingPathComponent("missing/parent"))
        }

        let output = BoundedActionOutput(limit: 10)
        output.append(Data("12345678".utf8))
        output.append(Data("ABCDEFGH".utf8))
        expect(output.text() == "12345678AB", "Large process output is capped while accepting further chunks")
        expect(output.displayedText()?.hasSuffix("（结果较长，仅显示前一部分。）") == true, "Partial output is labelled")
        let unicode = BoundedActionOutput(limit: 5)
        unicode.append(Data("中文".utf8))
        expect(unicode.displayedText()?.hasPrefix("中\n") == true, "Byte truncation does not corrupt UTF-8 display")
        let binary = BoundedActionOutput()
        binary.append(Data([0x89, 0x50, 0x00, 0xff]))
        expect(binary.displayedText() == nil, "Binary shortcut results are not displayed as text")
        let result = BoundedActionOutput()
        result.append(Data("  实际收到：选中内容\n".utf8))
        expect(result.displayedText() == "实际收到：选中内容", "Readable actual output is retained")

        let pipe = Pipe()
        let pipeOutput = BoundedActionOutput(limit: 32)
        let drainGroup = DispatchGroup()
        let reader = ActionPipeReader(handle: pipe.fileHandleForReading, output: pipeOutput, group: drainGroup)
        DispatchQueue.global(qos: .utility).async {
            try? pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: 512 * 1024))
            try? pipe.fileHandleForWriting.close()
        }
        expect(drainGroup.wait(timeout: .now() + 3) == .success, "Large output drains fully without filling the pipe")
        expect(pipeOutput.text() == String(repeating: "A", count: 32), "Draining large output still respects the memory cap")
        reader.stop()

        let retainedPipe = Pipe()
        let retainedGroup = DispatchGroup()
        let retainedReader = ActionPipeReader(handle: retainedPipe.fileHandleForReading, output: BoundedActionOutput(), group: retainedGroup)
        retainedReader.stop()
        retainedReader.stop()
        expect(retainedGroup.wait(timeout: .now() + 1) == .success, "Cancel closes a pipe even when a descendant keeps its write end open")
        try? retainedPipe.fileHandleForWriting.close()
        print("PASS: \(assertions) action input and output assertions")
    }
}
