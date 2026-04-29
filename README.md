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

1. Download `elixir-luv-v-0.1.0-universal.zip` or `.tar.gz` from the GitHub release.
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
:version               print V version
:vpath                 show active V executable
:doctor                show session diagnostics
:history               show submitted V forms
:load file.v           load a V snippet
:run file.v [args]     run a V file outside the session
:check file.v          compile-check a V file
:doc topic             run v doc topic
?topic                 run v help topic
;command               run a shell command
] install module       run V package commands
@time expr             evaluate and print elapsed wall time
```

## How It Works

V is a compiled language, not a dynamic interpreter. ELV keeps a session model in Elixir, renders it into a temporary V program, runs `v run`, and prints only the new output suffix. Deterministic snippets feel stateful; code with side effects may run again when the session is replayed.

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
