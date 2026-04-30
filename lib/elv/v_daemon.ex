defmodule Elv.VDaemon do
  @moduledoc false

  use GenServer

  @default_generation_retention 2
  @default_recycle_after_generations 50

  defstruct [
    :mode,
    :v_path,
    :cwd,
    :tmp_dir,
    :driver,
    :driver_state,
    :started_at,
    :generation_retention,
    :recycle_after_generations,
    :active_generation,
    :last_load,
    :last_unload,
    :last_recycle,
    :last_error,
    loaded_generations: %{},
    load_sequence: 0,
    load_count: 0,
    unload_count: 0,
    recycle_count: 0,
    failed_load_count: 0,
    failed_unload_count: 0,
    loads_since_recycle: 0
  ]

  def start_link(config) when is_map(config) do
    GenServer.start_link(__MODULE__, config)
  end

  def start(config) when is_map(config) do
    GenServer.start(__MODULE__, config)
  end

  def load_generation(pid, spec, opts \\ []) when is_map(spec) do
    GenServer.call(pid, {:load_generation, spec, opts}, :infinity)
  end

  def unload_generation(pid, generation, opts \\ []) do
    GenServer.call(pid, {:unload_generation, generation, opts}, :infinity)
  end

  def eval(pid, source, opts \\ []) when is_binary(source) do
    GenServer.call(pid, {:eval, source, opts}, :infinity)
  end

  def reset(pid, opts \\ []) do
    GenServer.call(pid, {:reset, opts}, :infinity)
  end

  def snapshot(pid, opts \\ []) do
    GenServer.call(pid, {:snapshot, opts}, :infinity)
  end

  def recycle(pid, reason, opts \\ []) do
    GenServer.call(pid, {:recycle, reason, opts}, :infinity)
  end

  def metadata(pid), do: GenServer.call(pid, :metadata)

  def close(pid) do
    GenServer.call(pid, :close, :infinity)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(config) do
    driver = Map.get(config, :driver, Elv.VDaemon.SystemDriver)

    case driver.start(config) do
      {:ok, driver_state} ->
        {:ok,
         %__MODULE__{
           mode: Map.fetch!(config, :mode),
           v_path: Map.fetch!(config, :v_path),
           cwd: Map.fetch!(config, :cwd),
           tmp_dir: Map.fetch!(config, :tmp_dir),
           driver: driver,
           driver_state: driver_state,
           generation_retention:
             Map.get(config, :generation_retention, @default_generation_retention),
           recycle_after_generations:
             Map.get(config, :recycle_after_generations, @default_recycle_after_generations),
           started_at: DateTime.utc_now()
         }}

      {:error, message} ->
        {:stop, message}
    end
  end

  @impl true
  def handle_call({:load_generation, spec, opts}, _from, state) do
    started_us = System.monotonic_time(:microsecond)

    with {:ok, artifact, driver_state} <- state.driver.build(state.driver_state, spec, opts),
         state = %{state | driver_state: driver_state},
         {:ok, load_info, driver_state} <- state.driver.load(state.driver_state, artifact, opts) do
      elapsed_us = System.monotonic_time(:microsecond) - started_us
      loaded_at = DateTime.utc_now() |> DateTime.to_iso8601()

      record =
        artifact
        |> Map.merge(load_info)
        |> Map.put(:loaded_at, loaded_at)
        |> Map.put(:load_elapsed_us, elapsed_us)
        |> Map.put(:load_index, state.load_sequence + 1)

      state = %{
        state
        | driver_state: driver_state,
          loaded_generations: Map.put(state.loaded_generations, record.generation, record),
          active_generation: record.generation,
          load_sequence: state.load_sequence + 1,
          load_count: state.load_count + 1,
          loads_since_recycle: state.loads_since_recycle + 1,
          last_load: summarize_record(record),
          last_error: nil
      }

      case enforce_generation_policy(state, record, opts) do
        {:ok, state, policy} ->
          record = Map.put(record, :policy, policy)
          {:reply, {:ok, record}, state}

        {:error, message, state} ->
          state = %{
            state
            | failed_load_count: state.failed_load_count + 1,
              last_error: message
          }

          {:reply, {:error, message}, state}
      end
    else
      {:error, message, driver_state} ->
        state = %{
          state
          | driver_state: driver_state,
            failed_load_count: state.failed_load_count + 1,
            last_error: message
        }

        {:reply, {:error, message}, state}
    end
  end

  def handle_call({:unload_generation, generation, opts}, _from, state) do
    case Map.fetch(state.loaded_generations, generation) do
      {:ok, record} ->
        case unload_record(state, record, opts) do
          {:ok, state, unload_info} -> {:reply, {:ok, unload_info}, state}
          {:error, message, state} -> {:reply, {:error, message}, state}
        end

      :error ->
        {:reply, {:ok, %{generation: generation, unloaded?: false, reason: :not_loaded}}, state}
    end
  end

  def handle_call({:eval, source, opts}, _from, state) do
    case state.driver.eval(state.driver_state, source, opts) do
      {:ok, result, driver_state} ->
        {:reply, {:ok, result}, %{state | driver_state: driver_state, last_error: nil}}

      {:error, message, driver_state} ->
        {:reply, {:error, message}, %{state | driver_state: driver_state, last_error: message}}
    end
  end

  def handle_call({:reset, opts}, _from, state) do
    case state.driver.reset(state.driver_state, opts) do
      {:ok, result, driver_state} ->
        {:reply, {:ok, result}, %{state | driver_state: driver_state, last_error: nil}}

      {:error, message, driver_state} ->
        {:reply, {:error, message}, %{state | driver_state: driver_state, last_error: message}}
    end
  end

  def handle_call({:snapshot, opts}, _from, state) do
    case state.driver.snapshot(state.driver_state, opts) do
      {:ok, result, driver_state} ->
        {:reply, {:ok, result}, %{state | driver_state: driver_state, last_error: nil}}

      {:error, message, driver_state} ->
        {:reply, {:error, message}, %{state | driver_state: driver_state, last_error: message}}
    end
  end

  def handle_call({:recycle, reason, opts}, _from, state) do
    case recycle_driver(state, to_string(reason), opts) do
      {:ok, state, recycle_info} -> {:reply, {:ok, recycle_info}, state}
      {:error, message, state} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call(:metadata, _from, state) do
    metadata =
      %{
        v_daemon: :enabled,
        v_daemon_mode: state.mode,
        v_daemon_driver: state.driver,
        v_daemon_started_at: DateTime.to_iso8601(state.started_at),
        v_daemon_generation_retention: state.generation_retention,
        v_daemon_recycle_after_generations: state.recycle_after_generations,
        v_daemon_active_generation: state.active_generation,
        v_daemon_loaded_generations: state.loaded_generations |> Map.keys() |> Enum.sort(),
        v_daemon_loaded_generation_count: map_size(state.loaded_generations),
        v_daemon_load_count: state.load_count,
        v_daemon_unload_count: state.unload_count,
        v_daemon_recycle_count: state.recycle_count,
        v_daemon_failed_load_count: state.failed_load_count,
        v_daemon_failed_unload_count: state.failed_unload_count,
        v_daemon_loads_since_recycle: state.loads_since_recycle,
        v_daemon_last_load: state.last_load,
        v_daemon_last_unload: state.last_unload,
        v_daemon_last_recycle: state.last_recycle,
        v_daemon_last_error: state.last_error
      }
      |> Map.merge(safe_driver_metadata(state))

    {:reply, metadata, state}
  end

  def handle_call(:close, _from, state) do
    close_driver(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    close_driver(state)
  end

  defp enforce_generation_policy(state, active_record, opts) do
    with {:ok, state, retired} <- unload_retired_generations(state, active_record, opts),
         {:ok, state, recycle} <- maybe_recycle_after_threshold(state, active_record, opts) do
      {:ok, state, %{retired: retired, recycle: recycle}}
    end
  end

  defp unload_retired_generations(%{generation_retention: retention} = state, active_record, opts)
       when is_integer(retention) and retention > 0 do
    generations =
      state.loaded_generations
      |> Map.values()
      |> Enum.sort_by(&Map.get(&1, :load_index, 0), :desc)

    retire =
      generations
      |> Enum.drop(retention)
      |> Enum.reject(&(&1.generation == active_record.generation))

    Enum.reduce_while(retire, {:ok, state, []}, fn record, {:ok, state, retired} ->
      case unload_record(state, record, opts) do
        {:ok, state, unload_info} ->
          {:cont, {:ok, state, retired ++ [unload_info]}}

        {:error, message, state} ->
          case recycle_and_reload(
                 state,
                 active_record,
                 "unload_failed:generation_#{record.generation}",
                 opts
               ) do
            {:ok, state, recycle_info} ->
              {:halt, {:ok, state, retired ++ [%{recycle: recycle_info, error: message}]}}

            {:error, recycle_message, state} ->
              {:halt, {:error, "#{message}; recycle failed: #{recycle_message}", state}}
          end
      end
    end)
  end

  defp unload_retired_generations(state, _active_record, _opts), do: {:ok, state, []}

  defp maybe_recycle_after_threshold(
         %{recycle_after_generations: max, loads_since_recycle: count} = state,
         active_record,
         opts
       )
       when is_integer(max) and max > 0 and count >= max do
    case recycle_and_reload(state, active_record, "max_generations=#{max}", opts) do
      {:ok, state, recycle_info} -> {:ok, state, recycle_info}
      {:error, message, state} -> {:error, message, state}
    end
  end

  defp maybe_recycle_after_threshold(state, _active_record, _opts), do: {:ok, state, nil}

  defp unload_record(state, record, opts) do
    case state.driver.unload(state.driver_state, record, opts) do
      {:ok, unload_info, driver_state} ->
        loaded_generations = Map.delete(state.loaded_generations, record.generation)

        active_generation =
          if state.active_generation == record.generation do
            loaded_generations |> Map.keys() |> Enum.sort(:desc) |> List.first()
          else
            state.active_generation
          end

        info =
          %{
            generation: record.generation,
            artifact_path: Map.get(record, :artifact_path),
            unloaded?: true,
            at: DateTime.utc_now() |> DateTime.to_iso8601()
          }
          |> Map.merge(unload_info)

        state = %{
          state
          | driver_state: driver_state,
            loaded_generations: loaded_generations,
            active_generation: active_generation,
            unload_count: state.unload_count + 1,
            last_unload: info,
            last_error: nil
        }

        {:ok, state, info}

      {:error, message, driver_state} ->
        state = %{
          state
          | driver_state: driver_state,
            failed_unload_count: state.failed_unload_count + 1,
            last_error: message
        }

        {:error, message, state}
    end
  end

  defp recycle_and_reload(state, active_record, reason, opts) do
    case recycle_driver(state, reason, opts) do
      {:ok, state, recycle_info} ->
        with {:ok, artifact, driver_state} <-
               state.driver.build(state.driver_state, active_record, opts),
             state = %{state | driver_state: driver_state},
             {:ok, load_info, driver_state} <-
               state.driver.load(state.driver_state, artifact, opts) do
          record =
            artifact
            |> Map.merge(load_info)
            |> Map.put(:loaded_at, DateTime.utc_now() |> DateTime.to_iso8601())
            |> Map.put(:load_index, state.load_sequence + 1)

          state = %{
            state
            | driver_state: driver_state,
              loaded_generations: %{record.generation => record},
              active_generation: record.generation,
              load_sequence: state.load_sequence + 1,
              loads_since_recycle: 1,
              last_load: summarize_record(record),
              last_error: nil
          }

          {:ok, state, recycle_info}
        else
          {:error, message, driver_state} ->
            state = %{
              state
              | driver_state: driver_state,
                failed_load_count: state.failed_load_count + 1,
                last_error: message
            }

            {:error, message, state}
        end

      {:error, message, state} ->
        {:error, message, state}
    end
  end

  defp recycle_driver(state, reason, opts) do
    case state.driver.recycle(state.driver_state, reason, opts) do
      {:ok, recycle_info, driver_state} ->
        info =
          %{
            reason: reason,
            at: DateTime.utc_now() |> DateTime.to_iso8601()
          }
          |> Map.merge(recycle_info)

        state = %{
          state
          | driver_state: driver_state,
            loaded_generations: %{},
            active_generation: nil,
            recycle_count: state.recycle_count + 1,
            loads_since_recycle: 0,
            last_recycle: info,
            last_error: nil
        }

        {:ok, state, info}

      {:error, message, driver_state} ->
        state = %{state | driver_state: driver_state, last_error: message}
        {:error, message, state}
    end
  end

  defp summarize_record(record) do
    %{
      generation: record.generation,
      source_path: Map.get(record, :source_path),
      source_sha256: Map.get(record, :source_sha256),
      artifact_path: Map.get(record, :artifact_path),
      symbol: Map.get(record, :symbol),
      loaded_at: Map.get(record, :loaded_at),
      load_index: Map.get(record, :load_index),
      load_elapsed_us: Map.get(record, :load_elapsed_us)
    }
  end

  defp safe_driver_metadata(state) do
    state.driver.metadata(state.driver_state)
  rescue
    error -> %{v_daemon_driver_error: Exception.message(error)}
  end

  defp close_driver(%{driver: driver, driver_state: driver_state}) do
    driver.stop(driver_state)
  rescue
    _ -> :ok
  end
end
