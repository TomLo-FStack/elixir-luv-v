defmodule Elv.Engine do
  @moduledoc false

  defstruct [
    :v_path,
    :cwd,
    :tmp_dir,
    :seq,
    :imports,
    :decls,
    :body,
    :previous_output
  ]

  @hard_timeout_ms 30_000

  def start(v_path, cwd, opts \\ []) do
    tmp_dir = make_tmp_dir(Keyword.get(opts, :tmp_root))

    {:ok,
     %__MODULE__{
       v_path: v_path,
       cwd: cwd,
       tmp_dir: tmp_dir,
       seq: 0,
       imports: [],
       decls: [],
       body: [],
       previous_output: ""
     }}
  rescue
    error -> {:error, Exception.message(error)}
  end

  def close(%__MODULE__{tmp_dir: tmp_dir}) do
    if is_binary(tmp_dir), do: File.rm_rf(tmp_dir)
    :ok
  rescue
    _ -> :ok
  end

  def restart(%__MODULE__{} = engine, opts \\ []) do
    v_path = engine.v_path
    cwd = engine.cwd
    close(engine)
    start(v_path, cwd, opts)
  end

  def eval(engine, code, opts \\ [])

  def eval(%__MODULE__{} = engine, code, opts) do
    code = String.trim(code)

    cond do
      code == "" ->
        {:ok, "", 0, engine}

      main_function?(code) ->
        {:error, "Do not define fn main() inside the REPL session; use :run for full V programs.",
         engine}

      import?(code) ->
        add_import(engine, code, opts)

      declaration?(code) ->
        add_declaration(engine, code, opts)

      true ->
        eval_expression_or_statement(engine, code, opts)
    end
  end

  def run_v(%__MODULE__{} = engine, args, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @hard_timeout_ms)

    task =
      Task.async(fn ->
        System.cmd(engine.v_path, args,
          cd: engine.cwd,
          env: command_env(engine),
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> {normalize_output(output), status}
      nil -> {"command timed out after #{timeout_ms} ms", 124}
    end
  rescue
    error -> {Exception.message(error), 1}
  end

  def split_forms(code, scanner \\ Elv.Scanner) do
    {forms, pending} =
      code
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.reduce({[], []}, fn line, {forms, pending} ->
        cond do
          pending == [] and String.trim(line) == "" ->
            {forms, pending}

          pending == [] and String.match?(line, ~r/^\s*module\s+\w+/) ->
            {forms, pending}

          true ->
            pending = [line | pending]
            form = pending |> Enum.reverse() |> Enum.join("\n")

            if scanner.complete?(form) do
              {[form | forms], []}
            else
              {forms, pending}
            end
        end
      end)

    forms =
      case pending do
        [] -> forms
        _ -> [pending |> Enum.reverse() |> Enum.join("\n") | forms]
      end

    forms
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp add_import(engine, code, opts) do
    imports = Enum.uniq(engine.imports ++ [code])

    case run_candidate(engine, imports, engine.decls, engine.body, opts) do
      {:ok, output, elapsed, engine} ->
        {:ok, delta(engine.previous_output, output), elapsed,
         %{engine | imports: imports, previous_output: output}}

      {:error, message, engine} ->
        {:error, message, engine}
    end
  end

  defp add_declaration(engine, code, opts) do
    decls = engine.decls ++ [code]

    case run_candidate(engine, engine.imports, decls, engine.body, opts) do
      {:ok, output, elapsed, engine} ->
        {:ok, delta(engine.previous_output, output), elapsed,
         %{engine | decls: decls, previous_output: output}}

      {:error, message, engine} ->
        {:error, message, engine}
    end
  end

  defp eval_expression_or_statement(engine, code, opts) do
    expression_body = engine.body ++ ["println(#{code})"]

    case run_candidate(engine, engine.imports, engine.decls, expression_body, opts) do
      {:ok, output, elapsed, engine} ->
        {:ok, delta(engine.previous_output, output), elapsed,
         %{engine | body: expression_body, previous_output: output}}

      {:error, expr_message, engine} ->
        statement_body = engine.body ++ [code]

        case run_candidate(engine, engine.imports, engine.decls, statement_body, opts) do
          {:ok, output, elapsed, engine} ->
            {:ok, delta(engine.previous_output, output), elapsed,
             %{engine | body: statement_body, previous_output: output}}

          {:error, stmt_message, engine} ->
            message =
              if String.contains?(stmt_message, "expression evaluated but not used") do
                expr_message
              else
                stmt_message
              end

            {:error, message, engine}
        end
    end
  end

  defp run_candidate(engine, imports, decls, body, opts) do
    seq = engine.seq + 1
    source = render(imports, decls, body)
    path = Path.join(engine.tmp_dir, "session_#{seq}.v")
    File.write!(path, source)

    case run_v_file(engine, path, opts) do
      {:ok, output, elapsed} -> {:ok, output, elapsed, %{engine | seq: seq}}
      {:error, message} -> {:error, message, %{engine | seq: seq}}
    end
  rescue
    error -> {:error, Exception.message(error), engine}
  end

  defp run_v_file(engine, path, opts) do
    hard_timeout_ms = Keyword.get(opts, :hard_timeout_ms, @hard_timeout_ms)
    started_us = System.monotonic_time(:microsecond)

    task =
      Task.async(fn ->
        System.cmd(engine.v_path, ["-w", "-n", "-nocolor", "run", path],
          cd: engine.cwd,
          env: command_env(engine),
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, hard_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, normalize_output(output), System.monotonic_time(:microsecond) - started_us}

      {:ok, {output, status}} ->
        {:error, "v exited with status #{status}\n#{normalize_output(output)}"}

      nil ->
        {:error, "Evaluation timed out after #{hard_timeout_ms} ms."}
    end
  end

  defp render(imports, decls, body) do
    imports_text = join_blocks(imports)
    decls_text = join_blocks(decls)
    body_text = indent_body(body)

    """
    module main

    #{imports_text}

    #{decls_text}

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

  defp delta(previous, current) do
    if String.starts_with?(current, previous) do
      binary_part(current, byte_size(previous), byte_size(current) - byte_size(previous))
    else
      current
    end
  end

  defp normalize_output(output) do
    String.replace(output, "\r\n", "\n")
  end

  defp import?(code), do: String.match?(code, ~r/^\s*import(\s|\()/)

  defp declaration?(code) do
    normalized =
      code
      |> String.trim_leading()
      |> strip_leading_attributes()

    String.match?(
      normalized,
      ~r/^(pub\s+)?(fn|struct|enum|interface|type|const)\b|^const\s*\(|^__global\b/
    )
  end

  defp main_function?(code), do: String.match?(code, ~r/^\s*(pub\s+)?fn\s+main\s*\(/)

  defp strip_leading_attributes(code) do
    code
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim_leading(&1) |> String.starts_with?("@[")))
    |> Enum.join("\n")
  end

  defp make_tmp_dir(nil) do
    System.get_env("ELV_TMP_ROOT")
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> Path.join(System.tmp_dir!(), "elv")
    end
    |> make_tmp_dir()
  end

  defp make_tmp_dir(root) do
    root = Path.expand(root)
    dir = Path.join(root, "session_" <> unique_id())
    File.mkdir_p!(dir)
    dir
  end

  defp command_env(engine) do
    path = System.get_env("PATH", "")
    sep = if windows?(), do: ";", else: ":"
    v_dir = Path.dirname(engine.v_path)
    [{"PATH", v_dir <> sep <> path}, {"VQUIET", "1"}]
  end

  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end
end
