import Foundation

public struct ZedAction: Codable, Sendable {
    public let id: String; public let title: String; public let kind: String; public let command: String; public let arguments: [String]; public let requiresConfirmation: Bool
    public init(id: String, title: String, kind: String, command: String, arguments: [String], requiresConfirmation: Bool) { self.id = id; self.title = title; self.kind = kind; self.command = command; self.arguments = arguments; self.requiresConfirmation = requiresConfirmation }
}
public struct ZedIssue: Codable, Sendable {
    public let id: String; public let severity: String; public let title: String; public let detail: String; public let files: [String]; public let actions: [ZedAction]
    public init(id: String, severity: String, title: String, detail: String, files: [String], actions: [ZedAction]) { self.id = id; self.severity = severity; self.title = title; self.detail = detail; self.files = files; self.actions = actions }
}
public struct ZedReport: Codable, Sendable {
    public let schemaVersion: Int; public let workspaceRoot: String; public let zedVersion: String?; public let issues: [ZedIssue]
    public init(schemaVersion: Int, workspaceRoot: String, zedVersion: String?, issues: [ZedIssue]) { self.schemaVersion = schemaVersion; self.workspaceRoot = workspaceRoot; self.zedVersion = zedVersion; self.issues = issues }
}
public struct ZedProcessResult: Sendable {
    public let status: Int32; public let stdout: Data; public let stderr: Data
    public init(status: Int32, stdout: Data, stderr: Data) { self.status = status; self.stdout = stdout; self.stderr = stderr }
}
public protocol ZedProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], cwd: URL, timeoutSeconds: UInt64) async throws -> ZedProcessResult
}
public enum ZedProcessError: Error { case timeout }

public actor FoundationZedProcessRunner: ZedProcessRunning {
    public init() {}
    public func run(executable: URL, arguments: [String], cwd: URL, timeoutSeconds: UInt64) async throws -> ZedProcessResult {
        let process = Process(); process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = cwd
        let output = Pipe(); let errors = Pipe(); process.standardOutput = output; process.standardError = errors; try process.run()
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        if process.isRunning { process.terminate(); throw ZedProcessError.timeout }
        return ZedProcessResult(status: process.terminationStatus, stdout: output.fileHandleForReading.readDataToEndOfFile(), stderr: errors.fileHandleForReading.readDataToEndOfFile())
    }
}

public actor ZedInspector {
    private let runner: any ZedProcessRunning; private let executable: URL; private let timeoutSeconds: UInt64
    public init(runner: any ZedProcessRunning = FoundationZedProcessRunner(), executable: URL = URL(fileURLWithPath: "/usr/bin/env"), timeoutSeconds: UInt64 = 30) { self.runner = runner; self.executable = executable; self.timeoutSeconds = timeoutSeconds }
    public func command(workspaceRoot: URL) -> [String] { ["zed", "inspect", "--workspace", workspaceRoot.standardizedFileURL.path, "--json"] }
    public func inspect(workspaceRoot: URL) async -> ZedReport {
        let root = workspaceRoot.standardizedFileURL
        do {
            let result = try await runner.run(executable: executable, arguments: command(workspaceRoot: root), cwd: root, timeoutSeconds: timeoutSeconds)
            guard result.status == 0 else { let raw = String(data: result.stderr, encoding: .utf8) ?? ""; return failed(root: root.path, detail: raw.isEmpty ? "zed exited with code \(result.status)" : raw) }
            do { return validate(try JSONDecoder().decode(ZedReport.self, from: result.stdout), root: root.path) }
            catch { return failed(root: root.path, detail: "Zed returned invalid JSON: \(error.localizedDescription)") }
        } catch ZedProcessError.timeout { return failed(root: root.path, detail: "Zed inspection timed out after \(timeoutSeconds) seconds.") }
        catch { return unavailable(root: root.path, detail: "The zed executable could not be started: \(error.localizedDescription)") }
    }
    public func validate(_ report: ZedReport, root: String) -> ZedReport {
        guard report.schemaVersion == 1 else { return failed(root: root, detail: "Unsupported Zed inspection schema; expected schemaVersion 1.") }
        for issue in report.issues { for action in issue.actions where action.kind == "command" && !action.requiresConfirmation { return failed(root: root, detail: "Rejected unsafe command action '\(action.id)'.") } }
        let issues = report.issues.map { ZedIssue(id: $0.id, severity: $0.severity, title: $0.title, detail: ZedRedactor.redact($0.detail), files: $0.files, actions: $0.actions) }
        return ZedReport(schemaVersion: 1, workspaceRoot: report.workspaceRoot, zedVersion: report.zedVersion, issues: issues)
    }
    private func unavailable(root: String, detail: String) -> ZedReport {
        let action = ZedAction(id: "open-install-docs", title: "Open installation instructions", kind: "url", command: "https://zpkg.tech", arguments: [], requiresConfirmation: false)
        return ZedReport(schemaVersion: 1, workspaceRoot: root, zedVersion: nil, issues: [ZedIssue(id: "cli.unavailable", severity: "error", title: "Zed CLI is unavailable", detail: ZedRedactor.redact(detail), files: [], actions: [action])])
    }
    private func failed(root: String, detail: String) -> ZedReport { ZedReport(schemaVersion: 1, workspaceRoot: root, zedVersion: nil, issues: [ZedIssue(id: "inspect.failed", severity: "error", title: "Zed inspection failed", detail: ZedRedactor.redact(detail), files: [], actions: [])]) }
}

public enum ZedRedactor {
    private static let patterns: [(String, String)] = [
        (#"(?i)(authorization|token|password|secret|api[_-]?key)\s*[:=]\s*([^\s,;]+)"#, "$1=[REDACTED]"),
        (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
        (#"gh[pousr]_[A-Za-z0-9_]{20,}"#, "[REDACTED]")
    ]
    public static func redact(_ text: String) -> String {
        patterns.reduce(text) { value, pair in
            guard let expression = try? NSRegularExpression(pattern: pair.0) else { return value }
            return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: pair.1)
        }
    }
}
