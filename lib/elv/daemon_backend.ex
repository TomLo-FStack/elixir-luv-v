defmodule Elv.DaemonBackend do
  @moduledoc false

  @behaviour Elv.ExecutionBackend

  defstruct [
    :v_path,
    :cwd,
    :tmp_dir,
    :daemon,
    :fallback,
    :daemon_status,
    :daemon_reason,
    :daemon_driver,
    :last_daemon_error,
    :fallback_synced?,
    daemon_eval_count: 0,
    daemon_error_count: 0,
    daemon_reset_count: 0,
    daemon_snapshot_count: 0,
    last_daemon_eval_us: nil,
    imports: 0,
    declarations: 0,
    body_forms: 0,
    history: []
  ]

  @impl true
  def start(v_path, cwd, opts \\ []) do
    tmp_dir = make_tmp_dir(Keyword.get(opts, :tmp_root))
    fallback_backend = Keyword.get(opts, :daemon_fallback_backend, Elv.Engine)
    daemon_driver = Keyword.get(opts, :v_daemon_driver, Elv.VDaemon.SystemDriver)

    case fallback_backend.start(v_path, cwd, opts) do
      {:ok, fallback_state} ->
        case start_daemon(v_path, cwd, tmp_dir, daemon_driver, opts) do
          {:ok, daemon} ->
            {:ok,
             %__MODULE__{
               v_path: v_path,
               cwd: cwd,
               tmp_dir: tmp_dir,
               daemon: daemon,
               fallback: {fallback_backend, fallback_state},
               daemon_status: :enabled,
               daemon_reason: "authoritative source-level V daemon backend active",
               daemon_driver: daemon_driver,
               fallback_synced?: false
             }}

          {:error, message} ->
            {:ok,
             %__MODULE__{
               v_path: v_path,
               cwd: cwd,
               tmp_dir: tmp_dir,
               daemon: nil,
               fallback: {fallback_backend, fallback_state},
               daemon_status: :degraded,
               daemon_reason: "V daemon unavailable; replay backend is authoritative",
               daemon_driver: daemon_driver,
               last_daemon_error: inspect_message(message),
               fallback_synced?: true
             }}
        end

      {:error, message} ->
        File.rm_rf(tmp_dir)
        {:error, message}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def close(%__MODULE__{fallback: {fallback_backend, fallback_state}} = state) do
    if is_pid(state.daemon), do: Elv.VDaemon.close(state.daemon)
    fallback_backend.close(fallback_state)
    if is_binary(state.tmp_dir), do: File.rm_rf(state.tmp_dir)
    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def restart(%__MODULE__{} = state, opts \\ []) do
    restart_opts = Keyword.put_new(opts, :tmp_root, Path.dirname(state.tmp_dir))
    close_daemon(state.daemon)

    {fallback_backend, current_fallback_state} = state.fallback

    with {:ok, fallback_state} <- fallback_backend.restart(current_fallback_state, restart_opts) do
      case start_daemon(state.v_path, state.cwd, state.tmp_dir, state.daemon_driver, opts) do
        {:ok, daemon} ->
          {:ok,
           %{
             state
             | daemon: daemon,
               fallback: {fallback_backend, fallback_state},
               daemon_status: :enabled,
               daemon_reason: "authoritative source-level V daemon backend active",
               last_daemon_error: nil,
               daemon_reset_count: state.daemon_reset_count + 1,
               imports: 0,
               declarations: 0,
               body_forms: 0,
               history: [],
               fallback_synced?: false
           }}

        {:error, message} ->
          {:ok,
           %{
             state
             | daemon: nil,
               fallback: {fallback_backend, fallback_state},
               daemon_status: :degraded,
               daemon_reason: "V daemon unavailable after reset; replay backend is authoritative",
               last_daemon_error: inspect_message(message),
               daemon_reset_count: state.daemon_reset_count + 1,
               imports: 0,
               declarations: 0,
               body_forms: 0,
               history: [],
               fallback_synced?: true
           }}
      end
    end
  end

  @impl true
  def eval(%__MODULE__{daemon: daemon} = state, code, opts) when is_pid(daemon) do
    code = String.trim(code)

    case safe_daemon_call(fn -> Elv.VDaemon.eval(daemon, code, opts) end) do
      {:ok, {:ok, %{status: 0, stdout: output, elapsed_us: elapsed_us}}} ->
        state = maybe_record_snapshot(state)

        state =
          state
          |> update_counts(code)
          |> Map.merge(%{
            daemon_eval_count: state.daemon_eval_count + 1,
            last_daemon_eval_us: elapsed_us,
            last_daemon_error: nil,
            history: append_history(state.history, code),
            fallback_synced?: false
          })

        {:ok, output, elapsed_us, state}

      {:ok, {:ok, %{stderr: stderr, status: status, elapsed_us: elapsed_us}}} ->
        message = String.trim_trailing(stderr)

        state = %{
          state
          | daemon_error_count: state.daemon_error_count + 1,
            last_daemon_eval_us: elapsed_us,
            last_daemon_error: message
        }

        {:error, message_for_status(status, message), state}

      {:ok, {:error, message}} ->
        state = degrade_to_fallback(state, "V daemon eval failed: #{message}")
        eval_fallback(state, code, opts)

      {:exit, reason} ->
        state = degrade_to_fallback(state, "V daemon exited: #{format_reason(reason)}")
        eval_fallback(state, code, opts)
    end
  rescue
    error ->
      state = degrade_to_fallback(state, "V daemon eval failed: #{Exception.message(error)}")
      eval_fallback(state, code, opts)
  end

  def eval(%__MODULE__{} = state, code, opts) do
    eval_fallback(state, String.trim(code), opts)
  end

  @impl true
  def run_v(%__MODULE__{fallback: {fallback_backend, fallback_state}}, args, opts \\ []) do
    fallback_backend.run_v(fallback_state, args, opts)
  end

  @impl true
  def split_forms(code), do: Elv.Engine.split_forms(code)

  @impl true
  def metadata(%__MODULE__{fallback: {fallback_backend, fallback_state}} = state) do
    fallback_metadata = fallback_backend.metadata(fallback_state)
    daemon_metadata = daemon_metadata(state)

    fallback_metadata
    |> Map.merge(daemon_metadata)
    |> Map.merge(%{
      backend: :daemon,
      daemon_authoritative: state.daemon_status == :enabled,
      daemon_status: state.daemon_status,
      daemon_reason: state.daemon_reason,
      daemon_eval_count: state.daemon_eval_count,
      daemon_error_count: state.daemon_error_count,
      daemon_reset_count: state.daemon_reset_count,
      daemon_snapshot_count: state.daemon_snapshot_count,
      last_daemon_eval_us: state.last_daemon_eval_us,
      last_daemon_error: state.last_daemon_error,
      imports: state.imports,
      declarations: state.declarations,
      body_forms: state.body_forms,
      capabilities: %{
        replay: true,
        daemon: state.daemon_status == :enabled,
        fast_eval: false,
        worker_isolation: false,
        lsp: false,
        snapshots: true,
        live_reload: false,
        plugins: false
      }
    })
  end

  defp eval_fallback(
         %__MODULE__{} = state,
         code,
         opts
       ) do
    case ensure_fallback_synced(state, opts) do
      {:ok, %{fallback: {fallback_backend, fallback_state}} = state} ->
        case fallback_backend.eval(fallback_state, code, opts) do
          {:ok, output, elapsed_us, fallback_state} ->
            state =
              state
              |> update_counts(code)
              |> Map.merge(%{
                fallback: {fallback_backend, fallback_state},
                history: append_history(state.history, code)
              })

            {:ok, output, elapsed_us, state}

          {:error, message, fallback_state} ->
            {:error, message, %{state | fallback: {fallback_backend, fallback_state}}}
        end

      {:error, message, state} ->
        {:error, message, state}
    end
  end

  defp ensure_fallback_synced(%__MODULE__{fallback_synced?: true} = state, _opts),
    do: {:ok, state}

  defp ensure_fallback_synced(%__MODULE__{history: []} = state, _opts),
    do: {:ok, %{state | fallback_synced?: true}}

  defp ensure_fallback_synced(
         %__MODULE__{fallback: {fallback_backend, fallback_state}} = state,
         opts
       ) do
    restart_opts =
      Keyword.put_new(opts, :tmp_root, fallback_tmp_root(fallback_backend, fallback_state, state))

    with {:ok, fallback_state} <- fallback_backend.restart(fallback_state, restart_opts),
         {:ok, fallback_state} <-
           replay_history(fallback_backend, fallback_state, state.history, opts) do
      {:ok, %{state | fallback: {fallback_backend, fallback_state}, fallback_synced?: true}}
    else
      {:error, message} ->
        {:error, "fallback replay failed after daemon degradation: #{message}",
         %{state | last_daemon_error: message}}
    end
  end

  defp replay_history(fallback_backend, fallback_state, history, opts) do
    Enum.reduce_while(history, {:ok, fallback_state}, fn source, {:ok, current_state} ->
      case fallback_backend.eval(current_state, source, opts) do
        {:ok, _output, _elapsed_us, next_state} -> {:cont, {:ok, next_state}}
        {:error, message, _next_state} -> {:halt, {:error, message}}
      end
    end)
  end

  defp update_counts(state, ""), do: state

  defp update_counts(state, code) do
    case Elv.Form.classify(code) do
      :import ->
        %{state | imports: state.imports + 1}

      :declaration ->
        %{state | declarations: state.declarations + 1}

      :execution ->
        %{state | body_forms: state.body_forms + length(Elv.Form.execution_body_forms(code))}
    end
  end

  defp degrade_to_fallback(%__MODULE__{} = state, message) do
    %{
      state
      | daemon: nil,
        daemon_status: :degraded,
        daemon_reason: "V daemon unavailable; replay backend is authoritative",
        daemon_error_count: state.daemon_error_count + 1,
        last_daemon_error: message,
        fallback_synced?: false
    }
  end

  defp maybe_record_snapshot(%__MODULE__{daemon: daemon} = state) when is_pid(daemon) do
    case safe_daemon_call(fn -> Elv.VDaemon.snapshot(daemon) end) do
      {:ok, {:ok, _snapshot}} ->
        %{state | daemon_snapshot_count: state.daemon_snapshot_count + 1}

      _ ->
        state
    end
  end

  defp maybe_record_snapshot(state), do: state

  defp daemon_metadata(%__MODULE__{daemon: daemon} = state) when is_pid(daemon) do
    case safe_daemon_call(fn -> Elv.VDaemon.metadata(daemon) end) do
      {:ok, metadata} ->
        metadata

      {:exit, reason} ->
        %{
          v_daemon: :disabled,
          v_daemon_last_error: "V daemon exited: #{format_reason(reason)}"
        }
    end
    |> Map.put(:daemon_backend_status, state.daemon_status)
  end

  defp daemon_metadata(%__MODULE__{} = state) do
    %{
      v_daemon: :disabled,
      v_daemon_last_error: state.last_daemon_error,
      daemon_backend_status: state.daemon_status
    }
  end

  defp start_daemon(v_path, cwd, tmp_dir, daemon_driver, opts) do
    config = %{
      mode: :daemon,
      v_path: v_path,
      cwd: cwd,
      tmp_dir: tmp_dir,
      driver: daemon_driver
    }

    config =
      case Keyword.fetch(opts, :v_daemon_config) do
        {:ok, extra} when is_map(extra) -> Map.merge(config, extra)
        _ -> config
      end

    config =
      config
      |> Map.put(:generation_retention, Keyword.get(opts, :hot_generation_retention, 2))
      |> Map.put(
        :recycle_after_generations,
        Keyword.get(opts, :hot_recycle_after_generations, 50)
      )

    if Process.whereis(Elv.VDaemonSupervisor) do
      Elv.VDaemonSupervisor.start_daemon(config)
    else
      Elv.VDaemon.start(config)
    end
  end

  defp close_daemon(pid) when is_pid(pid), do: Elv.VDaemon.close(pid)
  defp close_daemon(_pid), do: :ok

  defp append_history(history, ""), do: history
  defp append_history(history, code), do: history ++ [code]

  defp fallback_tmp_root(fallback_backend, fallback_state, state) do
    metadata = fallback_backend.metadata(fallback_state)

    cond do
      is_binary(metadata[:tmp_dir]) -> Path.dirname(metadata.tmp_dir)
      is_binary(metadata[:tmp_root]) -> metadata.tmp_root
      true -> Path.dirname(state.tmp_dir)
    end
  rescue
    _ -> Path.dirname(state.tmp_dir)
  end

  defp make_tmp_dir(nil) do
    System.get_env("ELV_TMP_ROOT")
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> Path.join(System.tmp_dir!(), "elv")
    end
    |> make_tmp_dir()
  end

  defp make_tmp_dir(root) do
    root = Path.expand(root)
    dir = Path.join(root, "daemon_backend_" <> unique_id())
    File.mkdir_p!(dir)
    dir
  end

  defp safe_daemon_call(fun) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:exit, reason}
  end

  defp message_for_status(status, message) do
    if String.starts_with?(message, "v exited with status ") do
      message
    else
      "v exited with status #{status}\n#{message}"
    end
  end

  defp inspect_message(message) when is_binary(message), do: message
  defp inspect_message(message), do: inspect(message)

  defp format_reason(reason) do
    inspect(reason, pretty: false, limit: 20)
  end

  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
