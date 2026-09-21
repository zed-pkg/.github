# Rust concurrency audit

`concurrency-rust.sh` is the advisory static companion to [`BOUNDED_CONCURRENCY.md`](../BOUNDED_CONCURRENCY.md). It is intentionally narrower than the policy: source text can identify suspicious fan-out sites, but it cannot prove that a site is actually unbounded.

## What it reports

The scanner walks Rust source files and reports review locations for:

- direct `thread::spawn` / `std::thread::spawn` calls;
- `thread::Builder` worker creation;
- unbounded standard-library `mpsc::channel()` calls;
- Tokio `mpsc::unbounded_channel()` calls; and
- crossbeam unbounded channel construction.

The fleet-wide `.ores-lint/lint.sh` wrapper always runs this pass in advisory mode. Existing repositories therefore receive visibility without suddenly failing because a lexical match cannot establish context.

## Strict adoption

A repository that has reviewed its concurrency model and intentionally adopted the bounded-concurrency policy may run the checker directly with:

```sh
ORES_LINT_CONCURRENCY_STRICT=1 sh .ores-lint/concurrency-rust.sh .
```

Strict mode exits non-zero when suspicious sites remain. It should be enabled only after each existing site has either moved behind a bounded scheduler/permit layer or received a narrowly reviewed exception.

`ORES_LINT_STRICT=1` on the general wrapper does **not** implicitly make this scanner strict; concurrency strictness is a separate opt-in because it has different false-positive characteristics from compiler/linter diagnostics.

## Reviewed exceptions

A suspicious site that is structurally bounded may carry a same-line marker:

```rust
thread::spawn(move || signal_loop()); // ores-concurrency: allow one signal thread per process
```

Every exception should explain the structural bound, not merely say “safe” or “intentional”. For a dedicated thread, document:

- its maximum count per process;
- who owns shutdown/join; and
- why input size cannot increase the count.

The approved fixed worker pool is itself expected to contain a bounded thread-creation site; that is precisely the kind of reviewed exception the marker is for.

## Configuration

- `ORES_LINT_SKIP_CONCURRENCY_RUST=1` disables this scanner.
- `ORES_LINT_CONCURRENCY_STRICT=1` makes direct scanner invocation fail on findings.
- `ORES_LINT_MAX_EXAMPLES` controls the number of example locations printed per rule.
- `ORES_LINT_DEPTH` controls source discovery depth.

The scanner excludes `.git`, `.ores-lint`, build/target/vendor directories, and temporary work directories.

## Deliberate limits

This is not a Rust parser and does not attempt to infer queue capacities, semaphore sizes, runtime worker counts, or control-flow guarantees. A clean scan is therefore not proof of policy compliance, and a finding is not proof of a defect. The policy still requires code review and tests that measure actual worker, queue, and process ceilings.
