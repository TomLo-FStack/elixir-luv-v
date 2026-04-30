defmodule Elv.Form do
  @moduledoc false

  @side_effect_pattern ~r/\b(print|println|eprint|eprintln|panic)\s*\(|\b(os|io|fs|net|http|time|rand)\./
  @declaration_pattern ~r/^(pub\s+)?(fn|struct|enum|interface|type|const)\b|^const\s*\(|^__global\b/

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
end
