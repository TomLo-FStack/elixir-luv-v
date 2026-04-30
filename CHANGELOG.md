# Changelog

## 0.3.0 - 2026-05-01

- Added `elv repl --backend daemon` for authoritative source-level execution through a long-running V daemon, with replay degradation diagnostics.
- Added front fast-path freezing diagnostics so `:doctor` shows `front_fast`, frozen reason, pending sync count, and native fallback count.
- Kept the Engine-internal fast evaluator synchronized with authoritative session state while freezing only the speculative CLI front path after native fallback.
- Added semicolon sequence handling for forms like `mut counter := 1; counter += 2; counter` across replay, hot-load rendering, and daemon execution.
- Added replay fallback synchronization after daemon eval failure so successful daemon history is replayed before fallback continues.
- Added replay-vs-daemon fallback benchmarking with median/p95 output and V compile-bound labeling.

## 0.2.0 - 2026-04-30

- Started the v0.2 runtime foundation: ELV now boots as an OTP application with a dynamic session supervisor.
- Moved the replay evaluator behind an execution backend behaviour so future live/plugin/worker backends can share the same session surface.
- Added a SessionServer for runtime metadata, history ownership, restart handling, evaluation timing, timeout counts, and crash accounting.
- Expanded session diagnostics with backend, temp root, snapshot status, generation, form counts, and compile/run timing details.
- Added source-level checkpoint files with deterministic/side-effecting form tracking.
- Added `:recover` for latest-checkpoint replay and `:crashes` for visible crash/timeout counters.
- Added a supervised disposable worker backend, exposed with `elv repl --backend worker`.
- Added worker crash replacement tests so the session process survives a crashed execution worker.
- Started the v0.3 editor layer with an EditorServer for multiline input buffering, submitted-form history, and `:search`.
- Added a shared form classifier and BuildServer foundation for generated-source caching and future live/plugin backends.
- Added optional LSP client plumbing with JSON-RPC framing plus `:diagnostics` and `:complete` hooks for `elv repl --lsp`.
- Added explicit checkpoint replay plans so recovery reports replayed and skipped side-effecting forms.
- Added automatic crash recovery from checkpoints and worker recycle policy support with replay restore.
- Added real `VDaemon`-backed `live` and `plugin` backend entry points with generation-specific artifacts, load/unload tracking, recycle policy, capability diagnostics, and replay fallback.
- Added `:capabilities` and `:snapshots` commands for inspecting backend support and recovery state.

## 0.1.0 - 2026-04-30

Initial public release.

- Julia-style REPL shell for V: `?`, `;`, `]`, `@time`, `:load`, `:reset`, `:history`.
- Cross-machine V discovery via `--v`, `v.path`, environment variables, PATH, project-local toolchains, and common Windows/macOS/Linux install locations.
- Persistent V path setup with `elv config set v.path PATH` and `elv v use PATH`.
- Managed V bootstrap with `elv v install`, backed by the official `vlang/v` source repository.
- Diagnostic commands: `elv doctor`, `elv locate`, `elv v path`, and `:doctor`.
- Universal release layout with POSIX and Windows launchers.
