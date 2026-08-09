# zed-eclipse

Buildable Eclipse core candidate for Zed Package Manager state, diagnostics, and recommended actions.

The Java process adapter uses an argv vector, a bounded timeout, schema validation, failure redaction, and rejects command actions that do not require explicit confirmation. `mvn test` exercises the safety boundary.

A dedicated repository still needs the PDE/OSGi bundle, Zed Packages view, workspace markers, quick fixes, p2 update site, and clean Eclipse application tests.
