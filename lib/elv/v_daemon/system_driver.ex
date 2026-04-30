defmodule Elv.VDaemon.SystemDriver do
  @moduledoc false

  @behaviour Elv.VDaemon.Driver

  defstruct [
    :mode,
    :v_path,
    :cwd,
    :tmp_dir,
    :port,
    :daemon_source_path,
    :daemon_executable_path,
    :live_source_path,
    :last_command,
    :last_output,
    :last_error,
    command_count: 0
  ]

  @control_prefix "__ELV__ "
  @default_timeout_ms 30_000

  @impl true
  def start(config) do
    state = %__MODULE__{
      mode: Map.fetch!(config, :mode),
      v_path: Map.fetch!(config, :v_path),
      cwd: Map.fetch!(config, :cwd),
      tmp_dir: Map.fetch!(config, :tmp_dir)
    }

    File.mkdir_p!(state.tmp_dir)

    case state.mode do
      :daemon -> start_eval_daemon(state, config)
      :plugin -> start_plugin_daemon(state, config)
      :live -> start_live_daemon(state, config)
      other -> {:error, "unknown V daemon mode: #{inspect(other)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def stop(%__MODULE__{} = state) do
    close_port(state)
    :ok
  end

  @impl true
  def build(%__MODULE__{mode: :plugin} = state, spec, opts) do
    plugins_dir = Path.join(state.tmp_dir, "plugins")
    File.mkdir_p!(plugins_dir)

    artifact_path =
      Path.join(plugins_dir, "elv_generation_#{spec.generation}" <> shared_library_extension())

    timeout_ms = Keyword.get(opts, :hot_build_timeout_ms, @default_timeout_ms)

    case run_v(state, ["-shared", "-o", artifact_path, spec.source_path], timeout_ms) do
      {:ok, output} ->
        artifact =
          spec
          |> Map.put(:artifact_path, artifact_path)
          |> Map.put(:build_output, output)

        {:ok, artifact, %{state | last_output: output, last_error: nil}}

      {:error, message} ->
        {:error, message, %{state | last_error: message}}
    end
  rescue
    error -> {:error, Exception.message(error), %{state | last_error: Exception.message(error)}}
  end

  def build(%__MODULE__{mode: :live} = state, spec, opts) do
    live_source_path = state.live_source_path || Path.join(state.tmp_dir, "elv_live_daemon.v")
    File.write!(live_source_path, spec.source)

    command = "generation #{spec.generation}"

    case command(state, command, Keyword.put(opts, :expect, command)) do
      {:ok, _message, state} ->
        artifact =
          spec
          |> Map.put(:artifact_path, live_source_path)
          |> Map.put(:source_path, live_source_path)

        {:ok, artifact, state}

      {:error, message, state} ->
        {:error, message, state}
    end
  rescue
    error -> {:error, Exception.message(error), %{state | last_error: Exception.message(error)}}
  end

  def build(%__MODULE__{mode: :daemon} = state, _spec, _opts) do
    message = "generation build is not supported by the authoritative daemon backend"
    {:error, message, %{state | last_error: message}}
  end

  @impl true
  def load(%__MODULE__{mode: :plugin} = state, artifact, opts) do
    symbol = Map.get(artifact, :symbol, "elv_generation_entry")

    command =
      [
        "load",
        artifact.generation,
        Base.encode64(artifact.artifact_path),
        Base.encode64(symbol)
      ]
      |> Enum.join(" ")

    case command(state, command, Keyword.put(opts, :expect, "load #{artifact.generation}")) do
      {:ok, message, state} ->
        {:ok, %{load_message: message, native_loaded?: true}, state}

      {:error, message, state} ->
        {:error, message, state}
    end
  end

  def load(%__MODULE__{mode: :live} = state, artifact, opts) do
    command = "activate #{artifact.generation}"

    case command(state, command, Keyword.put(opts, :expect, command)) do
      {:ok, message, state} ->
        {:ok, %{load_message: message, native_loaded?: true}, state}

      {:error, message, state} ->
        {:error, message, state}
    end
  end

  def load(%__MODULE__{mode: :daemon} = state, _artifact, _opts) do
    message = "generation load is not supported by the authoritative daemon backend"
    {:error, message, %{state | last_error: message}}
  end

  @impl true
  def unload(%__MODULE__{mode: :plugin} = state, record, opts) do
    command = "unload #{record.generation}"

    case command(state, command, Keyword.put(opts, :expect, command)) do
      {:ok, message, state} ->
        maybe_remove_file(Map.get(record, :artifact_path))
        {:ok, %{unload_message: message, native_unloaded?: true}, state}

      {:error, message, state} ->
        {:error, message, state}
    end
  end

  def unload(%__MODULE__{mode: :live} = state, record, _opts) do
    message =
      "v -live does not expose per-generation unload for generation #{record.generation}; recycle the daemon"

    {:error, message, %{state | last_error: message}}
  end

  def unload(%__MODULE__{mode: :daemon} = state, _record, _opts) do
    message = "generation unload is not supported by the authoritative daemon backend"
    {:error, message, %{state | last_error: message}}
  end

  @impl true
  def eval(%__MODULE__{mode: :daemon} = state, source, opts) do
    command = "eval " <> Base.encode64(source)

    case command(state, command, opts) do
      {:ok, "eval " <> payload, state} ->
        parse_eval_payload(payload, state)

      {:ok, message, state} ->
        {:error, "unexpected daemon eval response: #{message}", state}

      {:error, message, state} ->
        {:error, message, state}
    end
  end

  def eval(%__MODULE__{} = state, _source, _opts) do
    message = "eval is only supported by authoritative daemon mode"
    {:error, message, %{state | last_error: message}}
  end

  @impl true
  def reset(%__MODULE__{mode: :daemon} = state, opts) do
    case command(state, "reset", opts) do
      {:ok, "reset " <> payload, state} ->
        {:ok, %{message: payload}, state}

      {:ok, message, state} ->
        {:error, "unexpected daemon reset response: #{message}", state}

      {:error, message, state} ->
        {:error, message, state}
    end
  end

  def reset(%__MODULE__{} = state, _opts) do
    message = "reset is only supported by authoritative daemon mode"
    {:error, message, %{state | last_error: message}}
  end

  @impl true
  def snapshot(%__MODULE__{mode: :daemon} = state, opts) do
    case command(state, "snapshot", opts) do
      {:ok, "snapshot " <> payload, state} ->
        parse_snapshot_payload(payload, state)

      {:ok, message, state} ->
        {:error, "unexpected daemon snapshot response: #{message}", state}

      {:error, message, state} ->
        {:error, message, state}
    end
  end

  def snapshot(%__MODULE__{} = state, _opts) do
    message = "snapshot is only supported by authoritative daemon mode"
    {:error, message, %{state | last_error: message}}
  end

  @impl true
  def recycle(%__MODULE__{} = state, reason, opts) do
    state = close_port(state)

    case state.mode do
      :daemon ->
        with {:ok, state} <- start_eval_daemon(%{state | port: nil}, Map.new(opts)) do
          {:ok, %{recycle_message: reason}, state}
        end

      :plugin ->
        with {:ok, state} <- start_plugin_daemon(%{state | port: nil}, Map.new(opts)) do
          {:ok, %{recycle_message: reason}, state}
        end

      :live ->
        with {:ok, state} <- start_live_daemon(%{state | port: nil}, Map.new(opts)) do
          {:ok, %{recycle_message: reason}, state}
        end
    end
  end

  @impl true
  def metadata(%__MODULE__{} = state) do
    %{
      v_daemon_system_mode: state.mode,
      v_daemon_native_port?: is_port(state.port),
      v_daemon_source_path: state.daemon_source_path,
      v_daemon_executable_path: state.daemon_executable_path,
      v_daemon_live_source_path: state.live_source_path,
      v_daemon_command_count: state.command_count,
      v_daemon_last_command: state.last_command,
      v_daemon_last_output: state.last_output,
      v_daemon_system_last_error: state.last_error
    }
  end

  defp start_plugin_daemon(%__MODULE__{} = state, config) do
    daemon_dir = Path.join(state.tmp_dir, "daemon")
    File.mkdir_p!(daemon_dir)
    source_path = Path.join(daemon_dir, "elv_plugin_daemon.v")
    executable_path = Path.join(daemon_dir, "elv_plugin_daemon" <> executable_extension())

    File.write!(source_path, plugin_daemon_source())

    timeout_ms = Map.get(config, :daemon_build_timeout_ms, @default_timeout_ms)

    with {:ok, output} <- run_v(state, ["-o", executable_path, source_path], timeout_ms),
         {:ok, port} <- open_port(executable_path, [], state.cwd),
         state = %{
           state
           | port: port,
             daemon_source_path: source_path,
             daemon_executable_path: executable_path,
             last_output: output,
             last_error: nil
         } do
      {:ok, state}
    else
      {:error, message} -> {:error, message}
      {:error, message, _state} -> {:error, message}
    end
  end

  defp start_live_daemon(%__MODULE__{} = state, _config) do
    live_dir = Path.join(state.tmp_dir, "live")
    File.mkdir_p!(live_dir)
    source_path = Path.join(live_dir, "elv_live_daemon.v")
    File.write!(source_path, live_daemon_source([], [], []))

    with {:ok, port} <- open_port(state.v_path, ["-live", "run", source_path], state.cwd),
         state = %{state | port: port, live_source_path: source_path, last_error: nil} do
      {:ok, state}
    else
      {:error, message} -> {:error, message}
      {:error, message, _state} -> {:error, message}
    end
  end

  defp start_eval_daemon(%__MODULE__{} = state, config) do
    daemon_dir = Path.join(state.tmp_dir, "daemon")
    session_dir = Path.join(state.tmp_dir, "daemon_session")
    File.mkdir_p!(daemon_dir)
    File.mkdir_p!(session_dir)

    source_path = Path.join(daemon_dir, "elv_eval_daemon.v")
    executable_path = Path.join(daemon_dir, "elv_eval_daemon" <> executable_extension())

    File.write!(source_path, eval_daemon_source(state.v_path, session_dir))

    timeout_ms = Map.get(config, :daemon_build_timeout_ms, @default_timeout_ms)

    with {:ok, output} <- run_v(state, ["-o", executable_path, source_path], timeout_ms),
         {:ok, port} <- open_port(executable_path, [], state.cwd),
         state = %{
           state
           | port: port,
             daemon_source_path: source_path,
             daemon_executable_path: executable_path,
             last_output: output,
             last_error: nil
         },
         {:ok, _ready, state} <- read_control(state, @default_timeout_ms, "ready") do
      {:ok, state}
    else
      {:error, message} -> {:error, message}
      {:error, message, _state} -> {:error, message}
    end
  end

  defp command(%__MODULE__{} = state, command, opts) do
    timeout_ms = Keyword.get(opts, :daemon_timeout_ms, @default_timeout_ms)
    expect = Keyword.get(opts, :expect)

    if is_port(state.port) do
      Port.command(state.port, command <> "\n")

      state = %{
        state
        | last_command: command,
          command_count: state.command_count + 1
      }

      read_control(state, timeout_ms, expect)
    else
      {:error, "V daemon port is not running",
       %{state | last_error: "V daemon port is not running"}}
    end
  end

  defp read_control(state, timeout_ms, expect) do
    read_control(state, timeout_ms, [], expect)
  end

  defp read_control(state, timeout_ms, output, expect) do
    receive do
      {port, {:data, {:eol, line}}} when port == state.port ->
        line = IO.iodata_to_binary(line)

        if String.starts_with?(line, @control_prefix) do
          parse_control(line, state, output, timeout_ms, expect)
        else
          read_control(state, timeout_ms, [line | output], expect)
        end

      {port, {:data, {:noeol, line}}} when port == state.port ->
        read_control(state, timeout_ms, [IO.iodata_to_binary(line) | output], expect)

      {port, {:exit_status, status}} when port == state.port ->
        message = "V daemon exited with status #{status}"

        {:error, message,
         %{state | port: nil, last_output: join_output(output), last_error: message}}
    after
      timeout_ms ->
        message = "V daemon command timed out after #{timeout_ms} ms"
        {:error, message, %{state | last_output: join_output(output), last_error: message}}
    end
  end

  defp parse_control(line, state, output, timeout_ms, expect) do
    message = String.replace_prefix(line, @control_prefix, "")

    state = %{
      state
      | last_output: join_output(output),
        last_error: if(String.starts_with?(message, "error "), do: message, else: nil)
    }

    cond do
      String.starts_with?(message, "error ") ->
        {:error, String.replace_prefix(message, "error ", ""), state}

      is_binary(expect) and expected_control?(message, expect) ->
        {:ok, String.replace_prefix(message, "ok ", ""), state}

      is_binary(expect) ->
        read_control(state, timeout_ms, output, expect)

      message == "ok" ->
        {:ok, message, state}

      String.starts_with?(message, "ok ") ->
        {:ok, String.replace_prefix(message, "ok ", ""), state}

      true ->
        {:ok, message, state}
    end
  end

  defp expected_control?(message, expect) do
    message == "ok #{expect}" or message == expect
  end

  defp parse_eval_payload(payload, state) do
    case payload |> Base.decode64!() |> String.split("|", parts: 5) do
      [status_text, elapsed_text, stdout64, stderr64, source64] ->
        with {status, ""} <- Integer.parse(status_text),
             {elapsed_us, ""} <- Integer.parse(elapsed_text),
             {:ok, stdout} <- Base.decode64(stdout64),
             {:ok, stderr} <- Base.decode64(stderr64),
             {:ok, source} <- Base.decode64(source64) do
          {:ok,
           %{
             status: status,
             elapsed_us: elapsed_us,
             stdout: normalize_output(stdout),
             stderr: normalize_output(stderr),
             source: source
           }, state}
        else
          _ ->
            {:error, "invalid daemon eval payload",
             %{state | last_error: "invalid daemon eval payload"}}
        end

      _ ->
        {:error, "invalid daemon eval payload",
         %{state | last_error: "invalid daemon eval payload"}}
    end
  rescue
    error -> {:error, Exception.message(error), %{state | last_error: Exception.message(error)}}
  end

  defp parse_snapshot_payload(payload, state) do
    case Base.decode64(payload) do
      {:ok, source} ->
        {:ok, %{source: source}, state}

      :error ->
        {:error, "invalid daemon snapshot payload",
         %{state | last_error: "invalid daemon snapshot payload"}}
    end
  end

  defp open_port(executable, args, cwd) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:line, 65_536},
        {:args, args},
        {:cd, cwd}
      ])

    {:ok, port}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp run_v(state, args, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(state.v_path, args,
          cd: state.cwd,
          env: command_env(state.v_path),
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, normalize_output(output)}

      {:ok, {output, status}} ->
        {:error, "v exited with status #{status}\n#{normalize_output(output)}"}

      nil ->
        {:error, "v command timed out after #{timeout_ms} ms"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp close_port(%__MODULE__{port: port} = state) when is_port(port) do
    Port.command(port, "quit\n")

    receive do
      {^port, {:data, _data}} -> :ok
    after
      100 -> :ok
    end

    Port.close(port)
    %{state | port: nil}
  rescue
    _ -> %{state | port: nil}
  end

  defp close_port(state), do: state

  defp maybe_remove_file(path) when is_binary(path) do
    File.rm(path)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_remove_file(_path), do: :ok

  defp plugin_daemon_source do
    """
    module main

    import dl
    import encoding.base64
    import os

    struct LoadedGeneration {
      generation int
      path string
      handle voidptr
    }

    fn clean(text string) string {
      return text.replace('\\n', ' ').replace('\\r', ' ')
    }

    fn control(status string, message string) {
      println('#{@control_prefix}' + status + ' ' + clean(message))
    }

    fn unload_generation(mut loaded map[int]LoadedGeneration, generation int) bool {
      if generation in loaded {
        item := loaded[generation]
        dl.close(item.handle)
        loaded.delete(generation)
        return true
      }
      return false
    }

    fn main() {
      mut loaded := map[int]LoadedGeneration{}
      control('ok', 'ready')

      for {
        line := os.get_line()
        if line == '' {
          continue
        }

        parts := line.split(' ')
        command := parts[0]

        if command == 'ping' {
          control('ok', 'ping')
          continue
        }

        if command == 'quit' {
          for generation, _ in loaded {
            unload_generation(mut loaded, generation)
          }
          control('ok', 'quit')
          return
        }

        if command == 'load' {
          if parts.len < 3 {
            control('error', 'load expects generation and base64 path')
            continue
          }

          generation := parts[1].int()
          path := base64.decode_str(parts[2])
          symbol := if parts.len > 3 { base64.decode_str(parts[3]) } else { 'elv_generation_entry' }

          unload_generation(mut loaded, generation)
          handle := dl.open(path, dl.rtld_now | dl.rtld_local)
          if isnil(handle) {
            control('error', 'load failed: ' + dl.dlerror())
            continue
          }

          sym := dl.sym(handle, symbol)
          if isnil(sym) {
            dl.close(handle)
            control('error', 'missing symbol: ' + symbol + ' ' + dl.dlerror())
            continue
          }

          loaded[generation] = LoadedGeneration{
            generation: generation
            path: path
            handle: handle
          }
          control('ok', 'load ' + generation.str())
          continue
        }

        if command == 'unload' {
          if parts.len < 2 {
            control('error', 'unload expects generation')
            continue
          }

          generation := parts[1].int()
          if unload_generation(mut loaded, generation) {
            control('ok', 'unload ' + generation.str())
          } else {
            control('ok', 'unload-miss ' + generation.str())
          }
          continue
        }

        control('error', 'unknown command: ' + command)
      }
    }
    """
  end

  defp live_daemon_source(imports, declarations, body) do
    user_imports =
      imports
      |> Enum.reject(&(String.trim(&1) == "import os"))
      |> join_blocks()

    declarations = join_blocks(declarations)
    body = indent_body(body)

    """
    module main

    import os

    #{user_imports}

    #{declarations}

    @[live]
    fn elv_generation_entry() int {
    #{body}
        return 0
    }

    fn main() {
      println('#{@control_prefix}ok ready')

      for {
        line := os.get_line()
        if line == '' {
          continue
        }
        if line == 'quit' {
          println('#{@control_prefix}ok quit')
          return
        }
        if line.starts_with('ping') {
          println('#{@control_prefix}ok ping')
          continue
        }
        if line.starts_with('generation') || line.starts_with('activate') {
          println('#{@control_prefix}ok ' + line)
          continue
        }
        println('#{@control_prefix}error unknown command: ' + line)
      }
    }
    """
  end

  defp eval_daemon_source(v_path, session_dir) do
    v_path = escape_v_string(v_path)
    session_dir = escape_v_string(session_dir)

    """
    module main

    import encoding.base64
    import os
    import time

    const elv_v_path = '#{v_path}'
    const elv_session_dir = '#{session_dir}'
    const elv_control_prefix = '#{@control_prefix}'

    struct SessionState {
      imports []string
      declarations []string
      body []string
      previous_output string
      generation int
    }

    fn clean(text string) string {
      return text.replace('\\n', ' ').replace('\\r', ' ')
    }

    fn control(status string, message string) {
      println(elv_control_prefix + status + ' ' + clean(message))
      flush_stdout()
    }

    fn quote_arg(value string) string {
      return '"' + value.replace('"', '\\\\"') + '"'
    }

    fn join_blocks(items []string) string {
      mut text := ''
      for item in items {
        if item.trim_space() == '' {
          continue
        }
        if text != '' {
          text += '\\n\\n'
        }
        text += item
      }
      return text
    }

    fn indent_body(items []string) string {
      mut text := ''
      for item in items {
        for line in item.split('\\n') {
          text += '    ' + line + '\\n'
        }
      }
      return text
    }

    fn render_source(state SessionState) string {
      return 'module main\\n\\n' + join_blocks(state.imports) + '\\n\\n' +
        join_blocks(state.declarations) + '\\n\\nfn main() {\\n' + indent_body(state.body) + '}\\n'
    }

    fn delta(previous string, current string) string {
      if current.starts_with(previous) {
        return current[previous.len..]
      }
      return current
    }

    fn source_kind(source string) string {
      trimmed := source.trim_space()
      if trimmed.starts_with('import ') || trimmed.starts_with('import(') {
        return 'import'
      }
      for prefix in ['fn ', 'pub fn ', 'struct ', 'enum ', 'interface ', 'type ', 'const ', 'const(', '__global'] {
        if trimmed.starts_with(prefix) {
          return 'declaration'
        }
      }
      return 'execution'
    }

    fn is_statement(source string) bool {
      trimmed := source.trim_space()
      if trimmed.contains('println(') || trimmed.contains('print(') || trimmed.contains('panic(') {
        return true
      }
      for prefix in ['mut ', 'if ', 'for ', 'match ', 'assert ', 'defer ', 'return', 'break', 'continue', 'unsafe', 'lock ', 'rlock '] {
        if trimmed.starts_with(prefix) {
          return true
        }
      }
      return trimmed.contains(':=') || trimmed.contains(' +=') || trimmed.contains(' -=') ||
        trimmed.contains(' *=') || trimmed.contains(' /=') || trimmed.contains(' %=') ||
        trimmed.ends_with('++') || trimmed.ends_with('--')
    }

    fn is_obvious_statement(source string) bool {
      trimmed := source.trim_space()
      if trimmed.contains('println(') || trimmed.contains('print(') || trimmed.contains('panic(') {
        return true
      }
      for prefix in ['mut ', 'for ', 'assert ', 'defer ', 'return', 'break', 'continue', 'unsafe', 'lock ', 'rlock '] {
        if trimmed.starts_with(prefix) {
          return true
        }
      }
      return trimmed.contains(':=') || trimmed.contains(' +=') || trimmed.contains(' -=') ||
        trimmed.contains(' *=') || trimmed.contains(' /=') || trimmed.contains(' %=') ||
        trimmed.ends_with('++') || trimmed.ends_with('--')
    }

    fn trailing_expression_sequence(source string) ?[]string {
      trimmed := source.trim_space()
      if trimmed.contains(';') && !trimmed.contains('{') && !trimmed.contains('}') && !trimmed.contains('\\n') {
        raw_parts := trimmed.split(';')
        mut parts := []string{}
        for part in raw_parts {
          item := part.trim_space()
          if item != '' {
            parts << item
          }
        }
        if parts.len > 1 {
          tail := parts[parts.len - 1]
          if !is_statement(tail) && source_kind(tail) == 'execution' {
            mut forms := []string{}
            for i := 0; i < parts.len - 1; i++ {
              forms << parts[i]
            }
            forms << 'println(' + tail + ')'
            return forms
          }
        }
      }
      return none
    }

    fn execution_forms(source string, expression_first bool) []string {
      trimmed := source.trim_space()
      if forms := trailing_expression_sequence(trimmed) {
        return forms
      }
      if expression_first {
        return ['println(' + trimmed + ')']
      }
      if is_statement(trimmed) {
        return [trimmed]
      }
      return ['println(' + trimmed + ')']
    }

    fn candidate_state(state SessionState, source string, expression_first bool) SessionState {
      kind := source_kind(source)
      if kind == 'import' {
        mut imports := state.imports.clone()
        if source !in imports {
          imports << source
        }
        return SessionState{
          ...state
          imports: imports
        }
      }
      if kind == 'declaration' {
        mut declarations := state.declarations.clone()
        declarations << source
        return SessionState{
          ...state
          declarations: declarations
        }
      }
      mut body := state.body.clone()
      body << execution_forms(source, expression_first)
      return SessionState{
        ...state
        body: body
      }
    }

    fn run_once(state SessionState, source string, expression_first bool) (SessionState, string, int, int) {
      mut candidate := candidate_state(state, source, expression_first)
      candidate = SessionState{
        ...candidate
        generation: state.generation + 1
      }
      rendered := render_source(candidate)
      path := os.join_path(elv_session_dir, 'session_' + candidate.generation.str() + '.v')
      os.write_file(path, rendered) or {
        return state, err.msg(), 1, 0
      }
      started := time.now()
      result := os.execute(quote_arg(elv_v_path) + ' -w -n -nocolor run ' + quote_arg(path))
      elapsed_us := int(time.since(started).microseconds())
      if result.exit_code == 0 {
        output := result.output.replace('\\r\\n', '\\n')
        candidate = SessionState{
          ...candidate
          previous_output: output
        }
        return candidate, delta(state.previous_output, output), 0, elapsed_us
      }
      return state, result.output.replace('\\r\\n', '\\n'), result.exit_code, elapsed_us
    }

    fn run_candidate(state SessionState, source string) (SessionState, string, int, int) {
      kind := source_kind(source)
      if kind == 'import' || kind == 'declaration' || is_obvious_statement(source) {
        return run_once(state, source, false)
      }

      expr_state, expr_output, expr_status, expr_elapsed := run_once(state, source, true)
      if expr_status == 0 {
        return expr_state, expr_output, expr_status, expr_elapsed
      }

      stmt_state, stmt_output, stmt_status, stmt_elapsed := run_once(state, source, false)
      if stmt_status == 0 {
        return stmt_state, stmt_output, stmt_status, stmt_elapsed
      }

      return state, stmt_output, stmt_status, stmt_elapsed
    }

    fn encode_eval(status int, elapsed_us int, stdout string, stderr string, source string) string {
      payload := status.str() + '|' + elapsed_us.str() + '|' + base64.encode(stdout.bytes()) + '|' +
        base64.encode(stderr.bytes()) + '|' + base64.encode(source.bytes())
      return base64.encode(payload.bytes())
    }

    fn main() {
      os.mkdir_all(elv_session_dir) or {
        control('error', err.msg())
        return
      }
      mut state := SessionState{}
      control('ok', 'ready')

      for {
        line := os.get_line()
        if line == '' {
          continue
        }

        if line == 'quit' {
          control('ok', 'quit')
          return
        }

        if line == 'reset' {
          state = SessionState{}
          control('ok', 'reset ok')
          continue
        }

        if line == 'snapshot' {
          control('ok', 'snapshot ' + base64.encode(render_source(state).bytes()))
          continue
        }

        if line.starts_with('eval ') {
          encoded := line['eval '.len..]
          source := base64.decode_str(encoded)
          next_state, output, status, elapsed_us := run_candidate(state, source)
          if status == 0 {
            state = next_state
            control('ok', 'eval ' + encode_eval(status, elapsed_us, output, '', render_source(state)))
          } else {
            stderr := 'v exited with status ' + status.str() + '\\n' + output
            control('ok', 'eval ' + encode_eval(status, elapsed_us, '', stderr, render_source(state)))
          }
          continue
        }

        control('error', 'unknown command: ' + line)
      }
    }
    """
  end

  defp join_blocks(blocks), do: blocks |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

  defp indent_body([]), do: ""

  defp indent_body(forms) do
    forms
    |> Enum.join("\n")
    |> String.split("\n")
    |> Enum.map(&("    " <> &1))
    |> Enum.join("\n")
  end

  defp command_env(v_path) do
    path = System.get_env("PATH", "")
    sep = if windows?(), do: ";", else: ":"
    v_dir = Path.dirname(v_path)
    [{"PATH", v_dir <> sep <> path}, {"VQUIET", "1"}]
  end

  defp join_output([]), do: ""
  defp join_output(output), do: output |> Enum.reverse() |> Enum.join("\n")

  defp normalize_output(output), do: String.replace(output, "\r\n", "\n")

  defp escape_v_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  defp shared_library_extension do
    cond do
      windows?() -> ".dll"
      match?({:unix, :darwin}, :os.type()) -> ".dylib"
      true -> ".so"
    end
  end

  defp executable_extension do
    if windows?(), do: ".exe", else: ""
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end
end
