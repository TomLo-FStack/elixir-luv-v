defmodule Elv.CLI do
  @moduledoc false

  alias Elv.Config
  alias Elv.Engine
  alias Elv.Scanner
  alias Elv.VInstaller
  alias Elv.VLocator

  def main(argv) do
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
             {:ok, v} <- VLocator.resolve(path: opts[:v] || opts[:v_path], cwd: cwd) do
          {:ok,
           %{
             v: v,
             cwd: cwd,
             hard_timeout_ms: opts[:timeout] || 30_000,
             tmp_root: opts[:tmp_root],
             no_banner?: opts[:no_banner] || false
           }}
        end
    end
  end

  defp run_repl(config) do
    case Engine.start(config.v.path, config.cwd, tmp_root: config.tmp_root) do
      {:ok, engine} ->
        unless config.no_banner?, do: print_banner(engine, config)
        loop(engine, config, [])

      {:error, message} ->
        fail("Could not start #{Elv.short_name()}: #{message}", 1)
    end
  end

  defp loop(engine, config, history) do
    case read_form() do
      :eof ->
        Engine.close(engine)
        IO.puts("")

      {:command, :quit} ->
        Engine.close(engine)

      {:command, command} ->
        {engine, history} = handle_command(command, engine, config, history)
        loop(engine, config, history)

      {:code, code} ->
        timed? = String.starts_with?(String.trim_leading(code), "@time ")

        code =
          if timed?,
            do: String.trim_leading(code) |> String.replace_prefix("@time ", ""),
            else: code

        {engine, history} = eval_and_print(engine, config, code, history, timed?)
        loop(engine, config, history)
    end
  end

  defp read_form do
    case IO.gets(color(:cyan, "v> ")) do
      eof when eof in [nil, :eof] ->
        :eof

      line ->
        line = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")
        classify_first_line(line)
    end
  end

  defp classify_first_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        read_form()

      trimmed in ["exit", ":q", ":quit"] ->
        {:command, :quit}

      String.starts_with?(trimmed, ":") ->
        {:command, {:colon, trimmed}}

      String.starts_with?(trimmed, "?") ->
        {:command, {:help, String.trim_leading(trimmed, "?") |> String.trim()}}

      String.starts_with?(trimmed, ";") ->
        {:command, {:shell, String.trim_leading(trimmed, ";") |> String.trim()}}

      String.starts_with?(trimmed, "]") ->
        {:command, {:pkg, String.trim_leading(trimmed, "]") |> String.trim()}}

      Scanner.complete?(line) ->
        {:code, line}

      true ->
        read_continuation([line])
    end
  end

  defp read_continuation(lines) do
    case IO.gets(color(:light_black, "... ")) do
      eof when eof in [nil, :eof] ->
        {:code, Enum.reverse(lines) |> Enum.join("\n")}

      line ->
        line = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")
        lines = [line | lines]
        code = Enum.reverse(lines) |> Enum.join("\n")

        if Scanner.complete?(code) do
          {:code, code}
        else
          read_continuation(lines)
        end
    end
  end

  defp eval_and_print(engine, config, code, history, timed?) do
    history = history ++ [code]

    case Engine.eval(engine, code, hard_timeout_ms: config.hard_timeout_ms) do
      {:ok, output, elapsed_us, engine} ->
        print_output(output)
        if timed?, do: IO.puts(color(:light_black, "elapsed: #{format_time(elapsed_us)}"))
        {engine, history}

      {:error, message, engine} ->
        IO.puts(:stderr, color(:red, message))
        {engine, history}
    end
  end

  defp handle_command({:colon, line}, engine, config, history) do
    [command | rest] = String.split(String.trim_leading(line, ":"), ~r/\s+/, parts: 2)
    arg = rest |> List.first() |> Kernel.||("") |> String.trim()

    case command do
      "help" ->
        IO.puts(repl_help())
        {engine, history}

      "version" ->
        run_v(engine, ["version"])
        {engine, history}

      "vpath" ->
        IO.puts(engine.v_path)
        {engine, history}

      "doctor" ->
        print_session_doctor(engine, config)
        {engine, history}

      "pwd" ->
        IO.puts(engine.cwd)
        {engine, history}

      "clear" ->
        IO.write(IO.ANSI.clear() <> IO.ANSI.home())
        {engine, history}

      "history" ->
        print_history(history)
        {engine, history}

      "reset" ->
        case Engine.restart(engine, tmp_root: config.tmp_root) do
          {:ok, new_engine} ->
            IO.puts("session reset")
            {new_engine, history}

          {:error, message} ->
            IO.puts(:stderr, color(:red, "reset failed: #{message}"))
            {engine, history}
        end

      "load" ->
        load_file(arg, engine, config, history)

      "run" ->
        if arg == "" do
          IO.puts(:stderr, "usage: :run path/to/file.v [args...]")
        else
          {file, args} = split_command(arg)
          run_v(engine, ["run", file] ++ args)
        end

        {engine, history}

      "check" ->
        if arg == "",
          do: IO.puts(:stderr, "usage: :check path/to/file.v"),
          else: run_v(engine, [arg])

        {engine, history}

      "doc" ->
        if arg == "", do: IO.puts(:stderr, "usage: :doc topic"), else: run_v(engine, ["doc", arg])
        {engine, history}

      other ->
        IO.puts(:stderr, "unknown command :#{other}; use :help")
        {engine, history}
    end
  end

  defp handle_command({:help, ""}, engine, _config, history) do
    IO.puts(repl_help())
    {engine, history}
  end

  defp handle_command({:help, topic}, engine, _config, history) do
    run_v(engine, ["help", topic])
    {engine, history}
  end

  defp handle_command({:shell, ""}, engine, _config, history) do
    IO.puts(:stderr, "usage: ; command")
    {engine, history}
  end

  defp handle_command({:shell, command}, engine, _config, history) do
    {shell, args} = shell_command(command)
    {output, status} = System.cmd(shell, args, cd: engine.cwd, stderr_to_stdout: true)
    print_output(output)
    if status != 0, do: IO.puts(:stderr, color(:red, "shell exited with status #{status}"))
    {engine, history}
  rescue
    error ->
      IO.puts(:stderr, color(:red, Exception.message(error)))
      {engine, history}
  end

  defp handle_command({:pkg, ""}, engine, _config, history) do
    IO.puts("V package mode: ] install <module> | ] search <term> | ] update | ] list")
    {engine, history}
  end

  defp handle_command({:pkg, command}, engine, _config, history) do
    {subcommand, args} = split_command(command)

    case subcommand do
      cmd when cmd in ["install", "search", "update", "remove", "list", "outdated", "show"] ->
        run_v(engine, [cmd] ++ args)

      _ ->
        IO.puts(:stderr, "unknown V package command: #{subcommand}")
    end

    {engine, history}
  end

  defp load_file("", engine, _config, history) do
    IO.puts(:stderr, "usage: :load path/to/snippet.v")
    {engine, history}
  end

  defp load_file(path, engine, config, history) do
    path = Path.expand(path, engine.cwd)

    case File.read(path) do
      {:ok, code} ->
        code
        |> Engine.split_forms()
        |> Enum.reduce({engine, history}, fn form, {current_engine, current_history} ->
          eval_and_print(current_engine, config, form, current_history, false)
        end)

      {:error, reason} ->
        IO.puts(:stderr, color(:red, "could not read #{path}: #{:file.format_error(reason)}"))
        {engine, history}
    end
  end

  defp run_v(engine, args) do
    {output, status} = Engine.run_v(engine, args)
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
    case Engine.start(v_path, cwd) do
      {:ok, engine} ->
        result = Engine.eval(engine, "1 + 2")
        Engine.close(engine)

        case result do
          {:ok, "3\n", _elapsed, _engine} ->
            IO.puts("smoke: ok")

          {:ok, "3", _elapsed, _engine} ->
            IO.puts("smoke: ok")

          {:ok, output, _elapsed, _engine} ->
            IO.puts("smoke: unexpected output #{inspect(output)}")

          {:error, message, _engine} ->
            IO.puts(:stderr, color(:red, "smoke: #{message}"))
        end

      {:error, message} ->
        IO.puts(:stderr, color(:red, "smoke: #{message}"))
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

  defp print_banner(engine, config) do
    IO.puts("""
    #{Elv.product_name()} #{Elv.version()}  |  #{config.v.version}
    short:   #{Elv.short_name()} / elv
    backend: #{engine.v_path}
    source:  #{config.v.source}
    cwd:     #{engine.cwd}
    tmp:     #{engine.tmp_dir}
    Type :help for commands, :vpath for the active V path, :quit to exit.
    timeout: #{config.hard_timeout_ms} ms
    """)
  end

  defp print_session_doctor(engine, config) do
    IO.puts("#{Elv.product_name()} #{Elv.version()}")
    IO.puts("backend: #{engine.v_path}")
    IO.puts("source:  #{config.v.source}")
    IO.puts("cwd:     #{engine.cwd}")
    IO.puts("tmp:     #{engine.tmp_dir}")
    run_v(engine, ["version"])
  end

  defp repl_help do
    """
    Commands:
      :help                  show this help
      :quit                  exit
      :reset                 restart the V session
      :version               print V version
      :vpath                 show the active V executable
      :doctor                show session diagnostics
      :history               show submitted V forms
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
      elv repl [--v PATH] [--cwd DIR] [--timeout MS] [--tmp-root DIR]

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

  defp normalize_cwd(nil), do: {:ok, File.cwd!()}

  defp normalize_cwd(path) do
    path = Path.expand(path)

    if File.dir?(path) do
      {:ok, path}
    else
      {:error, "Working directory does not exist: #{path}"}
    end
  end

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
