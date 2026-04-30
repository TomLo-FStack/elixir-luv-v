defmodule Elv.Engine do
  @moduledoc false

  @behaviour Elv.ExecutionBackend

  alias Elv.BuildServer
  alias Elv.Form

  defstruct [
    :v_path,
    :cwd,
    :tmp_dir,
    :build_server,
    :seq,
    :imports,
    :decls,
    :body,
    :previous_output,
    :fast_eval,
    :fast_eval_hits,
    :fast_eval_misses,
    :fast_eval_us,
    :fallback_eval_count
  ]

  @hard_timeout_ms 30_000

  @impl true
  def start(v_path, cwd, opts \\ []) do
    tmp_dir = make_tmp_dir(Keyword.get(opts, :tmp_root))

    with {:ok, build_server} <- BuildServer.start_link(tmp_dir: tmp_dir) do
      {:ok,
       %__MODULE__{
         v_path: v_path,
         cwd: cwd,
         tmp_dir: tmp_dir,
         build_server: build_server,
         seq: 0,
         imports: [],
         decls: [],
         body: [],
         previous_output: "",
         fast_eval: Elv.FastEval.new(),
         fast_eval_hits: 0,
         fast_eval_misses: 0,
         fast_eval_us: 0,
         fallback_eval_count: 0
       }}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def close(%__MODULE__{tmp_dir: tmp_dir, build_server: build_server}) do
    if is_pid(build_server), do: BuildServer.close(build_server)
    if is_binary(tmp_dir), do: File.rm_rf(tmp_dir)
    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def restart(%__MODULE__{} = engine, opts \\ []) do
    v_path = engine.v_path
    cwd = engine.cwd
    close(engine)
    start(v_path, cwd, opts)
  end

  def eval(engine, code, opts \\ [])

  @impl true
  def eval(%__MODULE__{} = engine, code, opts) do
    code = String.trim(code)

    cond do
      code == "" ->
        {:ok, "", 0, engine}

      Form.main_function?(code) ->
        {:error, "Do not define fn main() inside the REPL session; use :run for full V programs.",
         engine}

      Form.import?(code) ->
        add_fast_or_import(engine, code, opts)

      Form.declaration?(code) ->
        add_fast_or_declaration(engine, code, opts)

      true ->
        eval_fast_or_expression(engine, code, opts)
    end
  end

  @impl true
  def run_v(%__MODULE__{} = engine, args, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @hard_timeout_ms)

    task =
      Task.async(fn ->
        command_result(fn ->
          System.cmd(engine.v_path, args,
            cd: engine.cwd,
            env: command_env(engine),
            stderr_to_stdout: true
          )
        end)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, status}}} -> {normalize_output(output), status}
      {:ok, {:error, message}} -> {message, 1}
      nil -> {"command timed out after #{timeout_ms} ms", 124}
    end
  rescue
    error -> {Exception.message(error), 1}
  end

  @impl true
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

  @impl true
  def metadata(%__MODULE__{} = engine) do
    %{
      backend: :replay,
      v_path: engine.v_path,
      cwd: engine.cwd,
      tmp_dir: engine.tmp_dir,
      tmp_root: Path.dirname(engine.tmp_dir),
      generation: engine.seq,
      imports: length(engine.imports),
      declarations: length(engine.decls),
      body_forms: length(engine.body),
      fast_eval_hits: engine.fast_eval_hits,
      fast_eval_misses: engine.fast_eval_misses,
      fast_eval_us: engine.fast_eval_us,
      fallback_eval_count: engine.fallback_eval_count,
      capabilities: %{
        replay: true,
        fast_eval: true,
        worker_isolation: false,
        lsp: false,
        snapshots: true,
        live_reload: false,
        plugins: false
      }
    }
    |> Map.merge(BuildServer.metadata(engine.build_server))
  end

  defp add_fast_or_import(engine, code, opts) do
    case Elv.FastEval.eval(code, engine.fast_eval) do
      {:ok, output, elapsed_us, fast_eval} ->
        imports = Enum.uniq(engine.imports ++ [code])

        engine =
          engine
          |> record_fast_hit(elapsed_us, fast_eval)
          |> Map.merge(%{
            imports: imports,
            previous_output: engine.previous_output <> output
          })

        {:ok, output, elapsed_us, engine}

      :error ->
        engine |> record_fast_miss() |> add_import(code, opts)
    end
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

  defp add_fast_or_declaration(engine, code, opts) do
    case Elv.FastEval.eval(code, engine.fast_eval) do
      {:ok, output, elapsed_us, fast_eval} ->
        decls = engine.decls ++ [code]

        engine =
          engine
          |> record_fast_hit(elapsed_us, fast_eval)
          |> Map.merge(%{
            decls: decls,
            previous_output: engine.previous_output <> output
          })

        {:ok, output, elapsed_us, engine}

      :error ->
        engine |> record_fast_miss() |> add_declaration(code, opts)
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

  defp eval_fast_or_expression(engine, code, opts) do
    case Elv.FastEval.eval(code, engine.fast_eval) do
      {:ok, output, elapsed_us, fast_eval} ->
        engine =
          engine
          |> record_fast_hit(elapsed_us, fast_eval)
          |> sync_fast_body(code, output)

        {:ok, output, elapsed_us, engine}

      :error ->
        engine |> record_fast_miss() |> eval_expression_or_statement(code, opts)
    end
  end

  defp sync_fast_body(engine, code, output) do
    body =
      cond do
        match?({:ok, _prefix, _expression}, Form.trailing_expression_sequence(code)) ->
          engine.body ++ Form.execution_body_forms(code)

        output != "" and Form.statement?(code) ->
          engine.body ++ [code]

        output != "" ->
          engine.body ++ ["println(#{code})"]

        Form.statement?(code) ->
          engine.body ++ [code]

        true ->
          engine.body
      end

    %{engine | body: body, previous_output: engine.previous_output <> output}
  end

  defp eval_expression_or_statement(engine, code, opts) do
    cond do
      match?({:ok, _prefix, _expression}, Form.trailing_expression_sequence(code)) ->
        eval_statement(engine, code, opts)

      Form.obvious_statement?(code) ->
        eval_statement(engine, code, opts)

      true ->
        eval_expression_then_statement(engine, code, opts)
    end
  end

  defp eval_expression_then_statement(engine, code, opts) do
    expression_body = engine.body ++ ["println(#{code})"]

    case run_candidate(engine, engine.imports, engine.decls, expression_body, opts) do
      {:ok, output, elapsed, engine} ->
        {:ok, delta(engine.previous_output, output), elapsed,
         %{engine | body: expression_body, previous_output: output}}

      {:error, expr_message, engine} ->
        case eval_statement(engine, code, opts) do
          {:ok, output, elapsed, engine} ->
            {:ok, output, elapsed, engine}

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

  defp eval_statement(engine, code, opts) do
    statement_body = engine.body ++ Form.execution_body_forms(code)

    case run_candidate(engine, engine.imports, engine.decls, statement_body, opts) do
      {:ok, output, elapsed, engine} ->
        {:ok, delta(engine.previous_output, output), elapsed,
         %{engine | body: statement_body, previous_output: output}}

      {:error, message, engine} ->
        {:error, message, engine}
    end
  end

  defp run_candidate(engine, imports, decls, body, opts) do
    engine = %{engine | fallback_eval_count: engine.fallback_eval_count + 1}

    case BuildServer.render(engine.build_server, imports, decls, body) do
      {:ok, artifact} ->
        engine = %{engine | seq: artifact.generation}

        case run_v_file(engine, artifact.path, opts) do
          {:ok, output, elapsed} -> {:ok, output, elapsed, engine}
          {:error, message} -> {:error, message, engine}
        end

      {:error, message} ->
        {:error, message, engine}
    end
  rescue
    error -> {:error, Exception.message(error), engine}
  end

  defp run_v_file(engine, path, opts) do
    hard_timeout_ms = Keyword.get(opts, :hard_timeout_ms, @hard_timeout_ms)
    started_us = System.monotonic_time(:microsecond)

    task =
      Task.async(fn ->
        command_result(fn ->
          System.cmd(engine.v_path, ["-w", "-n", "-nocolor", "run", path],
            cd: engine.cwd,
            env: command_env(engine),
            stderr_to_stdout: true
          )
        end)
      end)

    case Task.yield(task, hard_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, 0}}} ->
        {:ok, normalize_output(output), System.monotonic_time(:microsecond) - started_us}

      {:ok, {:ok, {output, status}}} ->
        {:error, "v exited with status #{status}\n#{normalize_output(output)}"}

      {:ok, {:error, message}} ->
        {:error, message}

      nil ->
        {:error, "Evaluation timed out after #{hard_timeout_ms} ms."}
    end
  end

  defp delta(previous, current) do
    if String.starts_with?(current, previous) do
      binary_part(current, byte_size(previous), byte_size(current) - byte_size(previous))
    else
      current
    end
  end

  defp record_fast_hit(engine, elapsed_us, fast_eval) do
    %{
      engine
      | fast_eval: fast_eval,
        fast_eval_hits: engine.fast_eval_hits + 1,
        fast_eval_us: engine.fast_eval_us + elapsed_us
    }
  end

  defp record_fast_miss(engine) do
    %{engine | fast_eval_misses: engine.fast_eval_misses + 1}
  end

  defp normalize_output(output) do
    String.replace(output, "\r\n", "\n")
  end

  defp command_result(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, "command failed: #{inspect(reason)}"}
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
