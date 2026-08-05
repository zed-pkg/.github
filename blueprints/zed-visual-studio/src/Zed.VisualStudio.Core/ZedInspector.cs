using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Zed.VisualStudio.Core;

public sealed record ZedAction(string Id, string Title, string Kind, string Command, IReadOnlyList<string> Arguments, bool RequiresConfirmation);
public sealed record ZedIssue(string Id, string Severity, string Title, string Detail, IReadOnlyList<string> Files, IReadOnlyList<ZedAction> Actions);
public sealed record ZedReport(int SchemaVersion, string WorkspaceRoot, string? ZedVersion, IReadOnlyList<ZedIssue> Issues);
public sealed record ZedProcessResult(int ExitCode, string Stdout, string Stderr);

public interface IZedProcessRunner {
    Task<ZedProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken cancellationToken);
}

public sealed class SystemZedProcessRunner : IZedProcessRunner {
    public async Task<ZedProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken cancellationToken) {
        var startInfo = new ProcessStartInfo { FileName = executable, WorkingDirectory = workingDirectory, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = startInfo };
        if (!process.Start()) throw new InvalidOperationException("The zed process could not be started.");
        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken); var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken); timeoutSource.CancelAfter(timeout);
        try { await process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { process.Kill(entireProcessTree: true); throw new TimeoutException($"Zed inspection timed out after {timeout.TotalSeconds:0} seconds."); }
        return new ZedProcessResult(process.ExitCode, await stdoutTask.ConfigureAwait(false), await stderrTask.ConfigureAwait(false));
    }
}

public sealed partial class ZedInspector {
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly IZedProcessRunner runner; private readonly string executable; private readonly TimeSpan timeout;
    public ZedInspector(IZedProcessRunner? runner = null, string executable = "zed", TimeSpan? timeout = null) { if (string.IsNullOrWhiteSpace(executable)) throw new ArgumentException("Zed executable is required.", nameof(executable)); this.runner = runner ?? new SystemZedProcessRunner(); this.executable = executable; this.timeout = timeout ?? TimeSpan.FromSeconds(30); }
    public IReadOnlyList<string> Arguments(string workspaceRoot) { var fullRoot = Path.GetFullPath(workspaceRoot); return ["inspect", "--workspace", fullRoot, "--json"]; }
    public async Task<ZedReport> InspectAsync(string workspaceRoot, CancellationToken cancellationToken = default) {
        if (string.IsNullOrWhiteSpace(workspaceRoot)) throw new ArgumentException("Workspace root is required.", nameof(workspaceRoot)); var fullRoot = Path.GetFullPath(workspaceRoot);
        try {
            var result = await runner.RunAsync(executable, Arguments(fullRoot), fullRoot, timeout, cancellationToken).ConfigureAwait(false);
            if (result.ExitCode != 0) return Failed(fullRoot, string.IsNullOrWhiteSpace(result.Stderr) ? $"zed exited with code {result.ExitCode}." : result.Stderr.Trim());
            try { var report = JsonSerializer.Deserialize<ZedReport>(result.Stdout, JsonOptions) ?? throw new JsonException("Zed returned an empty report."); return Validate(report, fullRoot); }
            catch (JsonException error) { return Failed(fullRoot, $"Zed returned invalid JSON: {error.Message}"); }
        } catch (TimeoutException error) { return Failed(fullRoot, error.Message); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or FileNotFoundException) { return Unavailable(fullRoot, "The zed executable was not found on PATH."); }
    }
    public ZedReport Validate(ZedReport report, string root) {
        if (report.SchemaVersion != 1) return Failed(root, "Unsupported Zed inspection schema; expected schemaVersion 1.");
        foreach (var issue in report.Issues ?? Array.Empty<ZedIssue>()) foreach (var action in issue.Actions ?? Array.Empty<ZedAction>()) if (action.Kind == "command" && !action.RequiresConfirmation) return Failed(root, $"Rejected unsafe command action '{action.Id}'.");
        var issues = (report.Issues ?? Array.Empty<ZedIssue>()).Select(issue => issue with { Detail = Redact(issue.Detail) }).ToArray(); return report with { SchemaVersion = 1, Issues = issues };
    }
    public static string Redact(string text) { if (string.IsNullOrEmpty(text)) return string.Empty; var output = AssignmentRegex().Replace(text, "$1=[REDACTED]"); output = BearerRegex().Replace(output, "Bearer [REDACTED]"); return GitHubTokenRegex().Replace(output, "[REDACTED]"); }
    private static ZedReport Unavailable(string root, string detail) => new(1, root, null, [new ZedIssue("cli.unavailable", "error", "Zed CLI is unavailable", Redact(detail), Array.Empty<string>(), [new ZedAction("open-install-docs", "Open installation instructions", "url", "https://zpkg.tech", Array.Empty<string>(), false)])]);
    private static ZedReport Failed(string root, string detail) => new(1, root, null, [new ZedIssue("inspect.failed", "error", "Zed inspection failed", Redact(detail), Array.Empty<string>(), Array.Empty<ZedAction>())]);
    [GeneratedRegex(@"(authorization|token|password|secret|api[_-]?key)\s*[:=]\s*([^\s,;]+)", RegexOptions.IgnoreCase)] private static partial Regex AssignmentRegex();
    [GeneratedRegex(@"bearer\s+[A-Za-z0-9._~+/=-]+", RegexOptions.IgnoreCase)] private static partial Regex BearerRegex();
    [GeneratedRegex(@"gh[pousr]_[A-Za-z0-9_]{20,}")] private static partial Regex GitHubTokenRegex();
}
