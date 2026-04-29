defmodule Elv.Scanner do
  @moduledoc false

  @pairs %{"(" => ")", "[" => "]", "{" => "}"}
  @closers MapSet.new(Map.values(@pairs))

  def complete?(source) do
    case scan(source) do
      %{string: nil, block_comment: 0, stack: []} -> true
      _ -> false
    end
  end

  defp scan(source) do
    source
    |> String.graphemes()
    |> do_scan(%{
      stack: [],
      string: nil,
      escape: false,
      line_comment: false,
      block_comment: 0,
      prev: nil
    })
  end

  defp do_scan([], state), do: Map.take(state, [:stack, :string, :block_comment])

  defp do_scan(["\r" | rest], state), do: do_scan(rest, state)

  defp do_scan(["\n" | rest], state) do
    do_scan(rest, %{state | line_comment: false, prev: "\n"})
  end

  defp do_scan([ch | rest], %{line_comment: true} = state) do
    do_scan(rest, %{state | prev: ch})
  end

  defp do_scan([ch | rest], %{block_comment: depth} = state) when depth > 0 do
    cond do
      state.prev == "/" and ch == "*" ->
        do_scan(rest, %{state | block_comment: depth + 1, prev: ch})

      state.prev == "*" and ch == "/" ->
        do_scan(rest, %{state | block_comment: depth - 1, prev: ch})

      true ->
        do_scan(rest, %{state | prev: ch})
    end
  end

  defp do_scan([ch | rest], %{string: quote, escape: escape?} = state) when not is_nil(quote) do
    cond do
      escape? ->
        do_scan(rest, %{state | escape: false, prev: ch})

      ch == "\\" and quote == "\"" ->
        do_scan(rest, %{state | escape: true, prev: ch})

      ch == quote ->
        do_scan(rest, %{state | string: nil, prev: ch})

      true ->
        do_scan(rest, %{state | prev: ch})
    end
  end

  defp do_scan([ch | rest], state) do
    cond do
      state.prev == "/" and ch == "/" ->
        do_scan(rest, %{state | line_comment: true, prev: ch})

      state.prev == "/" and ch == "*" ->
        do_scan(rest, %{state | block_comment: 1, prev: ch})

      ch in ["\"", "'"] ->
        do_scan(rest, %{state | string: ch, prev: ch})

      Map.has_key?(@pairs, ch) ->
        do_scan(rest, %{state | stack: [@pairs[ch] | state.stack], prev: ch})

      MapSet.member?(@closers, ch) ->
        stack =
          case state.stack do
            [^ch | rest_stack] -> rest_stack
            other -> other
          end

        do_scan(rest, %{state | stack: stack, prev: ch})

      true ->
        do_scan(rest, %{state | prev: ch})
    end
  end
end
