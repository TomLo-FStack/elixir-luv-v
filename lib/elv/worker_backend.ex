defmodule Elv.WorkerBackend do
  @moduledoc false

  @behaviour Elv.ExecutionBackend

  defstruct [
    :pid,
    :worker_backend,
    :v_path,
    :cwd,
    :backend_opts,
    :last_metadata,
    :evals_since_start,
    :worker_generation,
    :recycle_count,
    :last_recycle_reason
  ]

  @impl true
  def start(v_path, cwd, opts \\ []) do
    worker_backend = Keyword.get(opts, :worker_backend, Elv.Engine)
    backend_opts = Keyword.delete(opts, :worker_backend)

    start_worker(%__MODULE__{
      worker_backend: worker_backend,
      v_path: v_path,
      cwd: cwd,
      backend_opts: backend_opts,
      evals_since_start: 0,
      worker_generation: 0,
      recycle_count: 0
    })
  end

  @impl true
  def close(%__MODULE__{pid: pid}) do
    if is_pid(pid), do: Elv.VWorker.close(pid)
    :ok
  end

  @impl true
  def restart(%__MODULE__{} = state, opts \\ []) do
    close(state)

    state =
      %{
        state
        | backend_opts: Keyword.merge(state.backend_opts, opts),
          evals_since_start: 0,
          last_recycle_reason: nil
      }

    start_worker(state)
  end

  @impl true
  def eval(%__MODULE__{} = state, code, opts \\ []) do
    case safe_call(fn -> Elv.VWorker.eval(state.pid, code, opts) end) do
      {:ok, {:ok, output, elapsed_us}} ->
        state =
          state
          |> refresh_metadata()
          |> record_eval()

        {:ok, output, elapsed_us, state}

      {:ok, {:error, message}} ->
        state =
          state
          |> refresh_metadata()
          |> record_eval()

        {:error, message, state}

      {:exit, reason} ->
        worker_crashed(state, reason)
    end
  end

  @impl true
  def run_v(%__MODULE__{} = state, args, opts \\ []) do
    case safe_call(fn -> Elv.VWorker.run_v(state.pid, args, opts) end) do
      {:ok, result} -> result
      {:exit, reason} -> {"worker crashed: #{format_reason(reason)}", 1}
    end
  end

  @impl true
  def split_forms(code), do: Elv.Engine.split_forms(code)

  @impl true
  def metadata(%__MODULE__{} = state) do
    case safe_call(fn -> Elv.VWorker.metadata(state.pid) end) do
      {:ok, metadata} ->
        metadata
        |> Map.merge(%{
          backend: :worker,
          worker_backend: state.worker_backend,
          worker_alive?: true,
          worker_generation: state.worker_generation,
          worker_evals_since_start: state.evals_since_start,
          worker_recycle_count: state.recycle_count,
          worker_last_recycle_reason: state.last_recycle_reason,
          capabilities: %{
            replay: true,
            worker_isolation: true,
            lsp: false,
            snapshots: true,
            live_reload: false,
            plugins: false
          }
        })

      {:exit, reason} ->
        synthetic_metadata(state, reason)
    end
  end

  defp start_worker(%__MODULE__{} = state) do
    config = %{
      backend: state.worker_backend,
      v_path: state.v_path,
      cwd: state.cwd,
      backend_opts: state.backend_opts
    }

    case safe_call(fn -> Elv.WorkerSupervisor.start_worker(config) end) do
      {:ok, {:ok, pid}} ->
        state = %{
          state
          | pid: pid,
            worker_generation: state.worker_generation + 1,
            evals_since_start: 0
        }

        {:ok, refresh_metadata(state)}

      {:ok, {:error, {:already_started, pid}}} ->
        state = %{state | pid: pid}
        {:ok, refresh_metadata(state)}

      {:ok, {:error, reason}} ->
        {:error, "could not start worker: #{inspect(reason)}"}

      {:exit, reason} ->
        {:error, "worker supervisor unavailable: #{format_reason(reason)}"}
    end
  end

  defp worker_crashed(state, reason) do
    case start_worker(%{state | pid: nil}) do
      {:ok, new_state} ->
        new_state = %{
          new_state
          | recycle_count: state.recycle_count + 1,
            last_recycle_reason: "crash: #{format_reason(reason)}"
        }

        {:error, "worker crashed: #{format_reason(reason)}", new_state}

      {:error, message} ->
        {:error, "worker crashed: #{format_reason(reason)}; #{message}", state}
    end
  end

  defp refresh_metadata(%__MODULE__{} = state) do
    case safe_call(fn -> Elv.VWorker.metadata(state.pid) end) do
      {:ok, metadata} -> %{state | last_metadata: metadata}
      {:exit, _reason} -> state
    end
  end

  defp synthetic_metadata(state, reason) do
    base =
      state.last_metadata ||
        %{
          v_path: state.v_path,
          cwd: state.cwd,
          tmp_dir: nil,
          tmp_root: nil,
          generation: nil,
          imports: 0,
          declarations: 0,
          body_forms: 0
        }

    Map.merge(base, %{
      backend: :worker,
      worker_backend: state.worker_backend,
      worker_pid: inspect(state.pid),
      worker_alive?: false,
      worker_exit: format_reason(reason),
      worker_generation: state.worker_generation,
      worker_evals_since_start: state.evals_since_start,
      worker_recycle_count: state.recycle_count,
      worker_last_recycle_reason: state.last_recycle_reason
    })
  end

  defp record_eval(state) do
    %{state | evals_since_start: state.evals_since_start + 1}
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:exit, reason}
  end

  defp format_reason(reason) do
    inspect(reason, pretty: false, limit: 20)
  end
end
