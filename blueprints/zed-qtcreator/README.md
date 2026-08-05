# zed-qtcreator

Buildable Qt Creator integration candidate for Zed Package Manager insights.

The checked-in C++ core owns the safe process boundary, report validation,
redaction, and conformance tests. A dedicated repository must add the Qt Creator
`ExtensionSystem::IPlugin` shell, ProjectExplorer integration, Issues pane
markers, options page, signed plugin packaging, and clean-instance UI tests.

```sh
cmake -S . -B build -DBUILD_TESTING=ON
cmake --build build
ctest --test-dir build --output-on-failure
```

No command action is accepted unless it requires explicit confirmation.
