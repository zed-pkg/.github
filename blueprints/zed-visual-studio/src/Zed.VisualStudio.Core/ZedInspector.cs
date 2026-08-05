using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Zed.VisualStudio.Core;

public sealed record ZedAction(
    string Id,
    string Title,
    string Kind,
    string Command,
    IReadOnlyList<string> Arguments,
    bool RequiresConfirmation);

public sealed record ZedIssue(
    string Id,
    string Severity,
    string Title,
    string Detail,
    IReadOnlyList<string> Files,
    IReadOnlyList<ZedAction> Actions);

public sealed record ZedReport(
    int SchemaVersion,
    string WorkspaceRoot,
    string? ZedVersion,
    IReadOnlyList<ZedIssue> Issues);

public sealed class ZedInspector
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public async Task<ZedReport> InspectAsync(string workspaceRoot, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(workspaceRoot))
            throw new ArgumentException("Workspace root is required.", nameof(workspaceRoot));

        var fullRoot = Path.GetFullPath(workspaceRoot);
        var startInfo = new ProcessStartInfo
        {
            FileName = "zed",
            Arguments = $"inspect --workspace \"{fullRoot}\" --json",
            WorkingDirectory = fullRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
                return Unavailable(fullRoot, "The zed process could not be started.");
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or FileNotFoundException)
        {
            return Unavailable(fullRoot, "The zed executable was not found on PATH.");
        }

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);

        if (process.ExitCode != 0)
        {
            return new ZedReport(1, fullRoot, null, new[]
            {
                new ZedIssue("inspect.failed", "error", "Zed inspection failed",
                    string.IsNullOrWhiteSpace(stderr) ? $"zed exited with code {process.ExitCode}." : stderr.Trim(),
                    Array.Empty<string>(), Array.Empty<ZedAction>())
            });
        }

        try
        {
            return JsonSerializer.Deserialize<ZedReport>(stdout, JsonOptions)
                ?? throw new JsonException("Zed returned an empty report.");
        }
        catch (JsonException ex)
        {
            return new ZedReport(1, fullRoot, null, new[]
            {
                new ZedIssue("inspect.invalid-json", "error", "Invalid Zed report", ex.Message,
                    Array.Empty<string>(), Array.Empty<ZedAction>())
            });
        }
    }

    private static ZedReport Unavailable(string root, string detail) =>
        new(1, root, null, new[]
        {
            new ZedIssue("cli.unavailable", "error", "Zed CLI is unavailable", detail,
                Array.Empty<string>(), new[]
                {
                    new ZedAction("open-install-docs", "Open installation instructions", "url", "https://zpkg.tech", Array.Empty<string>(), false)
                })
        });
}
