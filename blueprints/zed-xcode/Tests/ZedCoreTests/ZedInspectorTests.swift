import Foundation
import Testing
@testable import ZedCore

private struct FakeRunner: ZedProcessRunning {
    let result: ZedProcessResult
    func run(executable: URL, arguments: [String], cwd: URL, timeoutSeconds: UInt64) async throws -> ZedProcessResult { result }
}

@Test func buildsArgumentVector() async {
    let inspector = ZedInspector()
    let command = await inspector.command(workspaceRoot: URL(fileURLWithPath: "/tmp/work space"))
    #expect(command == ["zed", "inspect", "--workspace", "/tmp/work space", "--json"])
}

@Test func redactsAndRejectsUnsafeActions() async {
    let unsafe = ZedReport(schemaVersion: 1, workspaceRoot: "/workspace", zedVersion: "0.1.0", issues: [ZedIssue(id: "lock.stale", severity: "warning", title: "Stale", detail: "token=secret ghp_abcdefghijklmnopqrstuvwxyz", files: [], actions: [ZedAction(id: "install", title: "Install", kind: "command", command: "zed", arguments: ["install"], requiresConfirmation: false)])])
    let report = await ZedInspector().validate(unsafe, root: "/workspace")
    #expect(report.issues.first?.id == "inspect.failed")
    #expect(report.issues.first?.detail.contains("secret") == false)
}

@Test func decodesSafeReportThroughInjectedRunner() async throws {
    let safe = ZedReport(schemaVersion: 1, workspaceRoot: "/workspace", zedVersion: "0.1.0", issues: [])
    let runner = FakeRunner(result: ZedProcessResult(status: 0, stdout: try JSONEncoder().encode(safe), stderr: Data()))
    let inspector = ZedInspector(runner: runner, executable: URL(fileURLWithPath: "/fake"))
    let report = await inspector.inspect(workspaceRoot: URL(fileURLWithPath: "/workspace"))
    #expect(report.schemaVersion == 1)
    #expect(report.issues.isEmpty)
}
