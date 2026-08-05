package tech.zpkg.eclipse;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

public final class ZedInspector {
    private static final ObjectMapper JSON = new ObjectMapper().configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);
    private static final Pattern ASSIGNMENT = Pattern.compile("(?i)(authorization|token|password|secret|api[_-]?key)\\s*[:=]\\s*([^\\s,;]+)");
    private static final Pattern BEARER = Pattern.compile("(?i)bearer\\s+[A-Za-z0-9._~+/=-]+");
    private static final Pattern GITHUB_TOKEN = Pattern.compile("gh[pousr]_[A-Za-z0-9_]{20,}");
    private final String executable;
    private final Duration timeout;

    public ZedInspector() { this("zed", Duration.ofSeconds(30)); }
    public ZedInspector(String executable, Duration timeout) {
        if (executable == null || executable.isBlank()) throw new IllegalArgumentException("zed executable must not be blank");
        if (timeout == null || timeout.isNegative() || timeout.isZero()) throw new IllegalArgumentException("timeout must be positive");
        this.executable = executable; this.timeout = timeout;
    }

    public record Action(String id, String title, String kind, String command, List<String> arguments, boolean requiresConfirmation) {}
    public record Issue(String id, String severity, String title, String detail, List<String> files, List<Action> actions) {}
    public record Report(int schemaVersion, String workspaceRoot, String zedVersion, List<Issue> issues) {}

    public List<String> command(Path workspaceRoot) {
        var root = workspaceRoot.toAbsolutePath().normalize();
        return List.of(executable, "inspect", "--workspace", root.toString(), "--json");
    }

    public Report inspect(Path workspaceRoot) throws InterruptedException {
        var root = workspaceRoot.toAbsolutePath().normalize();
        final Process process;
        try { process = new ProcessBuilder(command(root)).directory(root.toFile()).redirectErrorStream(false).start(); }
        catch (IOException unavailable) { return unavailable(root, "The zed executable was not found or could not be started."); }
        var stdoutFuture = CompletableFuture.supplyAsync(() -> read(process.getInputStream()));
        var stderrFuture = CompletableFuture.supplyAsync(() -> read(process.getErrorStream()));
        if (!process.waitFor(timeout.toMillis(), TimeUnit.MILLISECONDS)) {
            process.destroyForcibly(); return failed(root, "Zed inspection timed out after " + timeout.toSeconds() + " seconds.");
        }
        var stdout = stdoutFuture.join(); var stderr = stderrFuture.join();
        if (process.exitValue() != 0) return failed(root, stderr.isBlank() ? "zed exited with code " + process.exitValue() : stderr.trim());
        try { return validateReport(JSON.readValue(stdout, Report.class), root); }
        catch (IOException invalidJson) { return failed(root, "Zed returned invalid JSON: " + invalidJson.getMessage()); }
    }

    Report validateReport(Report report, Path root) {
        if (report == null || report.schemaVersion() != 1) return failed(root, "Unsupported Zed inspection schema; expected schemaVersion 1.");
        for (var issue : safe(report.issues())) for (var action : safe(issue.actions()))
            if ("command".equals(action.kind()) && !action.requiresConfirmation())
                return failed(root, "Rejected unsafe command action '" + action.id() + "': command actions must require explicit confirmation.");
        var sanitized = safe(report.issues()).stream().map(issue -> new Issue(issue.id(), issue.severity(), issue.title(), redact(issue.detail()), safe(issue.files()), safe(issue.actions()))).toList();
        return new Report(1, report.workspaceRoot(), report.zedVersion(), sanitized);
    }

    public static String redact(String text) {
        if (text == null || text.isEmpty()) return "";
        var output = ASSIGNMENT.matcher(text).replaceAll("$1=[REDACTED]");
        output = BEARER.matcher(output).replaceAll("Bearer [REDACTED]");
        return GITHUB_TOKEN.matcher(output).replaceAll("[REDACTED]");
    }
    private static String read(java.io.InputStream stream) { try (stream) { return new String(stream.readAllBytes(), StandardCharsets.UTF_8); } catch (IOException error) { return "Unable to read process output: " + error.getClass().getSimpleName(); } }
    private static <T> List<T> safe(List<T> values) { return values == null ? List.of() : values; }
    private static Report unavailable(Path root, String detail) { var action = new Action("open-install-docs", "Open installation instructions", "url", "https://zpkg.tech", List.of(), false); return new Report(1, root.toString(), null, List.of(new Issue("cli.unavailable", "error", "Zed CLI is unavailable", redact(detail), List.of(), List.of(action)))); }
    private static Report failed(Path root, String detail) { return new Report(1, root.toString(), null, List.of(new Issue("inspect.failed", "error", "Zed inspection failed", redact(detail), List.of(), List.of()))); }
}
