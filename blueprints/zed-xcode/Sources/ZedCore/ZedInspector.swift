import Foundation

public struct ZedAction: Codable, Sendable {
    public let id: String
    public let title: String
    public let kind: String
    public let command: String
    public let arguments: [String]
    public let requiresConfirmation: Bool
}

public struct ZedIssue: Codable, Sendable {
    public let id: String
    public let severity: String
    public let title: String
    public let detail: String
    public let files: [String]
    public let actions: [ZedAction]
}

public struct ZedReport: Codable, Sendable {
    public let schemaVersion: Int
    public let workspaceRoot: String
    public let zedVersion: String?
    public let issues: [ZedIssue]
}

public actor ZedInspector {
    public init() {}

    public func inspect(workspaceRoot: URL) async -> ZedReport {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zed", "inspect", "--workspace", workspaceRoot.path, "--json"]
        process.currentDirectoryURL = workspaceRoot

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return unavailable(root: workspaceRoot.path, detail: "The zed executable could not be started: \(error.localizedDescription)")
        }

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return failed(root: workspaceRoot.path, detail: detail?.isEmpty == false ? detail! : "zed exited with code \(process.terminationStatus)")
        }

        do {
            return try JSONDecoder().decode(ZedReport.self, from: stdout)
        } catch {
            return failed(root: workspaceRoot.path, detail: "Zed returned invalid JSON: \(error.localizedDescription)")
        }
    }

    private func unavailable(root: String, detail: String) -> ZedReport {
        let action = ZedAction(id: "open-install-docs", title: "Open installation instructions", kind: "url", command: "https://zpkg.tech", arguments: [], requiresConfirmation: false)
        return ZedReport(schemaVersion: 1, workspaceRoot: root, zedVersion: nil,
                         issues: [ZedIssue(id: "cli.unavailable", severity: "error", title: "Zed CLI is unavailable", detail: detail, files: [], actions: [action])])
    }

    private func failed(root: String, detail: String) -> ZedReport {
        ZedReport(schemaVersion: 1, workspaceRoot: root, zedVersion: nil,
                  issues: [ZedIssue(id: "inspect.failed", severity: "error", title: "Zed inspection failed", detail: detail, files: [], actions: [])])
    }
}
