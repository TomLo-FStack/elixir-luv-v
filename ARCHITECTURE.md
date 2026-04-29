# Architecture North Star

Elixir Luv V should grow from a polished REPL wrapper into a supervised hot-reload sandbox for V.

The target is not "pretend V is dynamic". The target is a high-integrity interactive runtime where Elixir owns supervision, editing, diagnostics, process lifecycle, and state recovery while V keeps fast native compilation and execution.

## Product Shape

```text
terminal/editor
  |
  v
Elixir host
  |-- Line editor / multiline buffer
  |-- LSP client for V intelligence
  |-- Session supervisor
  |-- Snapshot store
  |-- Build cache
  |-- V worker registry
  |
  +--> V state daemon
  |
  +--> V execution worker(s)
        |
        +--> hot-loaded V plugin generations
```

## Hard Truths

Native crashes change the rules.

If user code corrupts memory or segfaults inside a V process, that exact process image cannot be trusted. A supervisor can restart it, but it cannot magically preserve arbitrary stack frames, raw pointers, file descriptors, allocator internals, and mutated native heap state in a portable way.

The recoverable design is:

- keep the REPL contract in Elixir;
- treat V workers as disposable native execution sandboxes;
- store recoverable session state in explicit snapshots;
- replay declarations and deterministic operations when needed;
- prefer serialized or structured state boundaries over raw native pointers;
- restart crashed workers under supervision and rebuild from the latest safe checkpoint.

That can feel seamless to the user, but it is engineered recovery, not resurrection of corrupted memory.

## V Capabilities To Build On

V has an official hot code reloading path through `@[live]` functions and `v -live`, where marked functions are compiled into a shared library and reloaded at runtime. The same official documentation notes an important constraint: runtime type changes are not supported in that mode.

References:

- V hot code reloading: https://docs.vlang.io/other-v-features.html#hot-code-reloading
- V language server direction: https://github.com/vlang/v-analyzer

ELV should use these capabilities where they fit, but not couple the product to only one backend. The architecture should allow multiple execution strategies:

- replay backend: current safe baseline, simple and portable;
- `v -live` backend: fast function-level hot reload where type layouts stay stable;
- plugin backend: generated shared libraries loaded by a long-running V daemon;
- worker backend: isolated native process per risky execution, with snapshot restore.

## Supervision Model

Elixir should become the runtime owner.

Suggested supervision tree:

```text
Elv.Application
  Elv.SessionSupervisor
    Elv.SessionServer
      Elv.EditorServer
      Elv.LspClient
      Elv.BuildServer
      Elv.SnapshotStore
      Elv.VDaemon
      Elv.WorkerSupervisor
```

Responsibilities:

- `SessionServer`: owns user-visible session state, history, command routing, and recovery policy.
- `EditorServer`: owns input buffer, bracket-aware multiline editing, history search, and future terminal UI.
- `LspClient`: speaks JSON-RPC to `v-analyzer` or another V language server and returns completion, diagnostics, hover, and symbol data.
- `BuildServer`: maps submitted forms to generated V modules, caches source hashes, and schedules compilation.
- `SnapshotStore`: persists recoverable session state and metadata.
- `VDaemon`: long-running V state process for safe hot-load paths.
- `WorkerSupervisor`: starts disposable V workers for execution that may crash.

## State Model

Variables must not be only C stack locals in generated `main`.

Future ELV should lower user forms into a session state model:

```text
user input
  -> parse/classify
  -> declaration table
  -> expression wrapper
  -> state read/write plan
  -> generated V module/plugin
```

Possible state tiers:

- `Tier 0`: replay history, current implementation.
- `Tier 1`: snapshot source-level bindings and replay from checkpoints.
- `Tier 2`: generated V session struct with stable ABI fields.
- `Tier 3`: typed value registry with serialization for safe worker boundaries.
- `Tier 4`: native heap arenas with explicit checkpoint hooks for advanced users.

The product should default to safe tiers and let users opt into lower-level native persistence.

## Hot Loading Plan

The clean plugin path is:

1. Generate a stable host ABI.
2. Compile each increment as a unique shared library.
3. Load it into a V daemon or worker.
4. Call a known entry function, passing a session pointer or serialized state.
5. Store the returned state delta.
6. Never overwrite a loaded library file; use generation IDs.
7. Let old generations age out by process restart, which is simpler and more portable than trying to unload code on every platform.

On Windows, DLL replacement and unloading semantics are stricter than Unix-like systems. Generation-specific filenames and periodic worker recycling are the safer cross-platform baseline.

## LSP And UX

The REPL should eventually behave more like a small IDE than a terminal prompt:

- bracket-aware multiline editing;
- history search and structured cells;
- syntax highlighting from incremental parse;
- diagnostics as the user types;
- completions from a V language server;
- `:explain` for compiler diagnostics;
- clickable source spans in capable terminals;
- `:profile` and `@time` that separate compile time, load time, and run time.

The host should be an LSP client, not a replacement for the V language server ecosystem.

## Failure Recovery

Crash recovery should be visible in architecture, not patched around later.

When a V worker exits abnormally:

1. Elixir marks the current generation as poisoned.
2. The worker supervisor starts a fresh worker.
3. The session server restores from the latest safe snapshot.
4. Declarations and state deltas are replayed or reloaded.
5. The prompt resumes with a compact diagnostic.

The user experience can be quiet by default, but `:doctor` and `:crashes` should expose the facts.

## Roadmap

### v0.2: Runtime Foundation

- Convert CLI into an OTP application with a session supervisor.
- Move current replay engine behind an execution behavior.
- Add crash accounting and structured session metadata.
- Add `:doctor` details for backend, temp roots, snapshots, and compile timings.

### v0.3: Editor Intelligence

- Add a proper multiline editor abstraction.
- Add optional LSP client integration.
- Surface diagnostics and completion hooks.
- Keep fallback mode dependency-free.

### v0.4: Snapshot Backend

- Add checkpoint files.
- Add source-level replay snapshots.
- Track deterministic and side-effecting forms separately.
- Add recovery tests for killed workers.

### v0.5: Hot Reload Backend

- Prototype V `@[live]` backend for stable function reloads.
- Prototype generated shared-library plugins.
- Add generation IDs, build cache, and worker recycling.

### v1.0: Supervised Hot-Reload Sandbox

- Supervised sessions.
- LSP-powered editing.
- Snapshot recovery.
- Safe default execution backend.
- Optional hot-load backend for compatible code.
- Clear user-facing semantics for state, side effects, native crashes, and type-layout changes.
