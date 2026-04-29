# Changelog

## 0.1.0 - 2026-04-30

Initial public release.

- Julia-style REPL shell for V: `?`, `;`, `]`, `@time`, `:load`, `:reset`, `:history`.
- Cross-machine V discovery via `--v`, `v.path`, environment variables, PATH, project-local toolchains, and common Windows/macOS/Linux install locations.
- Persistent V path setup with `elv config set v.path PATH` and `elv v use PATH`.
- Managed V bootstrap with `elv v install`, backed by the official `vlang/v` source repository.
- Diagnostic commands: `elv doctor`, `elv locate`, `elv v path`, and `:doctor`.
- Universal release layout with POSIX and Windows launchers.
