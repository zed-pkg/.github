using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using Zed.VisualStudio.Core;

namespace Zed.VisualStudio.Core.Tests;

public sealed class ZedInspectorTests {
    [Fact] public void UsesArgumentListAndRedactsCredentials() {
        var inspector = new ZedInspector(executable: @"C:\Tools\zed.exe"); var arguments = inspector.Arguments(@"C:\work space");
        Assert.Equal(["inspect", "--workspace", Path.GetFullPath(@"C:\work space"), "--json"], arguments);
        var text = ZedInspector.Redact("Authorization: Bearer abc.def token=secret ghp_abcdefghijklmnopqrstuvwxyz"); Assert.DoesNotContain("secret", text); Assert.DoesNotContain("ghp_", text); Assert.Contains("[REDACTED]", text);
    }
    [Fact] public async Task RejectsUnsafeCommandAction() {
        var unsafeReport = new ZedReport(1, Path.GetFullPath("."), "0.1.0", [new ZedIssue("lock.stale", "warning", "Stale", "token=x", [], [new ZedAction("install", "Install", "command", "zed", ["install"], false)])]);
        var report = await new ZedInspector(new FakeRunner(new ZedProcessResult(0, JsonSerializer.Serialize(unsafeReport), string.Empty))).InspectAsync("."); Assert.Equal("inspect.failed", Assert.Single(report.Issues).Id); Assert.DoesNotContain("token=x", report.Issues[0].Detail);
    }
    [Fact] public async Task AcceptsVersionOneReport() {
        var safe = new ZedReport(1, Path.GetFullPath("."), "0.1.0", []); var report = await new ZedInspector(new FakeRunner(new ZedProcessResult(0, JsonSerializer.Serialize(safe), string.Empty))).InspectAsync("."); Assert.Empty(report.Issues);
    }
    private sealed class FakeRunner(ZedProcessResult result) : IZedProcessRunner { public Task<ZedProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken cancellationToken) => Task.FromResult(result); }
}
