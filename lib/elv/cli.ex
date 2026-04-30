defmodule Elv.CLI do
  @moduledoc false

  alias Elv.Config
  alias Elv.EditorServer
  alias Elv.SessionServer
  alias Elv.SessionSupervisor
  alias Elv.VInstaller
  alias Elv.VLocator

  def main(argv) do
    ensure_started()

    case argv do
      [] -> repl([])
      ["repl" | rest] -> repl(rest)
      ["doctor" | rest] -> doctor(rest)
      ["locate" | rest] -> locate(rest)
      ["setup" | rest] -> setup(rest)
      ["v" | rest] -> v_command(rest)
      ["config" | rest] -> config(rest)
      ["version"] -> IO.puts("#{Elv.product_name()} #{Elv.version()}")
      ["help"] -> IO.puts(usage())
      ["--help"] -> IO.puts(usage())
      ["-h"] -> IO.puts(usage())
      [first | _] when is_binary(first) -> maybe_repl_or_unknown(first, argv)
      [unknown | _] -> fail("Unknown command: #{unknown}\n\n#{usage()}", 2)
    end
  end

  defp maybe_repl_or_unknown(first, argv) do
    if String.starts_with?(first, "-") do
      repl(argv)
    else
      fail("Unknown command: #{first}\n\n#{usage()}", 2)
    end
  end

  defp repl(args) do
    case parse_repl_args(args) do
      {:help, text} ->
        IO.puts(text)

      {:error, message} ->
        fail(message, 2)

      {:ok, config} ->
        run_repl(config)
    end
  end

  defp parse_repl_args(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        switches: [
          help: :boolean,
          v: :string,
          v_path: :string,
          cwd: :string,
          timeout: :integer,
          tmp_root: :string,
          snapshot_root: :string,
          backend: :string,
          lsp: :boolean,
          lsp_command: :string,
          worker_recycle_after: :integer,
          hot_generation_retention: :integer,
          hot_recycle_after_generations: :integer,
          no_snapshots: :boolean,
          no_banner: :boolean
        ],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        {:help, repl_usage()}

      invalid != [] ->
        {:error, "Unknown option: #{inspect(invalid)}\n\n#{repl_usage()}"}

      true ->
        with {:ok, cwd} <- normalize_cwd(opts[:cwd]),
             {:ok, backend} <- normalize_backend(opts[:backend]),
             {:ok, v} <- VLocator.resolve(path: opts[:v] || opts[:v_path], cwd: cwd) do
          {:ok,
           %{
             v: v,
             cwd: cwd,
             backend: backend,
             backend_name: opts[:backend] || "replay",
             hard_timeout_ms: opts[:timeout] || 30_000,
             tmp_root: opts[:tmp_root],
             snapshot_root: opts[:snapshot_root],
             snapshots?: not (opts[:no_snapshots] || false),
             lsp?: opts[:lsp] || false,
             lsp_command: opts[:lsp_command],
             worker_recycle_after: opts[:worker_recycle_after],
             hot_generation_retention: opts[:hot_generation_retention],
             hot_recycle_after_generations: opts[:hot_recycle_after_generations],
             no_banner?: opts[:no_banner] || false
           }}
        end
    end
  end

  defp run_repl(config) do
    session_config = %{
      v_path: config.v.path,
      cwd: config.cwd,
      backend: config.backend,
      hot_reload_mode: hot_reload_mode(config.backend_name),
      tmp_root: config.tmp_root,
      snapshot_root: config.snapshot_root,
      snapshots?: config.snapshots?,
      lsp?: config.lsp?,
      lsp_command: config.lsp_command,
      worker_recycle_after: config.worker_recycle_after,
      hot_generation_retention: config.hot_generation_retention,
      hot_recycle_after_generations: config.hot_recycle_after_generations
    }

    case SessionSupervisor.start_session(session_config) do
      {:ok, session} ->
        case EditorServer.start_link() do
          {:ok, editor} ->
            unless config.no_banner?, do: print_banner(session, config)
            loop(session, editor, config)

          {:error, reason} ->
            SessionServer.close(session)
            fail("Could not start editor: #{inspect(reason)}", 1)
        end

      {:error, message} ->
        fail("Could not start #{Elv.short_name()}: #{inspect(message)}", 1)
    end
  end

  defp loop(session, editor, config) do
    case read_form(editor) do
      :eof ->
        SessionServer.close(session)
        EditorServer.close(editor)
        IO.puts("")

      {:command, :quit} ->
        SessionServer.close(session)
        EditorServer.close(editor)

      {:command, command} ->
        session = handle_command(command, session, editor, config)
        loop(session, editor, config)

      {:code, code} ->
        timed? = String.starts_with?(String.trim_leading(code), "@time ")

        code =
          if timed?,
            do: String.trim_leading(code) |> String.replace_prefix("@time ", ""),
            else: code

        session = eval_and_print(session, editor, config, code, timed?)
        loop(session, editor, config)
    end
  end

  defp read_form(editor) do
    case IO.gets(prompt(editor)) do
      eof when eof in [nil, :eof] ->
        case EditorServer.flush(editor) do
          :empty -> :eof
          {:code, code} -> {:code, code}
        end

      line ->
        case EditorServer.submit_line(editor, line) do
          :blank -> read_form(editor)
          :incomplete -> read_form(editor)
          {:ready, {:command, command}} -> {:command, command}
          {:ready, {:code, code}} -> {:code, code}
        end
    end
  end

  defp prompt(editor) do
    if EditorServer.buffering?(editor) do
      color(:light_black, "... ")
    else
      color(:cyan, "v> ")
    end
  end

  defp eval_and_print(session, editor, config, code, timed?) do
    EditorServer.record(editor, code)

    case SessionServer.eval(session, code, hard_timeout_ms: config.hard_timeout_ms) do
      {:ok, output, elapsed_us, session} ->
        print_output(output)
        if timed?, do: IO.puts(color(:light_black, "elapsed: #{format_time(elapsed_us)}"))
        session

      {:error, message, session} ->
        IO.puts(:stderr, color(:red, message))
        session
    end
  end

  defp handle_command({:colon, line}, session, editor, config) do
    [command | rest] = String.split(String.trim_leading(line, ":"), ~r/\s+/, parts: 2)
    arg = rest |> List.first() |> Kernel.||("") |> String.trim()

    case command do
      "help" ->
        IO.puts(repl_help())
        session

      "version" ->
        run_v(session, ["version"])
        session

      "vpath" ->
        IO.puts(session_metadata(session).v_path)
        session

      "doctor" ->
        print_session_doctor(session, config)
        session

      "capabilities" ->
        print_capabilities(session_metadata(session))
        session

      "snapshots" ->
        print_snapshots(session_metadata(session))
        session

      "diagnostics" ->
        print_diagnostics(SessionServer.diagnostics(session))
        session

      "complete" ->
        complete(arg, session)
        session

      "crashes" ->
        print_crashes(session)
        session

      "pwd" ->
        IO.puts(session_metadata(session).cwd)
        session

      "clear" ->
        IO.write(IO.ANSI.clear() <> IO.ANSI.home())
        session

      "history" ->
        print_history(EditorServer.history(editor))
        session

      "search" ->
        if arg == "",
          do: IO.puts(:stderr, "usage: :search query"),
          else: print_search(EditorServer.search(editor, arg))

        session

      "reset" ->
        case SessionServer.restart(session, tmp_root: config.tmp_root) do
          :ok ->
            IO.puts("session reset")
            session

          {:error, message} ->
            IO.puts(:stderr, color(:red, "reset failed: #{message}"))
            session
        end

      "recover" ->
        case SessionServer.recover_latest(session, hard_timeout_ms: config.hard_timeout_ms) do
          {:ok, count, skipped, elapsed_us, _session} ->
            IO.puts(
              "recovered #{count} form(s), skipped #{skipped} side-effecting form(s) in #{format_time(elapsed_us)}"
            )

            session

          {:error, message, _session} ->
            IO.puts(:stderr, color(:red, "recover failed: #{message}"))
            session
        end

      "load" ->
        load_file(arg, session, editor, config)

      "run" ->
        if arg == "" do
          IO.puts(:stderr, "usage: :run path/to/file.v [args...]")
        else
          {file, args} = split_command(arg)
          run_v(session, ["run", file] ++ args)
        end

        session

      "check" ->
        if arg == "",
          do: IO.puts(:stderr, "usage: :check path/to/file.v"),
          else: run_v(session, [arg])

        session

      "doc" ->
        if arg == "",
          do: IO.puts(:stderr, "usage: :doc topic"),
          else: run_v(session, ["doc", arg])

        session

      other ->
        IO.puts(:stderr, "unknown command :#{other}; use :help")
        session
    end
  end

  defp handle_command({:help, ""}, session, _editor, _config) do
    IO.puts(repl_help())
    session
  end

  defp handle_command({:help, topic}, session, _editor, _config) do
    run_v(session, ["help", topic])
    session
  end

  defp handle_command({:shell, ""}, session, _editor, _config) do
    IO.puts(:stderr, "usage: ; command")
    session
  end

  defp handle_command({:shell, command}, session, _editor, _config) do
    {shell, args} = shell_command(command)

    {output, status} =
      System.cmd(shell, args, cd: session_metadata(session).cwd, stderr_to_stdout: true)

    print_output(output)
    if status != 0, do: IO.puts(:stderr, color(:red, "shell exited with status #{status}"))
    session
  rescue
    error ->
      IO.puts(:stderr, color(:red, Exception.message(error)))
      session
  end

  defp handle_command({:pkg, ""}, session, _editor, _config) do
    IO.puts("V package mode: ] install <module> | ] search <term> | ] update | ] list")
    session
  end

  defp handle_command({:pkg, command}, session, _editor, _config) do
    {subcommand, args} = split_command(command)

    case subcommand do
      cmd when cmd in ["install", "search", "update", "remove", "list", "outdated", "show"] ->
        run_v(session, [cmd] ++ args)

      _ ->
        IO.puts(:stderr, "unknown V package command: #{subcommand}")
    end

    session
  end

  defp load_file("", session, _editor, _config) do
    IO.puts(:stderr, "usage: :load path/to/snippet.v")
    session
  end

  defp load_file(path, session, editor, config) do
    path = Path.expand(path, session_metadata(session).cwd)

    case File.read(path) do
      {:ok, code} ->
        SessionServer.split_forms(session, code)
        |> Enum.reduce(session, fn form, current_session ->
          eval_and_print(current_session, editor, config, form, false)
        end)

      {:error, reason} ->
        IO.puts(:stderr, color(:red, "could not read #{path}: #{:file.format_error(reason)}"))
        session
    end
  end

  defp run_v(session, args) do
    {output, status} = SessionServer.run_v(session, args)
    print_output(output)
    if status != 0, do: IO.puts(:stderr, color(:red, "v exited with status #{status}"))
  end

  defp doctor(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        switches: [
          v: :string,
          v_path: :string,
          cwd: :string,
          timeout: :integer,
          verbose: :boolean
        ],
        aliases: [h: :help]
      )

    cond do
      invalid != [] ->
        fail("Unknown option: #{inspect(invalid)}", 2)

      true ->
        cwd = opts[:cwd] || File.cwd!()
        config = Config.read()
        explicit = opts[:v] || opts[:v_path]

        IO.puts("#{Elv.product_name()} #{Elv.version()} doctor")
        IO.puts("os:     #{inspect(:os.type())}")
        IO.puts("elixir: #{System.version()} / OTP #{:erlang.system_info(:otp_release)}")
        IO.puts("cwd:    #{Path.expand(cwd)}")
        IO.puts("config: #{Config.path()}")

        case Map.get(config, "v.path") do
          nil -> IO.puts("v.path: (not set)")
          path -> IO.puts("v.path: #{path}")
        end

        case VLocator.resolve(path: explicit, cwd: cwd, timeout_ms: opts[:timeout] || 5_000) do
          {:ok, found} ->
            IO.puts("v:      #{found.path}")
            IO.puts("source: #{found.source}")
            IO.puts("version: #{found.version}")
            smoke_test(found.path, cwd)

          {:error, message} ->
            IO.puts(:stderr, color(:red, message))
            System.halt(1)
        end

        IO.puts("")

        IO.puts(
          "Candidates#{if opts[:verbose], do: "", else: " (use --verbose for all PATH checks)"}:"
        )

        candidates =
          VLocator.inspect_candidates(
            path: explicit,
            cwd: cwd,
            timeout_ms: opts[:timeout] || 5_000
          )

        candidates
        |> doctor_candidates(opts[:verbose] || false)
        |> Enum.each(&print_candidate/1)
    end
  end

  defp doctor_candidates(candidates, true), do: Enum.take(candidates, 60)

  defp doctor_candidates(candidates, false) do
    candidates
    |> Enum.filter(fn candidate ->
      candidate.status == :ok or
        String.starts_with?(candidate.source, "cli") or
        String.starts_with?(candidate.source, "config") or
        String.starts_with?(candidate.source, "env")
    end)
    |> case do
      [] ->
        [
          %{
            source: "hint",
            path: "run `elv v install` or `elv doctor --verbose`",
            status: :error,
            error: "no visible candidates"
          }
        ]

      visible ->
        visible
    end
  end

  defp locate(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args, switches: [v: :string, v_path: :string, cwd: :string])

    if invalid != [] do
      fail("Unknown option: #{inspect(invalid)}", 2)
    end

    cwd = opts[:cwd] || File.cwd!()

    case VLocator.resolve(path: opts[:v] || opts[:v_path], cwd: cwd) do
      {:ok, found} ->
        IO.puts(found.path)

      {:error, message} ->
        fail(message, 1)
    end
  end

  defp setup(args) do
    {opts, rest, invalid} = OptionParser.parse(args, switches: [v: :string, v_path: :string])

    cond do
      invalid != [] ->
        fail("Unknown option: #{inspect(invalid)}", 2)

      true ->
        path = opts[:v] || opts[:v_path] || Enum.join(rest, " ")

        if String.trim(path) == "" do
          fail("usage: elv setup /absolute/path/to/v", 2)
        end

        set_v_path(path)
    end
  end

  defp v_command(args) do
    case args do
      [] ->
        IO.puts(v_usage())

      ["path" | rest] ->
        locate(rest)

      ["doctor" | rest] ->
        doctor(rest)

      ["use" | rest] ->
        setup(rest)

      ["set" | rest] ->
        setup(rest)

      ["install" | rest] ->
        install_v(rest)

      ["update" | rest] ->
        update_v(rest)

      ["managed-dir"] ->
        IO.puts(VInstaller.default_install_dir())

      ["help"] ->
        IO.puts(v_usage())

      ["--help"] ->
        IO.puts(v_usage())

      [unknown | _] ->
        fail("Unknown v command: #{unknown}\n\n#{v_usage()}", 2)
    end
  end

  defp install_v(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        switches: [
          dir: :string,
          force: :boolean,
          no_config: :boolean,
          branch: :string,
          timeout: :integer
        ]
      )

    if invalid != [], do: fail("Unknown option: #{inspect(invalid)}", 2)

    IO.puts("Installing V from https://github.com/vlang/v")
    IO.puts("target: #{opts[:dir] || VInstaller.default_install_dir()}")

    case VInstaller.install(
           dir: opts[:dir],
           force: opts[:force] || false,
           no_config: opts[:no_config] || false,
           branch: opts[:branch],
           timeout_ms: opts[:timeout] || 600_000
         ) do
      {:ok, result} ->
        print_output(result.log)
        IO.puts("installed: #{result.path}")
        IO.puts(result.version)
        if result.configured?, do: IO.puts("saved v.path=#{result.path}")

      {:error, message} ->
        fail(message, 1)
    end
  end

  defp update_v(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        switches: [dir: :string, no_config: :boolean, timeout: :integer]
      )

    if invalid != [], do: fail("Unknown option: #{inspect(invalid)}", 2)

    case VInstaller.update(
           dir: opts[:dir],
           no_config: opts[:no_config] || false,
           timeout_ms: opts[:timeout] || 600_000
         ) do
      {:ok, result} ->
        print_output(result.log)
        IO.puts("updated: #{result.path}")
        IO.puts(result.version)
        if result.configured?, do: IO.puts("saved v.path=#{result.path}")

      {:error, message} ->
        fail(message, 1)
    end
  end

  defp config(args) do
    case args do
      [] ->
        print_config()

      ["path"] ->
        IO.puts(Config.path())

      ["get"] ->
        print_config()

      ["get", key] ->
        key = normalize_config_key(key)
        IO.puts(Config.get(key) || "")

      ["set", key | value_parts] ->
        key = normalize_config_key(key)
        value = Enum.join(value_parts, " ")

        case key do
          "v.path" -> set_v_path(value)
          _ -> Config.set(key, value)
        end

      ["unset", key] ->
        key = normalize_config_key(key)
        Config.unset(key)
        IO.puts("unset #{key}")

      _ ->
        fail(config_usage(), 2)
    end
  end

  defp set_v_path(path) do
    if String.trim(path) == "" do
      fail("usage: elv config set v.path /absolute/path/to/v", 2)
    end

    case VLocator.resolve(path: path, config: %{}, explicit_only: true) do
      {:ok, found} ->
        Config.set("v.path", found.path)
        IO.puts("saved v.path=#{found.path}")
        IO.puts(found.version)

      {:error, message} ->
        fail(message, 1)
    end
  end

  defp print_config do
    config = Config.read()
    IO.puts("config: #{Config.path()}")

    if map_size(config) == 0 do
      IO.puts("(empty)")
    else
      config
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.each(fn {key, value} -> IO.puts("#{key}=#{value}") end)
    end
  end

  defp smoke_test(v_path, cwd) do
    case SessionServer.start_link(%{v_path: v_path, cwd: cwd, tmp_root: nil}) do
      {:ok, session} ->
        result = SessionServer.eval(session, "1 + 2")
        metadata = session_metadata(session)
        SessionServer.close(session)

        case result do
          {:ok, "3\n", _elapsed, _session} ->
            IO.puts("smoke: ok")

          {:ok, "3", _elapsed, _session} ->
            IO.puts("smoke: ok")

          {:ok, output, _elapsed, _session} ->
            IO.puts("smoke: unexpected output #{inspect(output)}")

          {:error, message, _session} ->
            IO.puts(:stderr, color(:red, "smoke: #{message}"))
        end

        IO.puts("backend: #{metadata.backend}")
        IO.puts("tmp root: #{metadata.tmp_root}")
        IO.puts("snapshots: #{format_snapshots(metadata)}")
        IO.puts("checkpoint: #{metadata.snapshot_count}")
        IO.puts("last compile/run: #{format_optional_time(metadata.last_eval_us)}")

      {:error, message} ->
        IO.puts(:stderr, color(:red, "smoke: #{inspect(message)}"))
    end
  end

  defp print_candidate(candidate) do
    status =
      case candidate.status do
        :ok -> "ok #{candidate.version}"
        :error -> "skip #{candidate.error}"
      end

    IO.puts("  #{candidate.source}: #{candidate.path} [#{status}]")
  end

  defp print_banner(session, config) do
    metadata = session_metadata(session)

    IO.puts("""
    #{Elv.product_name()} #{Elv.version()}  |  #{config.v.version}
    short:   #{Elv.short_name()} / elv
    backend: #{metadata.backend}
    v:       #{metadata.v_path}
    source:  #{config.v.source}
    cwd:     #{metadata.cwd}
    tmp:     #{metadata.tmp_dir}
    Type :help for commands, :vpath for the active V path, :quit to exit.
    timeout: #{config.hard_timeout_ms} ms
    """)
  end

  defp print_session_doctor(session, config) do
    metadata = session_metadata(session)

    IO.puts("#{Elv.product_name()} #{Elv.version()}")
    IO.puts("session: #{metadata.session_id}")
    IO.puts("started: #{metadata.started_at}")
    IO.puts("backend: #{metadata.backend}")
    IO.puts("v:       #{metadata.v_path}")
    IO.puts("source:  #{config.v.source}")
    IO.puts("cwd:     #{metadata.cwd}")
    IO.puts("tmp root: #{metadata.tmp_root}")
    IO.puts("tmp:     #{metadata.tmp_dir}")
    IO.puts("snapshots: #{format_snapshots(metadata)}")
    IO.puts("checkpoint count: #{metadata.snapshot_count}")
    IO.puts("lsp: #{format_lsp(metadata)}")

    if metadata.snapshot_last_path,
      do: IO.puts("latest checkpoint: #{metadata.snapshot_last_path}")

    if metadata.snapshot_last_error,
      do: IO.puts("snapshot error: #{metadata.snapshot_last_error}")

    IO.puts("generation: #{metadata.generation}")

    if Map.has_key?(metadata, :build_cache_entries) do
      IO.puts(
        "build cache: entries=#{metadata.build_cache_entries} hits=#{metadata.build_cache_hits} misses=#{metadata.build_cache_misses}"
      )

      if metadata.last_source_path, do: IO.puts("last source: #{metadata.last_source_path}")
    end

    if Map.has_key?(metadata, :worker_alive?),
      do: IO.puts("worker alive: #{metadata.worker_alive?}")

    if metadata[:worker_pid], do: IO.puts("worker pid: #{metadata.worker_pid}")

    if metadata[:worker_backend],
      do: IO.puts("worker backend: #{inspect(metadata.worker_backend)}")

    if metadata[:worker_recycle_after],
      do: IO.puts("worker recycle after: #{metadata.worker_recycle_after} eval(s)")

    if metadata[:worker_recycle_count],
      do: IO.puts("worker recycles: #{metadata.worker_recycle_count}")

    if metadata[:last_worker_recycle],
      do: IO.puts("last worker recycle: #{inspect(metadata.last_worker_recycle)}")

    if metadata[:hot_reload],
      do: IO.puts("hot reload: #{metadata.hot_reload} #{metadata.hot_reload_reason}")

    if metadata[:hot_last_error],
      do: IO.puts("hot reload error: #{String.trim(metadata.hot_last_error)}")

    if metadata[:v_daemon] == :enabled do
      IO.puts(
        "v daemon: mode=#{metadata.v_daemon_mode} loaded=#{metadata.v_daemon_loaded_generation_count} active=#{metadata.v_daemon_active_generation} loads=#{metadata.v_daemon_load_count} unloads=#{metadata.v_daemon_unload_count} recycles=#{metadata.v_daemon_recycle_count}"
      )
    else
      if Map.has_key?(metadata, :v_daemon),
        do: IO.puts("v daemon: #{metadata.v_daemon} #{metadata[:v_daemon_last_error] || ""}")
    end

    if metadata[:v_daemon_last_recycle],
      do: IO.puts("last v daemon recycle: #{inspect(metadata.v_daemon_last_recycle)}")

    if metadata[:capabilities],
      do: IO.puts("capabilities: #{format_capabilities(metadata.capabilities)}")

    IO.puts(
      "forms: imports=#{metadata.imports} declarations=#{metadata.declarations} body=#{metadata.body_forms}"
    )

    IO.puts(
      "evals: #{metadata.eval_count} errors=#{metadata.error_count} crashes=#{metadata.crash_count} timeouts=#{metadata.timeout_count}"
    )

    IO.puts("last compile/run: #{format_optional_time(metadata.last_eval_us)}")
    IO.puts("recoveries: #{metadata.recovery_count}")
    IO.puts("last recovery: #{format_optional_time(metadata.last_recovery_us)}")

    if not is_nil(metadata.last_replayed_count) do
      IO.puts(
        "last recovery plan: replayed=#{metadata.last_replayed_count} skipped=#{metadata.last_skipped_count}"
      )
    end

    IO.puts("total compile/run: #{format_time(metadata.total_eval_us)}")
    if metadata.last_error, do: IO.puts("last error: #{String.trim(metadata.last_error)}")
    run_v(session, ["version"])
  end

  defp print_crashes(session) do
    metadata = session_metadata(session)

    IO.puts("crashes: #{metadata.crash_count}")
    IO.puts("timeouts: #{metadata.timeout_count}")
    IO.puts("errors: #{metadata.error_count}")
    IO.puts("last error: #{metadata.last_error || "(none)"}")
  end

  defp print_capabilities(%{capabilities: capabilities}) do
    capabilities
    |> Enum.sort_by(fn {name, _enabled?} -> Atom.to_string(name) end)
    |> Enum.each(fn {name, enabled?} ->
      IO.puts("#{name}: #{if enabled?, do: "yes", else: "no"}")
    end)
  end

  defp print_capabilities(_metadata), do: IO.puts("(no capability metadata)")

  defp print_snapshots(metadata) do
    IO.puts("snapshots: #{format_snapshots(metadata)}")
    IO.puts("checkpoint count: #{metadata.snapshot_count}")

    if metadata.snapshot_last_path,
      do: IO.puts("latest checkpoint: #{metadata.snapshot_last_path}")

    if metadata.last_replayed_count do
      IO.puts("last replayed: #{metadata.last_replayed_count}")
      IO.puts("last skipped: #{metadata.last_skipped_count}")
    end
  end

  defp complete("", _session) do
    IO.puts(:stderr, "usage: :complete source-prefix")
  end

  defp complete(source, session) do
    line = source |> String.split("\n") |> length() |> Kernel.-(1)
    character = source |> String.split("\n") |> List.last() |> String.length()

    case SessionServer.complete(session, source, line, character) do
      {:ok, result} ->
        print_completion(result)

      {:disabled, reason} ->
        IO.puts(:stderr, "LSP disabled: #{reason}")

      {:error, message} ->
        IO.puts(:stderr, color(:red, "completion failed: #{message}"))
    end
  end

  defp print_diagnostics({:disabled, reason}) do
    IO.puts("LSP disabled: #{reason}")
  end

  defp print_diagnostics([]), do: IO.puts("(no diagnostics)")

  defp print_diagnostics(diagnostics) when is_list(diagnostics) do
    Enum.each(diagnostics, fn diagnostic ->
      range = Map.get(diagnostic, "range", %{})
      start = Map.get(range, "start", %{})
      line = Map.get(start, "line", 0) + 1
      character = Map.get(start, "character", 0) + 1
      severity = Map.get(diagnostic, "severity", "?")
      message = Map.get(diagnostic, "message", inspect(diagnostic))

      IO.puts("#{line}:#{character} [#{severity}] #{message}")
    end)
  end

  defp print_diagnostics(diagnostics) when is_map(diagnostics) do
    diagnostics
    |> Enum.flat_map(fn {_uri, items} -> items end)
    |> print_diagnostics()
  end

  defp print_completion(%{"items" => items}) when is_list(items),
    do: print_completion_items(items)

  defp print_completion(items) when is_list(items), do: print_completion_items(items)
  defp print_completion(_result), do: IO.puts("(no completions)")

  defp print_completion_items([]), do: IO.puts("(no completions)")

  defp print_completion_items(items) do
    items
    |> Enum.take(20)
    |> Enum.each(fn item ->
      label = Map.get(item, "label", inspect(item))
      detail = Map.get(item, "detail")

      if detail do
        IO.puts("#{label}\t#{detail}")
      else
        IO.puts(label)
      end
    end)
  end

  defp repl_help do
    """
    Commands:
      :help                  show this help
      :quit                  exit
      :reset                 restart the V session
      :recover               restore the latest source-level checkpoint
      :crashes               show crash and timeout counters
      :version               print V version
      :vpath                 show the active V executable
      :doctor                show session diagnostics
      :capabilities          show current backend capability flags
      :snapshots             show checkpoint and replay-plan details
      :diagnostics           show latest LSP diagnostics when --lsp is enabled
      :complete <source>     ask LSP for completions at the end of source
      :history               show submitted V forms
      :search <query>        search submitted V forms
      :load <file.v>         load a V snippet into the current session
      :run <file.v> [args]   run a V file outside the session
      :check <file.v>        compile-check a V file
      :doc <topic>           run v doc <topic>
      :pwd                   show working directory
      :clear                 clear the screen

    Julia-style shortcuts:
      ?topic                 run v help topic
      ;command               run a shell command
      ] install <module>     run V package commands
      @time <expr-or-block>  evaluate and print elapsed wall time

    V path setup:
      elv config set v.path /absolute/path/to/v
      elv --v /absolute/path/to/v
      V_EXE=/absolute/path/to/v elv
    """
  end

  defp usage do
    """
    #{Elv.product_name()} #{Elv.version()}

    Usage:
      elv [repl options]
      elv repl [options]
      elv doctor [--v PATH]
      elv locate [--v PATH]
      elv setup PATH
      elv v install [--dir DIR]
      elv v use PATH
      elv config get [key]
      elv config set v.path PATH
      elv config unset v.path
      elv version

    Run `elv repl --help` for REPL options.
    """
  end

  defp v_usage do
    """
    Usage:
      elv v path [--v PATH]        print the active V executable
      elv v doctor [--v PATH]      show V diagnostics
      elv v use PATH               save v.path after validating it
      elv v install [options]      clone and build official vlang/v into ELV's data dir
      elv v update [options]       update an ELV-managed V checkout
      elv v managed-dir            print the default managed V directory

    Install options:
      --dir DIR                    install V into DIR
      --force                      replace an ELV-managed install directory
      --branch BRANCH              install a specific vlang/v branch or tag
      --no-config                  install without saving v.path
      --timeout MS                 build timeout, default 600000

    Default managed V directory:
      #{VInstaller.default_install_dir()}
    """
  end

  defp repl_usage do
    """
    Usage:
      elv repl [--v PATH] [--cwd DIR] [--timeout MS] [--tmp-root DIR] [--snapshot-root DIR] [--backend replay|worker|live|plugin] [--worker-recycle-after N] [--hot-generation-retention N] [--hot-recycle-after-generations N] [--lsp] [--lsp-command PATH] [--no-snapshots]

    V lookup order:
      1. --v / --v-path
      2. global config v.path
      3. ELV_V_PATH, V_EXE, V_PATH, VROOT, V_HOME, VLANG_HOME
      4. PATH
      5. common install locations and project-local tools/v
    """
  end

  defp config_usage do
    """
    Usage:
      elv config get [key]
      elv config set v.path PATH
      elv config unset v.path
      elv config path
    """
  end

  defp ensure_started do
    case Application.ensure_all_started(:elv) do
      {:ok, _apps} -> :ok
      {:error, {:already_started, _app}} -> :ok
      {:error, {:elv, {:already_started, _pid}}} -> :ok
      {:error, reason} -> fail("Could not start #{Elv.short_name()}: #{inspect(reason)}", 1)
    end
  end

  defp session_metadata(session), do: SessionServer.metadata(session)

  defp format_snapshots(%{snapshots: :disabled}), do: "disabled"

  defp format_snapshots(%{snapshots: :enabled, snapshot_root: root}) when is_binary(root),
    do: root

  defp format_snapshots(%{snapshot_root: root}) when is_binary(root), do: root
  defp format_snapshots(_metadata), do: "unknown"

  defp format_lsp(%{lsp: :enabled, lsp_command: command}), do: "enabled #{command}"
  defp format_lsp(%{lsp: :disabled, lsp_last_error: reason}), do: "disabled #{reason}"
  defp format_lsp(%{lsp: other}), do: inspect(other)
  defp format_lsp(_metadata), do: "unknown"

  defp format_capabilities(capabilities) do
    capabilities
    |> Enum.sort_by(fn {name, _enabled?} -> Atom.to_string(name) end)
    |> Enum.map(fn {name, enabled?} -> "#{name}=#{enabled?}" end)
    |> Enum.join(" ")
  end

  defp format_optional_time(nil), do: "(none)"
  defp format_optional_time(us), do: format_time(us)

  defp normalize_cwd(nil), do: {:ok, File.cwd!()}

  defp normalize_cwd(path) do
    path = Path.expand(path)

    if File.dir?(path) do
      {:ok, path}
    else
      {:error, "Working directory does not exist: #{path}"}
    end
  end

  defp normalize_backend(nil), do: {:ok, Elv.Engine}
  defp normalize_backend(""), do: {:ok, Elv.Engine}
  defp normalize_backend("replay"), do: {:ok, Elv.Engine}
  defp normalize_backend("worker"), do: {:ok, Elv.WorkerBackend}
  defp normalize_backend("live"), do: {:ok, Elv.HotReloadBackend}
  defp normalize_backend("plugin"), do: {:ok, Elv.HotReloadBackend}

  defp normalize_backend(other),
    do: {:error, "Unknown backend: #{other}; expected replay, worker, live, or plugin"}

  defp hot_reload_mode("plugin"), do: :plugin
  defp hot_reload_mode(_backend_name), do: :live

  defp split_command(command) do
    parts = String.split(command, ~r/\s+/, trim: true)

    case parts do
      [] -> {"", []}
      [head | tail] -> {head, tail}
    end
  end

  defp shell_command(command) do
    if match?({:win32, _}, :os.type()) do
      {System.get_env("ComSpec") || "cmd.exe", ["/c", command]}
    else
      {System.get_env("SHELL") || "sh", ["-c", command]}
    end
  end

  defp normalize_config_key(key) do
    case String.downcase(key) do
      key when key in ["v.path", "v-path", "v_path", "v"] -> "v.path"
      other -> other
    end
  end

  defp print_history([]), do: IO.puts("(empty)")

  defp print_history(history) do
    history
    |> Enum.with_index(1)
    |> Enum.each(fn {item, index} ->
      item = String.replace(item, "\n", "\n      ")
      IO.puts("#{String.pad_leading(Integer.to_string(index), 4)}  #{item}")
    end)
  end

  defp print_search([]), do: IO.puts("(no matches)")

  defp print_search(matches) do
    Enum.each(matches, fn %{index: index, source: source} ->
      source = String.replace(source, "\n", "\n      ")
      IO.puts("#{String.pad_leading(Integer.to_string(index), 4)}  #{source}")
    end)
  end

  defp print_output(""), do: :ok
  defp print_output(output), do: IO.puts(String.trim_trailing(output))

  defp format_time(us) when us < 1_000, do: "#{us} us"
  defp format_time(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 3)} ms"
  defp format_time(us), do: "#{Float.round(us / 1_000_000, 3)} s"

  defp color(color, text) do
    if IO.ANSI.enabled?() do
      [apply(IO.ANSI, color, []), text, IO.ANSI.reset()] |> IO.iodata_to_binary()
    else
      text
    end
  end

  defp fail(message, status) do
    IO.puts(:stderr, message)
    System.halt(status)
  end
end
