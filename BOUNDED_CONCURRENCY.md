# Bounded local concurrency policy

Tracking: https://github.com/zed-pkg/.github/issues/107  
Initial implementation: https://github.com/zed-pkg/zed-cli/issues/472

This policy applies to Zed repositories that fan out local work across Rust threads, async tasks, child processes, subprocess pools, or in-memory job queues.

## Core rule

Work fan-out must be bounded by construction. Input size, dependency-graph size, or request volume must not directly determine the number of local threads, child processes, or queued jobs.

A lock alone is not a concurrency bound. A queue protected by `Mutex` can still grow without limit. Approved designs therefore need explicit limits for both execution and waiting work.

## Required invariants

For every local execution subsystem that can fan out work, define and test these values independently where applicable:

1. **worker bound** — maximum live worker threads/tasks;
2. **queue bound** — maximum admitted-but-not-running jobs;
3. **process bound** — maximum concurrently running child processes;
4. **admission behavior** — what happens when the queue is full;
5. **shutdown behavior** — how admission closes, queued work drains/cancels, and workers/children are joined or reaped;
6. **nested-work behavior** — why a worker submitting/waiting for child work cannot deadlock the same executor;
7. **error behavior** — how panics, task errors, child failures, cancellation, and poisoned state propagate;
8. **configuration behavior** — accepted range, defaults, environment/CLI mapping, and invalid-value handling.

## Preferred Rust pattern

For synchronous local orchestration, prefer a small auditable scheduler with:

- a fixed worker set;
- `VecDeque<Job>` or equivalent bounded queue;
- `Mutex + Condvar`, a bounded channel, or another well-audited bounded primitive;
- explicit backpressure when capacity is reached;
- deterministic worker shutdown/join;
- a separate child-process permit layer when subprocesses are materially more expensive than worker threads;
- no heavyweight async runtime added solely to obtain a thread pool.

A bounded channel is acceptable only when its use cannot deadlock nested submissions. In particular, a worker must not block forever enqueueing or synchronously waiting for work that requires a worker from the same fully occupied pool. Approved solutions include same-executor inline/help execution, a coordinator-driven DAG scheduler, or another design with an equivalent tested progress guarantee.

## Defaults and overrides

- Preserve established CLI/config behavior unless a separate reviewed change intentionally revises it.
- Reject zero or otherwise invalid concurrency values before partial execution.
- CPU-derived defaults may use `std::thread::available_parallelism()` when appropriate, but I/O-bound/process-bound workloads may justify a different default or explicit override.
- Do not silently cap an explicit user value to CPU count unless that behavior is part of the documented interface contract.
- Queue capacity should be a finite centralized function of the execution budget or an explicit configuration value. Use saturating/checked arithmetic.

## Separate worker and child-process budgets

Worker count and subprocess count are distinct resource dimensions.

For example, a package build scheduler may safely keep four Rust workers alive while allowing only two expensive compilers/linkers at once, or may permit more network-bound fetch operations than CPU-heavy child processes. Do not make those limits accidentally identical merely because one `--jobs` flag exists today.

A subsystem may initially map both limits from one compatibility flag, but the implementation should keep the mechanisms separable.

## Disallowed fan-out patterns

The following require redesign or a documented narrowly scoped exception:

- one `std::thread::spawn` per graph node/item/request with no hard upper bound;
- one async task per input item when the runtime admits them all eagerly without a concurrency/admission limit;
- unbounded `mpsc::channel`/queue usage for producer rates that can exceed consumer capacity;
- queues whose only protection is `Mutex`/`RwLock` but whose length is not bounded;
- recursive worker submission where every worker can enqueue child work and synchronously wait for that same pool without a progress guarantee;
- child-process spawning whose maximum concurrency is derived only from how quickly upstream work arrives;
- detached local workers/processes that can outlive the owning command without an explicit daemon/service contract.

## Legitimate dedicated-thread exceptions

A dedicated thread may be appropriate for a singular role such as one signal loop, one terminal/UI event loop, one process-reaper, or one long-lived IPC reader. The exception must be structurally bounded and documented near the spawn site.

An exception must state:

- why the role needs a dedicated thread;
- the maximum number of such threads per process;
- who owns shutdown/join;
- why input size cannot increase that count.

## Required tests

Execution repositories should add focused tests that prove applicable invariants rather than only checking output correctness.

Minimum expectations for a worker-pool/queue subsystem:

- large synthetic input does not increase worker count past the configured limit;
- queue occupancy never exceeds capacity;
- saturation produces the documented backpressure/failure behavior;
- nested work completes without deadlock;
- job panic/error does not silently strand the queue;
- shutdown joins all workers and rejects late admission;
- peak child-process count never exceeds its own permit budget;
- duplicate/idempotent work remains correct under concurrency.

Where cross-platform process semantics matter, cover Linux, macOS, and Windows.

## Enforcement direction

This document is the policy authority; enforcement should be layered rather than relying on a single grep.

### Repository-local static checks

Rust repositories that own execution machinery should reject newly introduced suspicious fan-out sites such as:

- `std::thread::spawn` / `thread::spawn` outside approved scheduler/dedicated-thread modules;
- unbounded channel constructors in task/process fan-out paths;
- direct process spawning that bypasses an established subprocess limiter.

Checks should support narrow allowlisted paths or annotations for reviewed exceptions. They should not blindly reject all thread creation because the approved scheduler itself must create its fixed worker set.

### zed-pkg lifecycle and git hooks

When the shared rule is mature, zed-pkg lifecycle hooks and git hooks should invoke the repository-local check so violations are caught before CI. Hooks must not mutate source or bypass ordinary review.

### `.ores-lint`

`.ores-lint/rust.sh` may eventually surface suspicious unbounded fan-out as an organization warning, but policy enforcement should remain context-aware. A lexical match by itself cannot prove a spawn is unbounded.

## Initial adoption: `zed-cli`

`zed-cli` is the first target because its native task runtime currently has a positive `--jobs` budget, bounded per-group scoped thread batches, a `Mutex + Condvar` child-command limiter, and synchronized task identity state, but it does not yet reuse a fixed worker pool with a bounded runnable queue.

The implementation tracker is https://github.com/zed-pkg/zed-cli/issues/472. The preliminary design intentionally preserves the current default `jobs = 1` and the separate command limiter while introducing explicit worker/queue bounds.

## Review checklist

Before approving a new or changed concurrency subsystem, reviewers should be able to answer all of these from code/tests rather than inference:

- What is the maximum number of workers?
- What is the maximum queue length?
- What is the maximum number of child processes?
- What happens when the queue is full?
- Can workers synchronously wait for jobs requiring the same workers?
- What happens on panic/error/cancellation?
- Who closes admission and joins workers?
- Can any worker/process outlive the owning command?
- Are CLI/env/config concurrency values validated consistently?
- Does a large graph/input change only elapsed time, not the resource ceiling?
