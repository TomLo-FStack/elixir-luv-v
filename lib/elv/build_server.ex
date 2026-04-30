defmodule Elv.BuildServer do
  @moduledoc false

  use GenServer

  defstruct [
    :tmp_dir,
    generation: 0,
    cache: %{},
    last_artifact: nil,
    cache_hits: 0,
    cache_misses: 0
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def render(pid, imports, declarations, body) do
    GenServer.call(pid, {:render, imports, declarations, body})
  end

  def metadata(pid), do: GenServer.call(pid, :metadata)

  def close(pid) do
    GenServer.stop(pid, :normal, :infinity)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    opts = Enum.into(opts, %{})
    tmp_dir = Map.fetch!(opts, :tmp_dir)

    {:ok, %__MODULE__{tmp_dir: tmp_dir}}
  end

  @impl true
  def handle_call({:render, imports, declarations, body}, _from, state) do
    source = render_source(imports, declarations, body)
    source_hash = Elv.Form.sha256(source)

    case Map.fetch(state.cache, source_hash) do
      {:ok, artifact} ->
        state = %{state | last_artifact: artifact, cache_hits: state.cache_hits + 1}
        {:reply, {:ok, artifact}, state}

      :error ->
        generation = state.generation + 1
        path = Path.join(state.tmp_dir, "session_#{generation}.v")
        File.write!(path, source)

        artifact = %{
          generation: generation,
          path: path,
          source: source,
          source_sha256: source_hash
        }

        state = %{
          state
          | generation: generation,
            cache: Map.put(state.cache, source_hash, artifact),
            last_artifact: artifact,
            cache_misses: state.cache_misses + 1
        }

        {:reply, {:ok, artifact}, state}
    end
  rescue
    error ->
      {:reply, {:error, Exception.message(error)}, state}
  end

  def handle_call(:metadata, _from, state) do
    metadata = %{
      generation: state.generation,
      build_cache_entries: map_size(state.cache),
      build_cache_hits: state.cache_hits,
      build_cache_misses: state.cache_misses,
      last_source_path: last_artifact_field(state.last_artifact, :path),
      last_source_sha256: last_artifact_field(state.last_artifact, :source_sha256)
    }

    {:reply, metadata, state}
  end

  def render_source(imports, declarations, body) do
    imports_text = join_blocks(imports)
    declarations_text = join_blocks(declarations)
    body_text = indent_body(body)

    """
    module main

    #{imports_text}

    #{declarations_text}

    fn main() {
    #{body_text}
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

  defp last_artifact_field(nil, _key), do: nil
  defp last_artifact_field(artifact, key), do: Map.get(artifact, key)
end
