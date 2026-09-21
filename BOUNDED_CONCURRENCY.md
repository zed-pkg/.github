# Bounded local concurrency policy

Tracking: https://github.com/zed-pkg/.github/issues/107  
Initial implementation: https://github.com/zed-pkg/zed-cli/issues/472

This policy applies to Zed repositories that fan out local work across Rust threads, async tasks, child processes, subprocess pools, or in-memory job queues.

## Core rule

Work fan-out must be bounded by construction. Input size, dependency-graph size, request volume, or a user-supplied integer must not directly determine an effectively unbounded number of local threads, child processes, queued jobs, or eagerly reserved queue memory.

A lock alone is not a concurrency bound. A queue protected by `Mutex` can still grow without limit. Approved designs therefore need explicit limits for both execution and waiting work.

## Required invariants

For every local execution subsystem that can fan out work, define and test these values independently where applicable:

1. **worker bound** — maximum live worker threads/tasks, including an absolute safety ceiling;
2. **queue bound** — maximum admitted-but-not-running jobs and whether capacity is eagerly reserved;
3. **process bound** — maximum concurrently running child processes;
4. **admission behavior** — what happens when the queue is full and what happens to blocked producers when admission closes;
5. **shutdown behavior** — how external admission closes, already-admitted nested work drains/cancels, and workers/children are joined or reaped;
6. **nested-work behavior** — why a worker submitting/waiting for child work cannot deadlock the same executor and how recursive inline execution avoids unbounded stack growth;
7. **ownership behavior** — why an executor owner cannot be moved into one of its own workers and attempt to join itself;
8. **error behavior** — how panics, task errors, child failures, cancellation, mutex poisoning, and worker-join failures propagate;
9. **configuration behavior** — accepted range, absolute ceiling, defaults, environment/CLI mapping, and invalid-value handling.

## Preferred Rust pattern

For synchronous local orchestration, prefer a small auditable scheduler with:

- a fixed worker set;
- `VecDeque<Job>` or equivalent bounded queue;
- `Mutex + Condvar`, a bounded channel, or another well-audited bounded primitive;
- explicit backpressure when capacity is reached;
- deterministic worker shutdown/join;
- an owner object that cannot self-join from a worker context;
- a separate child-process permit layer when subprocesses are materially more expensive than worker threads;
- poison recovery or an explicitly documented fail-closed poison policy;
- no heavyweight async runtime added solely to obtain a thread pool.

A bounded channel is acceptable only when its use cannot deadlock nested submissions. In particular, a worker must not block forever enqueueing or synchronously waiting for work that requires a worker from the same fully occupied pool. Approved solutions include same-executor inline/help execution, a coordinator-driven DAG scheduler, or another design with an equivalent tested progress guarantee.

If nested same-executor work runs inline, the implementation must also address recursion depth. Bounded thread count does not make an unbounded recursive call chain safe.

## Defaults, overrides, and hard ceilings

- Preserve established CLI/config behavior unless a separate reviewed change intentionally revises it.
- Reject zero or otherwise invalid concurrency values before partial execution.
- Define an absolute upper bound for native worker creation even when a CLI/config value is explicitly supplied.
- Reject values above the hard safety ceiling rather than silently clamping them unless clamping is itself part of the documented contract.
- CPU-derived defaults may use `std::thread::available_parallelism()` when appropriate, but I/O-bound/process-bound workloads may justify a different default or explicit override.
- Do not silently cap an explicit user value to CPU count unless that behavior is part of the documented interface contract.
- Queue capacity should be a finite centralized function of the execution budget or an explicit configuration value. Use saturating/checked arithmetic.
- Do not eagerly reserve attacker/user-sized queue capacity merely because the logical limit is large; prefer lazy bounded growth unless preallocation has a reviewed reason.

## Separate worker and child-process budgets

Worker count and subprocess count are distinct resource dimensions.

For example, a package build scheduler may safely keep four Rust workers alive while allowing only two expensive compilers/linkers at once, or may permit more network-bound fetch operations than CPU-heavy child processes. Do not make those limits accidentally identical merely because one `--jobs` flag exists today.

A subsystem may initially map both limits from one compatibility flag, but the implementation should keep the mechanisms separable.

## Shutdown and draining

A scheduler that drains admitted work should normally distinguish between:

- **new external submissions**, which are rejected once shutdown begins; and
- **nested work required to finish already-admitted jobs**, which must either remain executable under the drain contract or be cancelled through an explicit cancellation contract.

Closing both classes indiscriminately can make an already-admitted parent fail only because shutdown started while it was running.

Producers blocked on a full queue must be awakened when admission closes. Shutdown must not leave a producer permanently sleeping on queue space that will never be admitted.

If an executor owns worker `JoinHandle`s, its type/ownership model should prevent a worker from owning the executor and attempting to join itself. Prefer excluding that state by type where practical rather than detecting it after the fact.

