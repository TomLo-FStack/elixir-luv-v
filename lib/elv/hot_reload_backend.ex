defmodule Elv.HotReloadBackend do
  @moduledoc false

  @behaviour Elv.ExecutionBackend

  alias Elv.Form

  defstruct [
    :mode,
    :fallback,
    :daemon,
    :tmp_dir,
    :v_path,
    :cwd,
    :imports,
    :decls,
    :body,
    :hot_status,
    :hot_reason,
    :hot_load_count,
    :hot_load_error_count,
    :hot_generation,
    :last_hot_load,
    :last_hot_error
  ]

  @impl true
  def start(v_path, cwd, opts \\ []) do
    mode = normalize_mode(Keyword.get(opts, :hot_reload_mode, :live))
    fallback = Keyword.get(opts, :fallback_backend, Elv.Engine)
    tmp_dir = make_tmp_dir(Keyword.get(opts, :tmp_root), mode)
    daemon_driver = Keyword.get(opts, :v_daemon_driver, Elv.VDaemon.SystemDriver)

    case fallback.start(v_path, cwd, opts) do
      {:ok, fallback_state} ->
        {daemon, hot_status, hot_reason, last_hot_error} =
          start_daemon(v_path, cwd, tmp_dir, mode, daemon_driver, opts)

        {:ok,
         %__MODULE__{
           mode: mode,
           fallback: {fallback, fallback_state},
           daemon: daemon,
           tmp_dir: tmp_dir,
           v_path: v_path,
           cwd: cwd,
           imports: [],
           decls: [],
           body: [],
           hot_status: hot_status,
           hot_reason: hot_reason,
           hot_load_count: 0,
           hot_load_error_count: if(is_nil(last_hot_error), do: 0, else: 1),
           hot_generation: 0,
           last_hot_error: last_hot_error
         }}

      {:error, message} ->
        File.rm_rf(tmp_dir)
        {:error, message}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def close(%__MODULE__{fallback: {fallback, fallback_state}} = state) do
    if is_pid(state.daemon), do: Elv.VDaemon.close(state.daemon)
    fallback.close(fallback_state)
    if is_binary(state.tmp_dir), do: File.rm_rf(state.tmp_dir)
    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def restart(%__MODULE__{fallback: {fallback, fallback_state}} = state, opts \\ []) do
    restart_opts = Keyword.put_new(opts, :tmp_root, Path.dirname(state.tmp_dir))

    with {:ok, fallback_state} <- fallback.restart(fallback_state, restart_opts) do
      close_daemon(state.daemon)

      {daemon, hot_status, hot_reason, last_hot_error} =
        start_daemon(
          state.v_path,
          state.cwd,
          state.tmp_dir,
          state.mode,
          Keyword.get(opts, :v_daemon_driver, Elv.VDaemon.SystemDriver),
          opts
        )

      {:ok,
       %__MODULE__{
         state
         | daemon: daemon,
           fallback: {fallback, fallback_state},
           imports: [],
           decls: [],
           body: [],
           hot_status: hot_status,
           hot_reason: hot_reason,
           hot_load_count: 0,
           hot_load_error_count: if(is_nil(last_hot_error), do: 0, else: 1),
           hot_generation: 0,
           last_hot_load: nil,
           last_hot_error: last_hot_error
       }}
    else
      {:error, message} ->
        {:error, message}
    end
  end

  @impl true
  def eval(%__MODULE__{fallback: {fallback, fallback_state}} = state, code, opts \\ []) do
    code = String.trim(code)

    case fallback.eval(fallback_state, code, opts) do
      {:ok, output, elapsed_us, fallback_state} ->
        state =
          state
          |> update_forms(code)
          |> maybe_hot_load(code, opts)
          |> Map.put(:fallback, {fallback, fallback_state})

        {:ok, output, elapsed_us, state}

      {:error, message, fallback_state} ->
        {:error, message, %{state | fallback: {fallback, fallback_state}}}
    end
  end

  @impl true
  def run_v(%__MODULE__{fallback: {fallback, fallback_state}}, args, opts \\ []) do
    fallback.run_v(fallback_state, args, opts)
  end

  @impl true
  def split_forms(code), do: Elv.Engine.split_forms(code)

  @impl true
  def metadata(%__MODULE__{fallback: {fallback, fallback_state}} = state) do
    fallback_metadata = fallback.metadata(fallback_state)

    {daemon_metadata, daemon_alive?} =
      case daemon_metadata(state) do
        {:ok, metadata} -> {metadata, true}
        {:error, message} -> {%{v_daemon: :disabled, v_daemon_last_error: message}, false}
      end

    fallback_metadata
    |> Map.merge(daemon_metadata)
    |> Map.merge(%{
      backend: state.mode,
      fallback_backend: fallback,
      hot_reload: state.hot_status,
      hot_reload_reason: state.hot_reason,
      hot_load_count: state.hot_load_count,
      hot_load_error_count: state.hot_load_error_count,
      hot_last_load: state.last_hot_load,
      hot_last_error: state.last_hot_error,
      hot_generation_strategy: :unique_artifacts,
      hot_recycle_strategy: :retention_and_threshold,
      capabilities: %{
        replay: true,
        worker_isolation: false,
        lsp: false,
        snapshots: true,
        live_reload: state.mode == :live and daemon_alive?,
        plugins: state.mode == :plugin and daemon_alive?
      }
    })
  end

  defp update_forms(%__MODULE__{} = state, ""), do: state

  defp update_forms(%__MODULE__{} = state, code) do
    case Form.classify(code) do
      :import ->
        %{state | imports: Enum.uniq(state.imports ++ [code])}

      :declaration ->
        %{state | decls: state.decls ++ [code]}

      :execution ->
        %{state | body: state.body ++ body_form(code)}
    end
  end

  defp maybe_hot_load(state, "", _opts), do: state

  defp maybe_hot_load(%__MODULE__{daemon: daemon} = state, code, opts) when is_pid(daemon) do
    spec =
      state
      |> generation_spec(code)
      |> write_generation_source!()

    case safe_daemon_call(fn -> Elv.VDaemon.load_generation(daemon, spec, opts) end) do
      {:ok, {:ok, load}} ->
        %{
          state
          | hot_status: :enabled,
            hot_reason: hot_reason(state.mode),
            hot_load_count: state.hot_load_count + 1,
            hot_generation: load.generation,
            last_hot_load: summarize_load(load),
            last_hot_error: nil
        }

      {:ok, {:error, message}} ->
        %{
          state
          | hot_status: :degraded,
            hot_reason: "hot load failed; replay backend remains authoritative",
            hot_load_error_count: state.hot_load_error_count + 1,
            last_hot_error: message
        }

      {:exit, reason} ->
        message = "V daemon exited: #{format_reason(reason)}"

        %{
          state
          | daemon: nil,
            hot_status: :degraded,
            hot_reason: "V daemon exited; replay backend remains authoritative",
            hot_load_error_count: state.hot_load_error_count + 1,
            last_hot_error: message
        }
    end
  rescue
    error ->
      %{
        state
        | hot_status: :degraded,
          hot_reason: "hot load failed; replay backend remains authoritative",
          hot_load_error_count: state.hot_load_error_count + 1,
          last_hot_error: Exception.message(error)
      }
  end

  defp maybe_hot_load(state, _code, _opts), do: state

  defp generation_spec(%__MODULE__{} = state, code) do
    source = render_hot_source(state)
    source_sha256 = Form.sha256(source)
    generation = state.hot_generation + 1

    %{
      mode: state.mode,
      generation: generation,
      source: source,
      source_sha256: source_sha256,
      source_form_sha256: Form.sha256(code),
      symbol: "elv_generation_entry",
      tmp_dir: state.tmp_dir
    }
  end

  defp write_generation_source!(
         %{tmp_dir: tmp_dir, generation: generation, source: source} = spec
       ) do
    source_dir = Path.join(tmp_dir, "sources")
    File.mkdir_p!(source_dir)

    path =
      case spec.mode do
        :plugin -> Path.join(source_dir, "elv_generation_#{generation}.v")
        :live -> Path.join(source_dir, "elv_live_generation_#{generation}.v")
      end

    File.write!(path, source)
    Map.put(spec, :source_path, path)
  end

  defp render_hot_source(%__MODULE__{mode: :plugin} = state) do
    imports_text = join_blocks(state.imports)
    decls_text = join_blocks(state.decls)
    body_text = indent_body(state.body)

    """
    module main

    #{imports_text}

    #{decls_text}

    @[export: 'elv_generation_entry']
    pub fn elv_generation_entry() int {
    #{body_text}
        return 0
    }
    """
  end

  defp render_hot_source(%__MODULE__{mode: :live} = state) do
    imports_text =
      state.imports
      |> Enum.reject(&(String.trim(&1) == "import os"))
      |> join_blocks()

    decls_text = join_blocks(state.decls)
    body_text = indent_body(state.body)

    """
    module main

    import os

    #{imports_text}

    #{decls_text}

    @[live]
    fn elv_generation_entry() int {
    #{body_text}
        return 0
    }

    fn main() {
        println("__ELV__ ok ready")

        for {
            line := os.get_line()
            if line == "" {
                continue
            }
            if line == "quit" {
                println("__ELV__ ok quit")
                return
            }
            if line.starts_with("ping") {
                println("__ELV__ ok ping")
                continue
            }
            if line.starts_with("generation") || line.starts_with("activate") {
                println("__ELV__ ok " + line)
                continue
            }
            println("__ELV__ error unknown command: " + line)
        }
    }
    """
  end

  defp body_form(code) do
    Form.execution_body_forms(code)
  end

  defp summarize_load(load) do
    %{
      generation: load.generation,
      source_path: Map.get(load, :source_path),
      source_sha256: Map.get(load, :source_sha256),
      artifact_path: Map.get(load, :artifact_path),
      native_loaded?: Map.get(load, :native_loaded?),
      policy: Map.get(load, :policy)
    }
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

  defp close_daemon(pid) when is_pid(pid) do
    Elv.VDaemon.close(pid)
    :ok
  end

  defp close_daemon(_pid), do: :ok

  defp start_daemon(v_path, cwd, tmp_dir, mode, daemon_driver, opts) do
    config = %{
      mode: mode,
      v_path: v_path,
      cwd: cwd,
      tmp_dir: tmp_dir,
      driver: daemon_driver,
      generation_retention: Keyword.get(opts, :hot_generation_retention, 2),
      recycle_after_generations: Keyword.get(opts, :hot_recycle_after_generations, 50)
    }

    case start_supervised_daemon(config) do
      {:ok, daemon} ->
        {daemon, :enabled, hot_reason(mode), nil}

      {:error, message} ->
        {nil, :degraded, "V daemon unavailable; replay backend remains authoritative",
         inspect_message(message)}
    end
  end

  defp start_supervised_daemon(config) do
    if Process.whereis(Elv.VDaemonSupervisor) do
      Elv.VDaemonSupervisor.start_daemon(config)
    else
      Elv.VDaemon.start(config)
    end
  end

  defp daemon_metadata(%__MODULE__{daemon: daemon}) when is_pid(daemon) do
    case safe_daemon_call(fn -> Elv.VDaemon.metadata(daemon) end) do
      {:ok, metadata} -> {:ok, metadata}
      {:exit, reason} -> {:error, "V daemon exited: #{format_reason(reason)}"}
    end
  end

  defp daemon_metadata(%__MODULE__{last_hot_error: message}) when is_binary(message) do
    {:error, message}
  end

  defp daemon_metadata(_state), do: {:error, nil}

  defp safe_daemon_call(fun) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:exit, reason}
  end

  defp hot_reason(:live) do
    "v -live generation backend active; replay remains authoritative for REPL output and recovery"
  end

  defp hot_reason(:plugin) do
    "shared-library plugin generations active; replay remains authoritative for REPL output and recovery"
  end

  defp normalize_mode(:plugin), do: :plugin
  defp normalize_mode("plugin"), do: :plugin
  defp normalize_mode(_mode), do: :live

  defp make_tmp_dir(nil, mode) do
    System.get_env("ELV_TMP_ROOT")
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> Path.join(System.tmp_dir!(), "elv")
    end
    |> make_tmp_dir(mode)
  end

  defp make_tmp_dir(root, mode) do
    root = Path.expand(root)
    dir = Path.join(root, "hot_#{mode}_" <> unique_id())
    File.mkdir_p!(dir)
    dir
  end

  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp inspect_message(message) when is_binary(message), do: message
  defp inspect_message(message), do: inspect(message)

  defp format_reason(reason) do
    inspect(reason, pretty: false, limit: 20)
  end
end
