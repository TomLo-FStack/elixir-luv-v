defmodule Elv.Form do
  @moduledoc false

  @side_effect_pattern ~r/\b(print|println|eprint|eprintln|panic)\s*\(|\b(os|io|fs|net|http|time|rand)\./
  @declaration_pattern ~r/^(pub\s+)?(fn|struct|enum|interface|type|const)\b|^const\s*\(|^__global\b/
  @assignment_pattern ~r/^(mut\s+)?[A-Za-z_][A-Za-z0-9_]*(\s*(:=|[+\-*\/%]?=)|\s*(\+\+|--)\b|\s*\[)/
  @control_statement_pattern ~r/^(if|for|match|assert|defer|return|break|continue|unsafe|lock|rlock)\b/
  @obvious_control_statement_pattern ~r/^(for|assert|defer|return|break|continue|unsafe|lock|rlock)\b/

  defstruct [
    :index,
    :kind,
    :source,
    :source_sha256,
    deterministic?: true,
    side_effecting?: false
  ]

  def classify(source) when is_binary(source) do
    trimmed = String.trim_leading(source)
    normalized = strip_leading_attributes(trimmed)

    cond do
      import?(trimmed) ->
        :import

      declaration?(normalized) ->
        :declaration

      true ->
        :execution
    end
  end

  def import?(source) when is_binary(source) do
    String.match?(source, ~r/^\s*import(\s|\()/)
  end

  def declaration?(source) when is_binary(source) do
    source
    |> String.trim_leading()
    |> strip_leading_attributes()
    |> String.match?(@declaration_pattern)
  end

  def main_function?(source) when is_binary(source) do
    String.match?(source, ~r/^\s*(pub\s+)?fn\s+main\s*\(/)
  end

  def side_effecting?(source) when is_binary(source) do
    String.match?(source, @side_effect_pattern)
  end

  def statement?(source) when is_binary(source) do
    trimmed = String.trim_leading(source)

    side_effecting?(source) or
      String.match?(trimmed, @assignment_pattern) or
      String.match?(trimmed, @control_statement_pattern)
  end

  def obvious_statement?(source) when is_binary(source) do
    trimmed = String.trim_leading(source)

    side_effecting?(source) or
      String.match?(trimmed, @assignment_pattern) or
      String.match?(trimmed, @obvious_control_statement_pattern)
  end

  def trailing_expression_sequence(source) when is_binary(source) do
    if simple_semicolon_sequence?(source) do
      parts =
        source
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      case parts do
        [_single] ->
          :error

        parts ->
          {prefix, [last]} = Enum.split(parts, -1)

          if expression_tail?(last) and Enum.all?(prefix, &sequence_prefix?/1) do
            {:ok, prefix, last}
          else
            :error
          end
      end
    else
      :error
    end
  end

  def execution_body_forms(source) when is_binary(source) do
    case trailing_expression_sequence(source) do
      {:ok, prefix, expression} ->
        prefix ++ ["println(#{expression})"]

      :error ->
        if statement?(source), do: [source], else: ["println(#{source})"]
    end
  end

  def deterministic?(source) when is_binary(source) do
    not side_effecting?(source)
  end

  def snapshot(source, index) when is_binary(source) and is_integer(index) do
    side_effecting? = side_effecting?(source)

    %__MODULE__{
      index: index,
      kind: classify(source),
      source: source,
      source_sha256: sha256(source),
      deterministic?: not side_effecting?,
      side_effecting?: side_effecting?
    }
  end

  def snapshot_map(source, index) do
    source
    |> snapshot(index)
    |> Map.from_struct()
  end

  def strip_leading_attributes(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim_leading(&1) |> String.starts_with?("@[")))
    |> Enum.join("\n")
  end

  def sha256(source) when is_binary(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end

  defp simple_semicolon_sequence?(source) do
    String.contains?(source, ";") and
      not String.contains?(source, "{") and
      not String.contains?(source, "}") and
      not String.contains?(source, "\n")
  end

  defp expression_tail?(source) do
    not import?(source) and not declaration?(source) and not statement?(source)
  end

  defp sequence_prefix?(source) do
    statement?(source) or declaration?(source) or import?(source)
  end
end
