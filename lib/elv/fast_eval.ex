defmodule Elv.FastEval do
  @moduledoc false

  defstruct imports: MapSet.new(), vars: %{}, functions: %{}

  @max_source_bytes 500
  @min_int -2_147_483_648
  @max_int 2_147_483_647

  def new, do: %__MODULE__{}

  def eval(source, state \\ new()) when is_binary(source) do
    started_us = System.monotonic_time(:microsecond)
    source = String.trim(source)

    with true <- byte_size(source) <= @max_source_bytes,
         {:ok, output, state} <- eval_source(source, state) do
      {:ok, output, System.monotonic_time(:microsecond) - started_us, state}
    else
      _ -> :error
    end
  end

  defp eval_source("", state), do: {:ok, "", state}

  defp eval_source("import " <> module, state) do
    module = String.trim(module)

    if simple_identifier?(module) do
      {:ok, "", %{state | imports: MapSet.put(state.imports, module)}}
    else
      :error
    end
  end

  defp eval_source(source, state) do
    cond do
      print_call = Regex.run(~r/^(print|println)\((.*)\)$/, source) ->
        [_, function, expression] = print_call

        with {:ok, value} <- eval_expression(expression, state) do
          output =
            case function do
              "print" -> format_value(value) |> String.trim_trailing("\n")
              "println" -> format_value(value)
            end

          {:ok, output, state}
        end

      declaration = Regex.run(~r/^(mut\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*(.+)$/, source) ->
        [_, mut, name, expression] = declaration

        with false <- Map.has_key?(state.vars, name),
             {:ok, value} <- eval_expression(expression, state) do
          {:ok, "", put_var(state, name, value, mutable?: mut != "")}
        else
          _ -> :error
        end

      reassignment =
          Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\s*(=|\+=|-=|\*=|\/=|%=|\^=)\s*(.+)$/, source) ->
        [_, name, operator, expression] = reassignment

        with {:ok, old_value, true} <- fetch_var(state, name),
             {:ok, value} <- eval_expression(expression, state),
             {:ok, value} <- apply_assignment(operator, old_value, value) do
          {:ok, "", put_var(state, name, value, mutable?: true)}
        else
          _ -> :error
        end

      increment = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\s*(\+\+|--)$/, source) ->
        [_, name, operator] = increment

        with {:ok, old_value, true} <- fetch_var(state, name),
             {:ok, value} <- apply_increment(operator, old_value) do
          {:ok, "", put_var(state, name, value, mutable?: true)}
        else
          _ -> :error
        end

      function = parse_add_function(source) ->
        {name, left, right} = function

        if Map.has_key?(state.functions, name) do
          :error
        else
          functions = Map.put(state.functions, name, {:add2, left, right})
          {:ok, "", %{state | functions: functions}}
        end

      true ->
        with {:ok, value} <- eval_expression(source, state) do
          {:ok, format_value(value), state}
        end
    end
  end

  defp parse_add_function(source) do
    case Regex.run(
           ~r/^fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s+int\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s+int\s*\)\s+int\s*\{\s*return\s+\2\s*\+\s*\3\s*\}$/,
           source
         ) do
      [_, name, left, right] -> {name, left, right}
      _ -> nil
    end
  end

  defp eval_expression(source, state) do
    with {:ok, tokens} <- tokenize(source),
         {:ok, value, []} <- parse_expression(tokens, state) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp tokenize(source), do: tokenize(String.to_charlist(source), [])

  defp tokenize([], tokens), do: {:ok, Enum.reverse(tokens)}

  defp tokenize([char | rest], tokens) when char in [?\s, ?\t, ?\r, ?\n],
    do: tokenize(rest, tokens)

  defp tokenize([char | rest], tokens) when char in [?+, ?-, ?*, ?/, ?%, ?^, ?(, ?), ?,, ?.],
    do: tokenize(rest, [char | tokens])

  defp tokenize([char | _rest], _tokens)
       when (char < ?0 or char > ?9) and
              (char < ?A or char > ?Z) and
              (char < ?a or char > ?z) and
              char != ?_,
       do: :error

  defp tokenize([char | _] = chars, tokens) when char >= ?0 and char <= ?9 do
    {digits, rest} = Enum.split_while(chars, &(&1 >= ?0 and &1 <= ?9))
    tokenize(rest, [{:int, List.to_integer(digits)} | tokens])
  rescue
    _ -> :error
  end

  defp tokenize([char | _] = chars, tokens)
       when (char >= ?A and char <= ?Z) or (char >= ?a and char <= ?z) or char == ?_ do
    {identifier, rest} =
      Enum.split_while(chars, fn item ->
        (item >= ?A and item <= ?Z) or
          (item >= ?a and item <= ?z) or
          (item >= ?0 and item <= ?9) or item == ?_
      end)

    tokenize(rest, [{:identifier, List.to_string(identifier)} | tokens])
  end

  defp parse_expression(tokens, state) do
    with {:ok, value, rest} <- parse_term(tokens, state),
         do: parse_expression_tail(value, rest, state)
  end

  defp parse_expression_tail(value, [?+ | rest], state) do
    with {:ok, rhs, rest} <- parse_term(rest, state),
         {:ok, value} <- add(value, rhs),
         do: parse_expression_tail(value, rest, state)
  end

  defp parse_expression_tail(value, [?- | rest], state) do
    with {:ok, rhs, rest} <- parse_term(rest, state),
         {:ok, value} <- subtract(value, rhs),
         do: parse_expression_tail(value, rest, state)
  end

  defp parse_expression_tail({:int, left}, [?^ | rest], state) do
    with {:ok, {:int, right}, rest} <- parse_term(rest, state),
         {:ok, value} <- int_result(Bitwise.bxor(left, right)),
         do: parse_expression_tail({:int, value}, rest, state)
  end

  defp parse_expression_tail(value, rest, _state), do: {:ok, value, rest}

  defp parse_term(tokens, state) do
    with {:ok, value, rest} <- parse_factor(tokens, state),
         do: parse_term_tail(value, rest, state)
  end

  defp parse_term_tail(value, [?* | rest], state) do
    with {:ok, rhs, rest} <- parse_factor(rest, state),
         {:ok, value} <- multiply(value, rhs),
         do: parse_term_tail(value, rest, state)
  end

  defp parse_term_tail(value, [?/ | rest], state) do
    with {:ok, rhs, rest} <- parse_factor(rest, state),
         {:ok, value} <- divide(value, rhs),
         do: parse_term_tail(value, rest, state)
  end

  defp parse_term_tail(value, [?% | rest], state) do
    with {:ok, rhs, rest} <- parse_factor(rest, state),
         {:ok, value} <- remainder(value, rhs),
         do: parse_term_tail(value, rest, state)
  end

  defp parse_term_tail(value, rest, _state), do: {:ok, value, rest}

  defp parse_factor([{:int, value} | rest], _state), do: {:ok, {:int, value}, rest}

  defp parse_factor([{:identifier, module}, ?., {:identifier, function}, ?( | rest], state) do
    parse_module_call(module, function, rest, state)
  end

  defp parse_factor([{:identifier, name}, ?( | rest], state) do
    parse_function_call(name, rest, state)
  end

  defp parse_factor([{:identifier, name} | rest], state) do
    case fetch_var(state, name) do
      {:ok, value, _mutable?} -> {:ok, value, rest}
      _ -> :error
    end
  end

  defp parse_factor([?+ | rest], state), do: parse_factor(rest, state)

  defp parse_factor([?- | rest], state) do
    with {:ok, value, rest} <- parse_factor(rest, state),
         {:ok, value} <- negate(value),
         do: {:ok, value, rest}
  end

  defp parse_factor([?( | rest], state) do
    with {:ok, value, [?) | rest]} <- parse_expression(rest, state), do: {:ok, value, rest}
  end

  defp parse_factor(_tokens, _state), do: :error

  defp parse_function_call(name, tokens, state) do
    with {:ok, left, [?, | rest]} <- parse_expression(tokens, state),
         {:ok, right, [?) | rest]} <- parse_expression(rest, state),
         {:ok, value} <- apply_function(name, left, right, state) do
      {:ok, value, rest}
    end
  end

  defp parse_module_call("math", "sqrt", tokens, state) do
    with true <- MapSet.member?(state.imports, "math"),
         {:ok, value, [?) | rest]} <- parse_expression(tokens, state),
         {:ok, value} <- sqrt(value) do
      {:ok, value, rest}
    else
      _ -> :error
    end
  end

  defp parse_module_call(_module, _function, _tokens, _state), do: :error

  defp apply_function(name, left, right, state) do
    case Map.fetch(state.functions, name) do
      {:ok, {:add2, _left_name, _right_name}} -> add(left, right)
      :error -> :error
    end
  end

  defp apply_assignment("=", _old_value, value), do: {:ok, value}
  defp apply_assignment("+=", old_value, value), do: add(old_value, value)
  defp apply_assignment("-=", old_value, value), do: subtract(old_value, value)
  defp apply_assignment("*=", old_value, value), do: multiply(old_value, value)
  defp apply_assignment("/=", old_value, value), do: divide(old_value, value)
  defp apply_assignment("%=", old_value, value), do: remainder(old_value, value)

  defp apply_assignment("^=", {:int, left}, {:int, right}) do
    with {:ok, value} <- int_result(Bitwise.bxor(left, right)), do: {:ok, {:int, value}}
  end

  defp apply_assignment(_operator, _old_value, _value), do: :error

  defp apply_increment("++", value), do: add(value, {:int, 1})
  defp apply_increment("--", value), do: subtract(value, {:int, 1})

  defp add({:int, left}, {:int, right}) do
    with {:ok, value} <- int_result(left + right), do: {:ok, {:int, value}}
  end

  defp add({:float, left}, {:float, right}), do: {:ok, {:float, left + right}}
  defp add({:float, left}, {:int, right}), do: {:ok, {:float, left + right}}
  defp add({:int, left}, {:float, right}), do: {:ok, {:float, left + right}}

  defp subtract({:int, left}, {:int, right}) do
    with {:ok, value} <- int_result(left - right), do: {:ok, {:int, value}}
  end

  defp subtract({:float, left}, {:float, right}), do: {:ok, {:float, left - right}}
  defp subtract({:float, left}, {:int, right}), do: {:ok, {:float, left - right}}
  defp subtract({:int, left}, {:float, right}), do: {:ok, {:float, left - right}}

  defp multiply({:int, left}, {:int, right}) do
    with {:ok, value} <- int_result(left * right), do: {:ok, {:int, value}}
  end

  defp multiply({:float, left}, {:float, right}), do: {:ok, {:float, left * right}}
  defp multiply({:float, left}, {:int, right}), do: {:ok, {:float, left * right}}
  defp multiply({:int, left}, {:float, right}), do: {:ok, {:float, left * right}}

  defp divide({:int, _left}, {:int, 0}), do: :error

  defp divide({:int, left}, {:int, right}) do
    with {:ok, value} <- int_result(div(left, right)), do: {:ok, {:int, value}}
  end

  defp divide({_type, _left}, {:float, right}) when right == 0.0, do: :error
  defp divide({:float, left}, {:float, right}), do: {:ok, {:float, left / right}}
  defp divide({:float, left}, {:int, right}) when right != 0, do: {:ok, {:float, left / right}}
  defp divide({:int, left}, {:float, right}) when right != 0.0, do: {:ok, {:float, left / right}}

  defp remainder({:int, _left}, {:int, 0}), do: :error
  defp remainder({:int, left}, {:int, right}), do: {:ok, {:int, rem(left, right)}}
  defp remainder(_left, _right), do: :error

  defp negate({:int, value}) do
    with {:ok, value} <- int_result(-value), do: {:ok, {:int, value}}
  end

  defp negate({:float, value}), do: {:ok, {:float, -value}}

  defp sqrt({:int, value}) when value >= 0, do: {:ok, {:float, :math.sqrt(value)}}
  defp sqrt({:float, value}) when value >= 0.0, do: {:ok, {:float, :math.sqrt(value)}}
  defp sqrt(_value), do: :error

  defp format_value({:int, value}), do: Integer.to_string(value) <> "\n"

  defp format_value({:float, value}) do
    rounded = Float.round(value)

    if value == rounded do
      :erlang.float_to_binary(value, decimals: 1) <> "\n"
    else
      :erlang.float_to_binary(value, [:compact, decimals: 12]) <> "\n"
    end
  end

  defp fetch_var(state, name) do
    case Map.fetch(state.vars, name) do
      {:ok, %{value: value, mutable?: mutable?}} -> {:ok, value, mutable?}
      {:ok, value} -> {:ok, value, false}
      :error -> :error
    end
  end

  defp put_var(state, name, value, opts) do
    mutable? = Keyword.fetch!(opts, :mutable?)
    put_in(state.vars[name], %{value: value, mutable?: mutable?})
  end

  defp int_result(value) when value >= @min_int and value <= @max_int, do: {:ok, value}
  defp int_result(_value), do: :error

  defp simple_identifier?(value), do: String.match?(value, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
end
