defmodule Elv.EditorServer do
  @moduledoc false

  use GenServer

  alias Elv.Scanner

  defstruct buffer: [],
            history: [],
            scanner: Scanner

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def submit_line(pid, line) when is_binary(line) do
    GenServer.call(pid, {:submit_line, normalize_line(line)})
  end

  def buffering?(pid), do: GenServer.call(pid, :buffering?)

  def flush(pid), do: GenServer.call(pid, :flush)

  def record(pid, source) when is_binary(source) do
    GenServer.call(pid, {:record, source})
  end

  def history(pid), do: GenServer.call(pid, :history)

  def search(pid, query, opts \\ []) when is_binary(query) do
    GenServer.call(pid, {:search, query, opts})
  end

  def close(pid) do
    GenServer.stop(pid, :normal, :infinity)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    opts = Enum.into(opts, %{})

    {:ok,
     %__MODULE__{
       scanner: Map.get(opts, :scanner, Scanner),
       history: Map.get(opts, :history, [])
     }}
  end

  @impl true
  def handle_call({:submit_line, line}, _from, %{buffer: []} = state) do
    case classify_first_line(line, state.scanner) do
      :blank ->
        {:reply, :blank, state}

      :incomplete ->
        {:reply, :incomplete, %{state | buffer: [line]}}

      ready ->
        {:reply, ready, state}
    end
  end

  def handle_call({:submit_line, line}, _from, state) do
    buffer = state.buffer ++ [line]
    code = Enum.join(buffer, "\n")

    if state.scanner.complete?(code) do
      {:reply, {:ready, {:code, code}}, %{state | buffer: []}}
    else
      {:reply, :incomplete, %{state | buffer: buffer}}
    end
  end

  def handle_call(:buffering?, _from, state) do
    {:reply, state.buffer != [], state}
  end

  def handle_call(:flush, _from, %{buffer: []} = state) do
    {:reply, :empty, state}
  end

  def handle_call(:flush, _from, state) do
    {:reply, {:code, Enum.join(state.buffer, "\n")}, %{state | buffer: []}}
  end

  def handle_call({:record, source}, _from, state) do
    {:reply, :ok, %{state | history: state.history ++ [source]}}
  end

  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  def handle_call({:search, query, opts}, _from, state) do
    {:reply, search_history(state.history, query, opts), state}
  end

  defp classify_first_line(line, scanner) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :blank

      trimmed in ["exit", ":q", ":quit"] ->
        {:ready, {:command, :quit}}

      String.starts_with?(trimmed, ":") ->
        {:ready, {:command, {:colon, trimmed}}}

      String.starts_with?(trimmed, "?") ->
        {:ready, {:command, {:help, String.trim_leading(trimmed, "?") |> String.trim()}}}

      String.starts_with?(trimmed, ";") ->
        {:ready, {:command, {:shell, String.trim_leading(trimmed, ";") |> String.trim()}}}

      String.starts_with?(trimmed, "]") ->
        {:ready, {:command, {:pkg, String.trim_leading(trimmed, "]") |> String.trim()}}}

      scanner.complete?(line) ->
        {:ready, {:code, line}}

      true ->
        :incomplete
    end
  end

  defp search_history(history, query, opts) do
    query = String.trim(query)
    limit = Keyword.get(opts, :limit, 20)
    case_sensitive? = Keyword.get(opts, :case_sensitive?, false)

    if query == "" do
      []
    else
      needle = comparable(query, case_sensitive?)

      history
      |> Enum.with_index(1)
      |> Enum.filter(fn {source, _index} ->
        String.contains?(comparable(source, case_sensitive?), needle)
      end)
      |> Enum.map(fn {source, index} -> %{index: index, source: source} end)
      |> Enum.reverse()
      |> Enum.take(limit)
    end
  end

  defp comparable(value, true), do: value
  defp comparable(value, false), do: String.downcase(value)

  defp normalize_line(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end
end
