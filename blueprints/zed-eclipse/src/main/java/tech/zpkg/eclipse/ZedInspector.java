package tech.zpkg.eclipse;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.TimeUnit;

public final class ZedInspector {
    private static final ObjectMapper JSON = new ObjectMapper()
            .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    public record Action(String id, String title, String kind, String command,
                         List<String> arguments, boolean requiresConfirmation) {}
    public record Issue(String id, String severity, String title, String detail,
                        List<String> files, List<Action> actions) {}
    public record Report(int schemaVersion, String workspaceRoot, String zedVersion,
                         List<Issue> issues) {}

    public Report inspect(Path workspaceRoot) throws IOException, InterruptedException {
        var root = workspaceRoot.toAbsolutePath().normalize();
        final Process process;
        try {
            process = new ProcessBuilder("zed", "inspect", "--workspace", root.toString(), "--json")
                    .directory(root.toFile())
                    .redirectErrorStream(false)
                    .start();
        } catch (IOException unavailable) {
            return unavailable(root, "The zed executable was not found on PATH.");
        }

        if (!process.waitFor(30, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            return failed(root, "Zed inspection timed out after 30 seconds.");
        }

        var stdout = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        var stderr = new String(process.getErrorStream().readAllBytes(), StandardCharsets.UTF_8);
        if (process.exitValue() != 0) {
            return failed(root, stderr.isBlank() ? "zed exited with code " + process.exitValue() : stderr.trim());
        }

        try {
            return JSON.readValue(stdout, Report.class);
        } catch (IOException invalidJson) {
            return failed(root, "Zed returned invalid JSON: " + invalidJson.getMessage());
        }
    }

    private static Report unavailable(Path root, String detail) {
        var action = new Action("open-install-docs", "Open installation instructions", "url",
                "https://zpkg.tech", List.of(), false);
        return new Report(1, root.toString(), null,
                List.of(new Issue("cli.unavailable", "error", "Zed CLI is unavailable",
                        detail, List.of(), List.of(action))));
    }

    private static Report failed(Path root, String detail) {
        return new Report(1, root.toString(), null,
                List.of(new Issue("inspect.failed", "error", "Zed inspection failed",
                        detail, List.of(), List.of())));
    }
}
