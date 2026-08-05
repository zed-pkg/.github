package tech.zpkg.eclipse;

import org.junit.jupiter.api.Test;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import static org.junit.jupiter.api.Assertions.*;

class ZedInspectorTest {
    @Test void commandUsesArgumentVectorAndAbsoluteWorkspace() {
        var inspector = new ZedInspector("/opt/zed/bin/zed", Duration.ofSeconds(12));
        var command = inspector.command(Path.of("workspace"));
        assertEquals("/opt/zed/bin/zed", command.getFirst()); assertEquals("inspect", command.get(1)); assertEquals("--workspace", command.get(2)); assertTrue(Path.of(command.get(3)).isAbsolute()); assertEquals("--json", command.get(4));
    }
    @Test void redactsCredentialShapes() {
        var text = ZedInspector.redact("Authorization: Bearer abc.def token=secret ghp_abcdefghijklmnopqrstuvwxyz");
        assertFalse(text.contains("secret")); assertFalse(text.contains("ghp_")); assertTrue(text.contains("[REDACTED]"));
    }
    @Test void rejectsUnknownSchemaAndUnsafeCommands() {
        var inspector = new ZedInspector(); var root = Path.of("/workspace");
        var unknown = inspector.validateReport(new ZedInspector.Report(2, root.toString(), null, List.of()), root);
        assertEquals("inspect.failed", unknown.issues().getFirst().id());
        var unsafe = new ZedInspector.Report(1, root.toString(), null, List.of(new ZedInspector.Issue("lock.stale", "warning", "Stale lock", "token=x", List.of(), List.of(new ZedInspector.Action("install", "Install", "command", "zed", List.of("install"), false)))));
        var rejected = inspector.validateReport(unsafe, root);
        assertEquals("inspect.failed", rejected.issues().getFirst().id()); assertFalse(rejected.issues().getFirst().detail().contains("token=x"));
    }
}
