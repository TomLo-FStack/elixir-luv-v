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

  @impl true
  def recycle(%__MODULE__{} = state, reason, opts) do
    state = close_port(state)

    case state.mode do
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
