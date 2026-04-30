defmodule Elv.SessionServer do
  @moduledoc false

  use GenServer

  alias Elv.Form

  @default_backend Elv.Engine
  @default_timeout_ms 30_000

  defstruct [
    :id,
    :backend_mod,
    :backend,
    :v_path,
    :cwd,
    :tmp_root,
    :snapshot_store,
    :lsp_client,
    :lsp_status,
    :lsp_document_uri,
    :lsp_document_version,
    :worker_recycle_after,
    :started_at,
    :last_error,
    eval_count: 0,
    error_count: 0,
    crash_count: 0,
    timeout_count: 0,
    total_eval_us: 0,
    last_eval_us: nil,
    recovery_count: 0,
    last_recovery_us: nil,
    last_replayed_count: nil,
    last_skipped_count: nil,
    auto_recovery_count: 0,
    last_auto_recovery: nil,
    poisoned_generations: [],
    worker_recycle_count: 0,
    last_worker_recycle: nil,
    safe_history: [],
    history: []
  ]

  def start_link(config) when is_map(config) do
    GenServer.start_link(__MODULE__, config)
  end

  def eval(pid, code, opts \\ []) do
    timeout = (Keyword.get(opts, :hard_timeout_ms) || @default_timeout_ms) + 5_000
    GenServer.call(pid, {:eval, code, opts}, timeout)
  end

  def run_v(pid, args, opts \\ []) do
    timeout = (Keyword.get(opts, :timeout_ms) || @default_timeout_ms) + 5_000
    GenServer.call(pid, {:run_v, args, opts}, timeout)
  end

  def restart(pid, opts \\ []) do
    GenServer.call(pid, {:restart, opts}, :infinity)
  end

  def recover_latest(pid, opts \\ []) do
    GenServer.call(pid, {:recover_latest, opts}, :infinity)
  end

  def close(pid) do
    GenServer.call(pid, :close, :infinity)
  catch
    :exit, _ -> :ok
  end

  def history(pid), do: GenServer.call(pid, :history)
  def metadata(pid), do: GenServer.call(pid, :metadata)
  def split_forms(pid, code), do: GenServer.call(pid, {:split_forms, code})
  def diagnostics(pid), do: GenServer.call(pid, :diagnostics)

  def complete(pid, source, line, character, opts \\ []) do
    timeout = (Keyword.get(opts, :timeout_ms) || @default_timeout_ms) + 1_000
    GenServer.call(pid, {:complete, source, line, character, opts}, timeout)
  end

  @impl true
  def init(config) do
    backend_mod = Map.get(config, :backend, @default_backend)
    v_path = Map.fetch!(config, :v_path)
    cwd = Map.fetch!(config, :cwd)
    tmp_root = Map.get(config, :tmp_root)
    lsp_status = start_lsp(config, cwd)
    worker_recycle_after = Map.get(config, :worker_recycle_after)

    case backend_mod.start(v_path, cwd, backend_opts(config)) do
      {:ok, backend} ->
        session_id = unique_id()
        backend_metadata = backend_mod.metadata(backend)
        snapshot_opts = snapshot_opts(config)

        {:ok, snapshot_store} =
          Elv.SnapshotStore.start(session_id, backend_metadata, snapshot_opts)

        {:ok,
         %__MODULE__{
           id: session_id,
           backend_mod: backend_mod,
           backend: backend,
           v_path: v_path,
           cwd: cwd,
           tmp_root: tmp_root,
           snapshot_store: snapshot_store,
           lsp_client: lsp_client(lsp_status),
           lsp_status: lsp_status,
           lsp_document_uri: lsp_document_uri(cwd, session_id),
           lsp_document_version: 0,
           worker_recycle_after: worker_recycle_after,
           started_at: DateTime.utc_now()
         }}

      {:error, message} ->
        {:stop, message}
    end
  end

  @impl true
  def handle_call({:eval, code, opts}, _from, state) do
    history = state.history ++ [code]

    case state.backend_mod.eval(state.backend, code, opts) do
      {:ok, output, elapsed_us, backend} ->
        state =
          %{
            state
            | backend: backend,
              history: history,
              safe_history: state.safe_history ++ [code],
              eval_count: state.eval_count + 1,
              total_eval_us: state.total_eval_us + elapsed_us,
              last_eval_us: elapsed_us,
              last_error: nil
          }
          |> update_lsp_document()
          |> checkpoint()
          |> maybe_recycle_worker(opts)

        {:reply, {:ok, output, elapsed_us, self()}, state}

      {:error, message, backend} ->
        state = %{
          state
          | backend: backend,
            history: history,
            eval_count: state.eval_count + 1,
            last_error: message
        }

        {reply_message, state} =
          state
          |> record_error()
          |> maybe_auto_recover(opts)

        {:reply, {:error, reply_message, self()}, state}
    end
  end

  def handle_call({:run_v, args, opts}, _from, state) do
    {:reply, state.backend_mod.run_v(state.backend, args, opts), state}
  end

  def handle_call({:restart, opts}, _from, state) do
    opts = Keyword.put_new(opts, :tmp_root, state.tmp_root)

    case state.backend_mod.restart(state.backend, opts) do
      {:ok, backend} ->
        {:ok, snapshot_store} =
          Elv.SnapshotStore.start(state.id, state.backend_mod.metadata(backend),
            root: state.snapshot_store.root,
            enabled?: state.snapshot_store.enabled?
          )

        {:reply, :ok,
         %{
           state
           | backend: backend,
             snapshot_store: snapshot_store,
             safe_history: [],
             last_error: nil
         }}

      {:error, message} ->
        {:reply, {:error, message}, record_error(%{state | last_error: message})}
    end
  end

  def handle_call({:recover_latest, opts}, _from, state) do
    case Elv.SnapshotStore.read_latest(state.snapshot_store) do
      {:ok, snapshot} ->
        recover_from_snapshot(state, snapshot, opts)

      {:error, :disabled} ->
        {:reply, {:error, "snapshots are disabled", self()}, state}

      {:error, reason} ->
        {:reply, {:error, "could not read latest snapshot: #{inspect(reason)}", self()}, state}
    end
  end

  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call(:metadata, _from, state) do
    {:reply, session_metadata(state), state}
  end

  def handle_call({:split_forms, code}, _from, state) do
    {:reply, state.backend_mod.split_forms(code), state}
  end

  def handle_call(:diagnostics, _from, state) do
    case state.lsp_status do
      {:enabled, pid} ->
        {:reply, Elv.LspClient.diagnostics(pid, state.lsp_document_uri), state}

      {:disabled, reason} ->
        {:reply, {:disabled, reason}, state}
    end
  end

  def handle_call({:complete, source, line, character, opts}, _from, state) do
    case state.lsp_status do
      {:enabled, pid} ->
        original_history = state.safe_history
        state = update_lsp_document(%{state | safe_history: original_history ++ [source]})

        reply =
          Elv.LspClient.completion(pid, state.lsp_document_uri, line, character,
            timeout_ms: Keyword.get(opts, :timeout_ms, 2_000)
          )

        {:reply, reply, %{state | safe_history: original_history}}

      {:disabled, reason} ->
        {:reply, {:disabled, reason}, state}
    end
  end

  def handle_call(:close, _from, state) do
    close_backend(state)
    close_lsp(state)
    {:stop, :normal, :ok, %{state | backend: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    close_backend(state)
    close_lsp(state)
  end

  defp session_metadata(state) do
    backend_metadata =
      if is_nil(state.backend), do: %{}, else: state.backend_mod.metadata(state.backend)

    Map.merge(backend_metadata, %{
      session_id: state.id,
      started_at: DateTime.to_iso8601(state.started_at),
      history_count: length(state.history),
      safe_history_count: length(state.safe_history),
      eval_count: state.eval_count,
      error_count: state.error_count,
      crash_count: state.crash_count,
      timeout_count: state.timeout_count,
      total_eval_us: state.total_eval_us,
      last_eval_us: state.last_eval_us,
      recovery_count: state.recovery_count,
      last_recovery_us: state.last_recovery_us,
      last_replayed_count: state.last_replayed_count,
      last_skipped_count: state.last_skipped_count,
      auto_recovery_count: state.auto_recovery_count,
      last_auto_recovery: state.last_auto_recovery,
      poisoned_generations: Enum.reverse(state.poisoned_generations),
      worker_recycle_after: state.worker_recycle_after,
      worker_recycle_count: state.worker_recycle_count,
      last_worker_recycle: state.last_worker_recycle,
      last_error: state.last_error
    })
    |> Map.merge(Elv.SnapshotStore.metadata(state.snapshot_store))
    |> Map.merge(lsp_metadata(state))
  end

  defp checkpoint(state) do
    forms = snapshot_forms(state.safe_history)

    snapshot = %{
      session_id: state.id,
      backend: state.backend_mod.metadata(state.backend),
      history: state.safe_history,
      forms: forms,
      replay_plan: replay_plan(forms),
      deterministic_count: Enum.count(forms, & &1.deterministic?),
      side_effecting_count: Enum.count(forms, & &1.side_effecting?),
      eval_count: state.eval_count,
      error_count: state.error_count,
      crash_count: state.crash_count,
      timeout_count: state.timeout_count,
      total_eval_us: state.total_eval_us
    }

    case Elv.SnapshotStore.put(state.snapshot_store, snapshot) do
      {:ok, snapshot_store} ->
        %{state | snapshot_store: snapshot_store}

      {:error, message, snapshot_store} ->
        %{state | snapshot_store: snapshot_store, last_error: message}
    end
  end

  defp recover_from_snapshot(state, snapshot, opts) do
    started_us = System.monotonic_time(:microsecond)
    replay = replay_plan_from_snapshot(snapshot)
    replay_history = Enum.map(replay.replayed, &Map.fetch!(&1, :source))
    restart_opts = Keyword.put_new(opts, :tmp_root, state.tmp_root)

    with {:ok, backend} <- state.backend_mod.restart(state.backend, restart_opts),
         {:ok, backend, replayed} <-
           replay_forms(state.backend_mod, backend, replay_history, opts) do
      elapsed_us = System.monotonic_time(:microsecond) - started_us

      state =
        %{
          state
          | backend: backend,
            safe_history: replayed,
            recovery_count: state.recovery_count + 1,
            last_recovery_us: elapsed_us,
            last_replayed_count: length(replayed),
            last_skipped_count: length(replay.skipped),
            last_error: nil
        }
        |> checkpoint()

      {:reply, {:ok, length(replayed), length(replay.skipped), elapsed_us, self()}, state}
    else
      {:error, message} ->
        state = record_error(%{state | last_error: message})
        {:reply, {:error, message, self()}, state}

      {:error, message, backend, replayed} ->
        state =
          record_error(%{
            state
            | backend: backend,
              safe_history: replayed,
              last_error: message
          })

        {:reply, {:error, message, self()}, state}
    end
  end

  defp replay_forms(backend_mod, backend, forms, opts) do
    Enum.reduce_while(forms, {:ok, backend, []}, fn source, {:ok, current_backend, replayed} ->
      case backend_mod.eval(current_backend, source, opts) do
        {:ok, _output, _elapsed_us, next_backend} ->
          {:cont, {:ok, next_backend, replayed ++ [source]}}

        {:error, message, next_backend} ->
          {:halt, {:error, message, next_backend, replayed}}
      end
    end)
  end

  defp replay_plan_from_snapshot(%{forms: forms}) when is_list(forms) do
    replay_plan(forms)
  end

  defp replay_plan_from_snapshot(%{history: history}) when is_list(history) do
    forms =
      history
      |> Enum.with_index(1)
      |> Enum.map(fn {source, index} -> Form.snapshot_map(source, index) end)

    replay_plan(forms)
  end

  defp replay_plan_from_snapshot(_snapshot), do: %{replayed: [], skipped: []}

  defp snapshot_opts(config) do
    [
      root: Map.get(config, :snapshot_root),
      enabled?: Map.get(config, :snapshots?, true)
    ]
  end

  defp backend_opts(config) do
    [
      tmp_root: Map.get(config, :tmp_root),
      worker_backend: Map.get(config, :worker_backend, Elv.Engine),
      hot_reload_mode: Map.get(config, :hot_reload_mode, :live),
      hot_generation_retention: Map.get(config, :hot_generation_retention, 2),
      hot_recycle_after_generations: Map.get(config, :hot_recycle_after_generations, 50)
    ]
  end

  defp maybe_recycle_worker(%{worker_recycle_after: max} = state, opts)
       when is_integer(max) and max > 0 do
    metadata = state.backend_mod.metadata(state.backend)

    if metadata[:backend] == :worker and metadata[:worker_evals_since_start] >= max do
      recycle_worker_from_checkpoint(state, opts, "max_evals=#{max}")
    else
      state
    end
  end

  defp maybe_recycle_worker(state, _opts), do: state

  defp recycle_worker_from_checkpoint(state, opts, reason) do
    case Elv.SnapshotStore.read_latest(state.snapshot_store) do
      {:ok, snapshot} ->
        started_us = System.monotonic_time(:microsecond)
        replay = replay_plan_from_snapshot(snapshot)
        replay_history = Enum.map(replay.replayed, &Map.fetch!(&1, :source))
        restart_opts = Keyword.put_new(opts, :tmp_root, state.tmp_root)

        with {:ok, backend} <- state.backend_mod.restart(state.backend, restart_opts),
             {:ok, backend, replayed} <-
               replay_forms(state.backend_mod, backend, replay_history, opts) do
          elapsed_us = System.monotonic_time(:microsecond) - started_us

          %{
            state
            | backend: backend,
              safe_history: replayed,
              worker_recycle_count: state.worker_recycle_count + 1,
              last_worker_recycle: %{
                reason: reason,
                replayed: length(replayed),
                skipped: length(replay.skipped),
                elapsed_us: elapsed_us,
                at: DateTime.utc_now() |> DateTime.to_iso8601()
              }
          }
        else
          {:error, message} ->
            record_error(%{state | last_error: "worker recycle failed: #{message}"})

          {:error, message, backend, replayed} ->
            record_error(%{
              state
              | backend: backend,
                safe_history: replayed,
                last_error: "worker recycle failed: #{message}"
            })
        end

      {:error, reason} ->
        record_error(%{state | last_error: "worker recycle failed: #{inspect(reason)}"})
    end
  end

  defp start_lsp(config, cwd) do
    if Map.get(config, :lsp?, false) do
      command = Map.get(config, :lsp_command)

      case Elv.LspClient.start_optional(command: command, cwd: cwd) do
        {:ok, pid} -> {:enabled, pid}
        {:disabled, reason} -> {:disabled, reason}
      end
    else
      {:disabled, "not requested"}
    end
  end

  defp lsp_client({:enabled, pid}), do: pid
  defp lsp_client(_status), do: nil

  defp lsp_metadata(%{lsp_status: {:enabled, pid}} = state) do
    Elv.LspClient.metadata(pid)
    |> Map.merge(%{lsp_document_uri: state.lsp_document_uri})
  rescue
    error ->
      %{lsp: :error, lsp_last_error: Exception.message(error)}
  end

  defp lsp_metadata(%{lsp_status: {:disabled, reason}}) do
    %{lsp: :disabled, lsp_last_error: reason}
  end

  defp update_lsp_document(%{lsp_status: {:enabled, pid}} = state) do
    text = Enum.join(state.safe_history, "\n\n")
    version = state.lsp_document_version + 1

    result =
      if state.lsp_document_version == 0 do
        Elv.LspClient.open_document(pid, state.lsp_document_uri, text, version: version)
      else
        Elv.LspClient.change_document(pid, state.lsp_document_uri, version, text)
      end

    case result do
      :ok -> %{state | lsp_document_version: version}
      _ -> state
    end
  rescue
    error -> %{state | lsp_status: {:disabled, Exception.message(error)}, lsp_client: nil}
  end

  defp update_lsp_document(state), do: state

  defp lsp_document_uri(cwd, session_id) do
    Elv.LspClient.path_uri(Path.join(cwd, ".elv_session_#{session_id}.v"))
  end

  defp snapshot_forms(history) do
    history
    |> Enum.with_index(1)
    |> Enum.map(fn {source, index} -> Form.snapshot_map(source, index) end)
  end

  defp replay_plan(forms) do
    forms =
      Enum.map(forms, fn form ->
        if is_struct(form), do: Map.from_struct(form), else: form
      end)

    %{
      replayed: Enum.filter(forms, &Map.get(&1, :deterministic?, true)),
      skipped: Enum.reject(forms, &Map.get(&1, :deterministic?, true))
    }
  end

  defp record_error(state) do
    %{
      state
      | error_count: state.error_count + 1,
        crash_count: state.crash_count + crash_increment(state.last_error),
        timeout_count: state.timeout_count + timeout_increment(state.last_error)
    }
  end

  defp maybe_auto_recover(state, opts) do
    cond do
      not recoverable_crash?(state.last_error) ->
        {state.last_error, state}

      true ->
        poisoned_generation = state.backend_mod.metadata(state.backend)[:generation]

        state = %{
          state
          | poisoned_generations: [poisoned_generation | state.poisoned_generations]
        }

        case Elv.SnapshotStore.read_latest(state.snapshot_store) do
          {:ok, snapshot} ->
            auto_recover_from_snapshot(state, snapshot, opts)

          {:error, :disabled} ->
            {"#{state.last_error}\nautomatic recovery skipped: snapshots are disabled", state}

          {:error, reason} ->
            {"#{state.last_error}\nautomatic recovery failed: could not read latest snapshot #{inspect(reason)}",
             state}
        end
    end
  end

  defp auto_recover_from_snapshot(state, snapshot, opts) do
    started_us = System.monotonic_time(:microsecond)
    replay = replay_plan_from_snapshot(snapshot)
    replay_history = Enum.map(replay.replayed, &Map.fetch!(&1, :source))
    restart_opts = Keyword.put_new(opts, :tmp_root, state.tmp_root)

    with {:ok, backend} <- state.backend_mod.restart(state.backend, restart_opts),
         {:ok, backend, replayed} <-
           replay_forms(state.backend_mod, backend, replay_history, opts) do
      elapsed_us = System.monotonic_time(:microsecond) - started_us

      recovery = %{
        replayed: length(replayed),
        skipped: length(replay.skipped),
        elapsed_us: elapsed_us,
        at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      state =
        %{
          state
          | backend: backend,
            safe_history: replayed,
            recovery_count: state.recovery_count + 1,
            auto_recovery_count: state.auto_recovery_count + 1,
            last_recovery_us: elapsed_us,
            last_replayed_count: length(replayed),
            last_skipped_count: length(replay.skipped),
            last_auto_recovery: recovery
        }
        |> checkpoint()

      message =
        "#{state.last_error}\nautomatic recovery replayed #{recovery.replayed} form(s), skipped #{recovery.skipped} side-effecting form(s)"

      {message, state}
    else
      {:error, message} ->
        {"#{state.last_error}\nautomatic recovery failed: #{message}",
         record_error(%{state | last_error: message})}

      {:error, message, backend, replayed} ->
        state =
          record_error(%{
            state
            | backend: backend,
              safe_history: replayed,
              last_error: message
          })

        {"#{state.last_error}\nautomatic recovery failed: #{message}", state}
    end
  end

  defp crash_increment(message) when is_binary(message) do
    cond do
      String.contains?(message, "worker crashed") ->
        1

      true ->
        case Regex.run(~r/v exited with status (\d+)/, message) do
          [_, status] ->
            status = String.to_integer(status)
            if status >= 128, do: 1, else: 0

          _ ->
            0
        end
    end
  end

  defp crash_increment(_message), do: 0

  defp recoverable_crash?(message) when is_binary(message) do
    crash_increment(message) > 0
  end

  defp recoverable_crash?(_message), do: false

  defp timeout_increment(message) when is_binary(message) do
    if String.contains?(message, "timed out"), do: 1, else: 0
  end

  defp timeout_increment(_message), do: 0

  defp close_backend(%{backend: nil}), do: :ok

  defp close_backend(%{backend_mod: backend_mod, backend: backend}) do
    backend_mod.close(backend)
  rescue
    _ -> :ok
  end

  defp close_lsp(%{lsp_status: {:enabled, pid}}), do: Elv.LspClient.close(pid)
  defp close_lsp(_state), do: :ok

  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
