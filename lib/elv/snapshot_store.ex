defmodule Elv.SnapshotStore do
  @moduledoc false

  defstruct [
    :root,
    :latest_path,
    enabled?: true,
    checkpoint_count: 0,
    last_path: nil,
    last_error: nil
  ]

  @schema_version 1

  def start(session_id, backend_metadata, opts \\ []) do
    enabled? = Keyword.get(opts, :enabled?, true)
    root = snapshot_root(session_id, backend_metadata, Keyword.get(opts, :root))

    store = %__MODULE__{
      root: root,
      latest_path: Path.join(root, "latest.term"),
      enabled?: enabled?
    }

    if enabled? do
      File.mkdir_p!(root)
    end

    {:ok, store}
  rescue
    error ->
      {:ok,
       %__MODULE__{
         root: nil,
         enabled?: false,
         last_error: Exception.message(error)
       }}
  end

  def put(%__MODULE__{enabled?: false} = store, _snapshot), do: {:ok, store}

  def put(%__MODULE__{} = store, snapshot) do
    checkpoint_count = store.checkpoint_count + 1
    path = Path.join(store.root, checkpoint_name(checkpoint_count))

    snapshot =
      snapshot
      |> Map.put(:schema_version, @schema_version)
      |> Map.put(:written_at, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put(:checkpoint, checkpoint_count)

    write_term!(path, snapshot)
    write_term!(store.latest_path, snapshot)

    {:ok, %{store | checkpoint_count: checkpoint_count, last_path: path, last_error: nil}}
  rescue
    error ->
      {:error, Exception.message(error), %{store | last_error: Exception.message(error)}}
  end

  def read_latest(%__MODULE__{enabled?: false}), do: {:error, :disabled}

  def read_latest(%__MODULE__{latest_path: path}) when is_binary(path) do
    read(path)
  end

  def read_latest(%__MODULE__{}), do: {:error, :disabled}

  def read(path) when is_binary(path) do
    with {:ok, binary} <- File.read(path) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def metadata(%__MODULE__{} = store) do
    %{
      snapshots: if(store.enabled?, do: :enabled, else: :disabled),
      snapshot_root: store.root,
      snapshot_latest: store.latest_path,
      snapshot_count: store.checkpoint_count,
      snapshot_last_path: store.last_path,
      snapshot_last_error: store.last_error
    }
  end

  defp snapshot_root(_session_id, _metadata, root) when is_binary(root) and root != "" do
    Path.expand(root)
  end

  defp snapshot_root(session_id, metadata, _root) do
    base =
      System.get_env("ELV_SNAPSHOT_ROOT")
      |> case do
        value when is_binary(value) and value != "" -> value
        _ -> Path.join(Map.get(metadata, :tmp_root) || System.tmp_dir!(), "elv_snapshots")
      end

    Path.join(Path.expand(base), "session_#{session_id}")
  end

  defp checkpoint_name(index) do
    "checkpoint_" <> String.pad_leading(Integer.to_string(index), 6, "0") <> ".term"
  end

  defp write_term!(path, term) do
    tmp_path = path <> ".tmp"
    File.write!(tmp_path, :erlang.term_to_binary(term))

    if File.exists?(path), do: File.rm!(path)
    File.rename!(tmp_path, path)
  end
end