## Panic, poison, and cancellation

User job panics should not silently destroy a worker and strand unrelated admitted work. Catch/translate them at an appropriate job boundary or otherwise make worker loss explicit and observable.

Mutex poisoning must have an explicit policy. Scheduler code should not casually convert poisoning into secondary `expect`/`unwrap` panics during shutdown or error handling when the guarded state can be safely recovered.

A wait timeout is not automatically job cancellation. If a result wait can time out while work continues, document that distinction. If cancellation is supported, define who owns descendant processes and how they are reaped.

## Disallowed fan-out patterns

The following require redesign or a documented narrowly scoped exception:

- one `std::thread::spawn` per graph node/item/request with no hard upper bound;
- one async task per input item when the runtime admits them all eagerly without a concurrency/admission limit;
- unbounded `mpsc::channel`/queue usage for producer rates that can exceed consumer capacity;
- queues whose only protection is `Mutex`/`RwLock` but whose length is not bounded;
- recursive worker submission where every worker can enqueue child work and synchronously wait for that same pool without a progress guarantee;
- unbounded recursive inline execution used as the only deadlock-avoidance strategy;
- executor ownership that permits a worker to join itself;
- user-controlled worker counts with no absolute ceiling;
- eager allocation proportional to an unchecked user concurrency value;
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
- zero and extreme worker/queue requests fail before large allocation or thread creation;
- queue occupancy never exceeds capacity;
- saturation produces the documented backpressure/failure behavior;
- blocked producers wake with a defined result when admission closes;
- nested work completes without deadlock;
- shutdown does not reject nested work that is required by an already-admitted parent unless cancellation is the documented policy;
- recursive inline work has a depth/progress safety rule;
- user job panic/error does not silently strand the queue;
- internal worker panic/join failure is observable;
- shutdown joins all workers and rejects late external admission;
- peak child-process count never exceeds its own permit budget;
- duplicate/idempotent work remains correct under concurrency.

Where cross-platform process semantics matter, cover Linux, macOS, and Windows.

## Enforcement direction

This document is the policy authority; enforcement should be layered rather than relying on a single grep.

### Repository-local static checks

Rust repositories that own execution machinery should reject newly introduced suspicious fan-out sites such as:

- `std::thread::spawn` / `thread::spawn` outside approved scheduler/dedicated-thread modules;
- unbounded channel constructors in task/process fan-out paths;
- direct process spawning that bypasses an established subprocess limiter;
- queue preallocation or thread-loop counts sourced directly from unchecked CLI/config values.

Checks should support narrow allowlisted paths or annotations for reviewed exceptions. They should not blindly reject all thread creation because the approved scheduler itself must create its fixed worker set.

### zed-pkg lifecycle and git hooks

When the shared rule is mature, zed-pkg lifecycle hooks and git hooks should invoke the repository-local check so violations are caught before CI. Hooks must not mutate source or bypass ordinary review.

### `.ores-lint`

`.ores-lint` may surface suspicious unbounded fan-out as an organization warning, but policy enforcement should remain context-aware. A lexical match by itself cannot prove a spawn is unbounded.

A shared checker should therefore be advisory by default, print exact source locations, support narrow reviewed exceptions, and reserve strict/failing mode for repositories that have explicitly adopted the concurrency policy.

## Initial adoption: `zed-cli`

`zed-cli` is the first target because its native task runtime currently has a positive `--jobs` budget, bounded per-group scoped thread batches, a `Mutex + Condvar` child-command limiter, and synchronized task identity state, but it does not yet reuse a fixed worker pool with a bounded runnable queue.

The implementation tracker is https://github.com/zed-pkg/zed-cli/issues/472. The preliminary scheduler now additionally hardens extreme concurrency inputs, shutdown-vs-nested-work semantics, inline recursion depth, worker self-join prevention, poison recovery, and internal-worker-panic reporting before `TaskRuntime` integration.

## Review checklist

Before approving a new or changed concurrency subsystem, reviewers should be able to answer all of these from code/tests rather than inference:

- What is the maximum number of workers, including the absolute safety ceiling?
- What is the maximum queue length, and is that capacity eagerly reserved?
- What is the maximum number of child processes?
- What happens when the queue is full?
- What wakes blocked producers when admission closes?
- Can workers synchronously wait for jobs requiring the same workers?
- Can inline nested work exhaust the stack?
- Can a worker own the scheduler and attempt to join itself?
- What happens on panic/error/cancellation/poisoning?
- Who closes external admission and who is still allowed to submit nested drain work?
- Who joins workers and reaps children?
- Can any worker/process outlive the owning command?
- Are CLI/env/config concurrency values validated consistently and bounded absolutely?
- Does a large graph/input change only elapsed time, not the resource ceiling?
