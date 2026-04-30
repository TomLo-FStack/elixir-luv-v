# Elixir Luv V

**ELV** is a polished third-party REPL shell for V, written in Elixir. It gives V a Julia-style command surface without hiding the compiler underneath.

```text
v> 1 + 2
3
v> import math
v> @time math.sqrt(81)
9.0
elapsed: 820.114 ms
v> ;git status --short
v> ?run
```

## Install

ELV ships as a universal escript package. The package embeds Elixir code, but it still needs Erlang/OTP's `escript` command on PATH.

1. Download `elixir-luv-v-0.3.0-universal.zip` or `.tar.gz` from the GitHub release.
2. Unpack it.
3. Add the unpacked `bin` directory to PATH.
4. Run:

```sh
elv doctor
```

From source:

```sh
git clone https://github.com/TomLo-FStack/elixir-luv-v.git
cd elixir-luv-v
mix escript.build
escript ./elv doctor
```

## V Setup

ELV does not bundle V in the default package. That is intentional: the default package stays small, transparent, and respects the V version already selected by the user or project.

Lookup order:

1. `--v PATH` or `--v-path PATH`
2. saved config `v.path`
3. `ELV_V_PATH`, `V_EXE`, `V_PATH`, `VROOT`, `V_HOME`, `VLANG_HOME`
4. `PATH`
5. project-local `tools/v`, `vendor/v`, `.v`, `v`
6. common Windows, macOS, and Linux install locations

If V is already installed:

```sh
elv v use /absolute/path/to/v
elv doctor
elv
```

On Windows, paths like this work:

```powershell
elv v use E:\v_go_ds50_benchmark\tools\v\v.exe
```

On macOS, ELV checks the common Homebrew and local source locations automatically, including:

```text
/opt/homebrew/bin/v
/usr/local/bin/v
/opt/local/bin/v
~/v
~/.v
```

If V is not installed:

```sh
elv v install
```

That command clones the official `vlang/v` repository into ELV's managed data directory, builds V, validates `v version`, then saves `v.path`. It requires `git` and the normal build tools for your platform.

Managed V commands:

```sh
elv v install            # install official vlang/v into ELV's data dir
elv v update             # git pull + rebuild managed V
elv v managed-dir        # show where managed V is stored
elv v use PATH           # save a specific V executable
elv v path               # print the active V executable
```

## REPL Commands

```text
:help                  show REPL help
:quit                  exit
:reset                 restart the session
:recover               restore replay-safe forms from the latest checkpoint
:crashes               show crash and timeout counters
:version               print V version
:vpath                 show active V executable
:doctor                show session diagnostics
:capabilities          show backend capability flags
:snapshots             show checkpoint and replay-plan details
:diagnostics           show latest LSP diagnostics when LSP is enabled
:complete source       ask LSP for completions at the end of source
:history               show submitted V forms
:search query          search submitted V forms
:load file.v           load a V snippet
:run file.v [args]     run a V file outside the session
:check file.v          compile-check a V file
:doc topic             run v doc topic
?topic                 run v help topic
;command               run a shell command
] install module       run V package commands
@time expr             evaluate and print elapsed wall time
```

Worker-isolated execution can be enabled with:

```sh
elv repl --backend worker
elv repl --backend worker --worker-recycle-after 100
```

The authoritative native daemon backend can be enabled with:

```sh
elv repl --backend daemon
```

This starts a long-running V control process for source-level session execution. If it is unavailable, ELV reports the degradation in `:doctor` and uses replay execution as the authoritative backend.

Hot-load backends can be enabled with:

```sh
elv repl --backend live
elv repl --backend plugin
elv repl --backend plugin --hot-generation-retention 2 --hot-recycle-after-generations 50
```

These modes start a supervised `VDaemon`, compile generation-specific V artifacts, and manage load/unload/recycle policy without overwriting an already-loaded library. Replay execution remains authoritative for REPL output and checkpoint recovery; the hot-load path is reported separately in `:doctor` so native generation status is visible.

Optional V language-server hooks can be enabled when `v-analyzer` is installed:

```sh
elv repl --lsp
```

## How It Works

V is a compiled language, not a dynamic interpreter. ELV runs as an OTP application: a supervised session server owns source-level checkpoints and runtime metadata, while an editor server owns the active input buffer and searchable submitted-form history. The replay backend asks a build server to render and cache generated V source files, runs `v run`, and prints only the new output suffix. Optional LSP hooks talk JSON-RPC to a V language server for diagnostics and completion without making that server a required dependency. The optional worker backend runs the evaluator behind a supervised disposable worker process, so worker crashes can be counted, replaced, automatically recovered from checkpoints, and proactively recycled. The daemon backend keeps a long-running V control process as the authoritative native session executor. The optional live/plugin backend starts a V daemon and loads generation-specific native artifacts while keeping replay as the recovery-safe source of truth. Deterministic snippets feel stateful; code with side effects are tracked in each checkpoint replay plan so recovery can report what it replayed and what it skipped.

## North Star

ELV's long-term direction is a supervised hot-reload sandbox: Elixir owns the session, supervision, LSP integration, diagnostics, build cache, and crash recovery; V owns fast native compilation and execution.

The current release is the portable baseline. The planned architecture is documented in [ARCHITECTURE.md](ARCHITECTURE.md).

## Bundled V Policy

The default release is **ELV Slim** and does not include V.

Reasons:

- Users and projects often need a specific V version.
- Bundling a compiler makes each release platform-specific and much larger.
- Security updates should come from the upstream V toolchain, not be silently frozen inside a REPL wrapper.
- Package managers and CI systems already have established ways to provide compilers.

The supported fallback for machines without V is `elv v install`. Optional `with-v` release bundles can be added later per platform, but they should remain separate assets from the default package.

## License

MIT
