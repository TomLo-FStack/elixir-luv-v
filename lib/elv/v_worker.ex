defmodule Elv.VWorker do
  @moduledoc false

  use GenServer

  @default_timeout_ms 30_000

  defstruct [
    :backend_mod,
    :backend,
    :v_path,
    :cwd,
    :backend_opts,
    :started_at
  ]

  def child_spec(config) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

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

  def metadata(pid), do: GenServer.call(pid, :metadata)

  def close(pid) do
    GenServer.call(pid, :close, :infinity)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(config) do
    backend_mod = Map.get(config, :backend, Elv.Engine)
    v_path = Map.fetch!(config, :v_path)
    cwd = Map.fetch!(config, :cwd)
    backend_opts = Map.get(config, :backend_opts, [])

    case backend_mod.start(v_path, cwd, backend_opts) do
      {:ok, backend} ->
        {:ok,
         %__MODULE__{
           backend_mod: backend_mod,
           backend: backend,
           v_path: v_path,
           cwd: cwd,
           backend_opts: backend_opts,
           started_at: DateTime.utc_now()
         }}

      {:error, message} ->
        {:stop, message}
    end
  end

  @impl true
  def handle_call({:eval, code, opts}, _from, state) do
    case state.backend_mod.eval(state.backend, code, opts) do
      {:ok, output, elapsed_us, backend} ->
        {:reply, {:ok, output, elapsed_us}, %{state | backend: backend}}

      {:error, message, backend} ->
        {:reply, {:error, message}, %{state | backend: backend}}
    end
  end

  def handle_call({:run_v, args, opts}, _from, state) do
    {:reply, state.backend_mod.run_v(state.backend, args, opts), state}
  end

  def handle_call({:restart, opts}, _from, state) do
    opts = Keyword.merge(state.backend_opts, opts)

    case state.backend_mod.restart(state.backend, opts) do
      {:ok, backend} -> {:reply, :ok, %{state | backend: backend, backend_opts: opts}}
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call(:metadata, _from, state) do
    metadata =
      state.backend_mod.metadata(state.backend)
      |> Map.merge(%{
        worker_pid: inspect(self()),
        worker_started_at: DateTime.to_iso8601(state.started_at),
        worker_backend: state.backend_mod,
        worker_alive?: true
      })

    {:reply, metadata, state}
  end

  def handle_call(:close, _from, state) do
    close_backend(state)
    {:stop, :normal, :ok, %{state | backend: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    close_backend(state)
  end

  defp close_backend(%{backend: nil}), do: :ok

  defp close_backend(%{backend_mod: backend_mod, backend: backend}) do
    backend_mod.close(backend)
  rescue
    _ -> :ok
  end
end
