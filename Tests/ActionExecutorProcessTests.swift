import Foundation
import AppKit

@main
struct ActionExecutorProcessTests {
    struct TestFailure: Error { let message: String }
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) throws {
        assertions += 1
        if !condition() { throw TestFailure(message: "line \(line): \(message)") }
    }

    static func pump(seconds: TimeInterval = 5, until ready: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if ready() { return true }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return ready()
    }

    static func marker(_ name: String, in root: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("\(name)-started.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func main() {
        do { try runTests() }
        catch {
            let detail = (error as? TestFailure)?.message ?? error.localizedDescription
            fputs("FAIL: \(detail)\n", stderr)
            exit(1)
        }
    }

    static func runTests() throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("presslet-process-tests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        let runner = root.appendingPathComponent("local-test-runner.py")
        let script = #"""
        #!/usr/bin/python3
        import json, os, signal, sys, time
        from pathlib import Path
        root = Path(__file__).resolve().parent
        args = sys.argv[1:]
        if len(args) < 2 or args[0] != "run":
            sys.exit(64)
        mode = args[1]
        paths = args[3:] if len(args) >= 3 and args[2] == "--input-path" else []
        def stop(signum, frame):
            (root / (mode + "-terminated")).write_text("stopped", encoding="utf-8")
            sys.exit(128 + signum)
        signal.signal(signal.SIGTERM, stop)
        (root / (mode + "-started.json")).write_text(json.dumps({"arguments": args, "paths": paths, "pid": os.getpid()}), encoding="utf-8")
        if mode == "wait":
            for _ in range(200):
                time.sleep(0.05)
            sys.exit(0)
        if mode == "fail":
            sys.stderr.buffer.write("本地测试预期失败".encode("utf-8"))
            sys.exit(7)
        data = b"\n".join(Path(path).read_bytes() for path in paths)
        sys.stdout.buffer.write(data if paths else "没有输入".encode("utf-8"))
        """#
        try Data(script.utf8).write(to: runner)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
        let executor = ActionExecutor(workflowExecutableURL: runner)
        defer { executor.cancelAll() }
        let target = NSRunningApplication.current
        try expect(target.processIdentifier > 0, "AppKit resolves the current test process (AppKit PID \(target.processIdentifier), actual PID \(ProcessInfo.processInfo.processIdentifier))")
        let text = "第一行中文：按压输入\n第二行保留换行 🪁"
        let context = ActionContext(sourcePID: target.processIdentifier,
                                    sourceBundleID: "app.presslet.process-tests", sourceName: "Test Runner",
                                    capturedAt: Date(), selectedText: text)
        let echo = MenuAction(title: "Echo test", kind: .workflow, value: "echo", inputRequirement: .selectedText)
        var echoResult: Result<String, Error>?
        executor.execute(echo, target: target, context: context) { echoResult = $0 }
        try expect(pump { echoResult != nil }, "Real Process completes while the main RunLoop remains available")
        guard case .success(let returned)? = echoResult else {
            throw TestFailure(message: "Echo helper did not succeed: \(String(describing: echoResult))")
        }
        try expect(returned == "快捷指令已完成。\n" + text, "Actual helper output carries UTF-8 Chinese text and its internal newline")
        let echoMarker = try marker("echo", in: root)
        let echoPaths = echoMarker["paths"] as! [String]
        try expect(echoPaths.count == 1, "Text is delivered as one actual input file")
        try expect((echoMarker["arguments"] as! [String]) == ["run", "echo", "--input-path", echoPaths[0]], "Actual process receives the expected argument boundaries")
        try expect(!manager.fileExists(atPath: echoPaths[0]), "Successful completion removes its temporary text input before callback")
        try expect(!manager.fileExists(atPath: URL(fileURLWithPath: echoPaths[0]).deletingLastPathComponent().path), "Successful completion removes its private directory")

        let missing = MenuAction(title: "Missing input", kind: .workflow, value: "missing", inputRequirement: .selectedText)
        var missingResult: Result<String, Error>?
        executor.execute(missing, target: target, context: nil) { missingResult = $0 }
        try expect(pump { missingResult != nil }, "Missing input returns promptly")
        if case .failure? = missingResult {} else { throw TestFailure(message: "Missing input was accepted") }
        try expect(!manager.fileExists(atPath: root.appendingPathComponent("missing-started.json").path), "Missing input never launches the runner")

        let failure = MenuAction(title: "Failure test", kind: .workflow, value: "fail", inputRequirement: .selectedText)
        var failureResult: Result<String, Error>?
        executor.execute(failure, target: target, context: context) { failureResult = $0 }
        try expect(pump { failureResult != nil }, "Nonzero process exit completes")
        if case .failure(let error)? = failureResult {
            try expect(error.localizedDescription.contains("本地测试预期失败"), "Actual bounded stderr is reported for a nonzero exit")
        } else { throw TestFailure(message: "Nonzero exit was reported as success") }
        let failurePaths = try marker("fail", in: root)["paths"] as! [String]
        try expect(!manager.fileExists(atPath: failurePaths[0]), "Nonzero exit cleans its input")

        let wait = MenuAction(title: "Cancel test", kind: .workflow, value: "wait", inputRequirement: .selectedText)
        var cancelResult: Result<String, Error>?
        var cancelCallbacks = 0
        executor.execute(wait, target: target, context: context) {
            cancelCallbacks += 1
            cancelResult = $0
        }
        let waitStarted = root.appendingPathComponent("wait-started.json")
        try expect(pump { manager.fileExists(atPath: waitStarted.path) }, "Cancelable helper actually started")
        let waitPaths = try marker("wait", in: root)["paths"] as! [String]
        try expect(manager.fileExists(atPath: waitPaths[0]), "Input stays available while the process is running")
        executor.cancelAll()
        try expect(pump { cancelResult != nil }, "Cancellation calls completion without blocking the main thread")
        if case .failure(let error)? = cancelResult {
            try expect(error.localizedDescription.contains("已取消"), "Cancellation is reported as cancellation")
        } else { throw TestFailure(message: "Cancellation was reported as success") }
        try expect(!manager.fileExists(atPath: waitPaths[0]), "Cancellation removes private input")
        let terminated = root.appendingPathComponent("wait-terminated")
        try expect(pump(seconds: 3) { manager.fileExists(atPath: terminated.path) }, "Cancellation terminates only the launched local helper")
        _ = pump(seconds: 0.2) { false }
        try expect(cancelCallbacks == 1, "Late process termination cannot deliver a duplicate callback")

        let none = MenuAction(title: "No input", kind: .workflow, value: "none")
        var noneResult: Result<String, Error>?
        executor.execute(none, target: nil) { noneResult = $0 }
        try expect(pump { noneResult != nil }, "Existing input-free call signature still works")
        if case .success(let message)? = noneResult {
            try expect(message.contains("没有输入"), "Input-free runner returns its real output")
        } else { throw TestFailure(message: "Input-free execution failed") }
        let noneMarker = try marker("none", in: root)
        try expect((noneMarker["arguments"] as! [String]) == ["run", "none"], "Input-free actions do not add input-path arguments")
        print("PASS: \(assertions) local process integration assertions")
    }
}
