defmodule Elv.LspClient do
  @moduledoc false

  use GenServer

  alias Elv.JsonRpc

  @default_timeout_ms 5_000
  @default_request_timeout_ms 2_000

  defstruct [
    :command,
    :cwd,
    :port,
    :root_uri,
    :workspace_uri,
    :buffer,
    :request_timeout_ms,
    initialized?: false,
    next_id: 1,
    pending: %{},
    diagnostics: %{},
    last_error: nil
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def start_optional(opts \\ []) do
    case start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, message} when is_binary(message) -> {:disabled, message}
      {:error, reason} -> {:disabled, inspect(reason)}
    end
  end

  def completion(pid, uri, line, character, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_request_timeout_ms) + 1_000
    GenServer.call(pid, {:completion, uri, line, character, opts}, timeout)
  end

  def open_document(pid, uri, text, opts \\ []) do
    GenServer.call(pid, {:open_document, uri, text, opts})
  end

  def change_document(pid, uri, version, text) do
    GenServer.call(pid, {:change_document, uri, version, text})
  end

  def diagnostics(pid, uri \\ nil) do
    GenServer.call(pid, {:diagnostics, uri})
  end

  def metadata(pid), do: GenServer.call(pid, :metadata)

  def close(pid) do
    GenServer.call(pid, :close, :infinity)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    opts = Enum.into(opts, %{})
    cwd = Map.get(opts, :cwd, File.cwd!())
    transport = Map.get(opts, :transport)
    command = Map.get(opts, :command) || find_analyzer()
    request_timeout_ms = Map.get(opts, :request_timeout_ms, @default_request_timeout_ms)

    cond do
      is_nil(transport) and is_nil(command) ->
        {:stop, "v-analyzer not found on PATH; install it or start ELV without LSP"}

      transport ->
        state = %__MODULE__{
          command: command || "memory",
          cwd: cwd,
          port: transport,
          root_uri: path_uri(cwd),
          workspace_uri: path_uri(cwd),
          buffer: "",
          request_timeout_ms: request_timeout_ms
        }

        case initialize(state, Map.get(opts, :timeout_ms, @default_timeout_ms)) do
          {:ok, state} -> {:ok, state}
          {:error, message, state} -> {:stop, close_port(state, message)}
        end

      true ->
        case open_port(command, cwd) do
          {:ok, port} ->
            state = %__MODULE__{
              command: command,
              cwd: cwd,
              port: port,
              root_uri: path_uri(cwd),
              workspace_uri: path_uri(cwd),
              buffer: "",
              request_timeout_ms: request_timeout_ms
            }

            case initialize(state, Map.get(opts, :timeout_ms, @default_timeout_ms)) do
              {:ok, state} -> {:ok, state}
              {:error, message, state} -> {:stop, close_port(state, message)}
            end

          {:error, message} ->
            {:stop, message}
        end
    end
  end

  @impl true
  def handle_call({:completion, uri, line, character, opts}, from, state) do
    params = %{
      textDocument: %{uri: uri},
      position: %{line: line, character: character},
      context: %{triggerKind: 1}
    }

    request_timeout_ms = Keyword.get(opts, :timeout_ms, state.request_timeout_ms)
    {id, state} = send_request(state, "textDocument/completion", params, from)
    Process.send_after(self(), {:request_timeout, id}, request_timeout_ms)

    {:noreply, state}
  end

  def handle_call({:open_document, uri, text, opts}, _from, state) do
    version = Keyword.get(opts, :version, 1)
    language_id = Keyword.get(opts, :language_id, "v")

    write_message(
      state,
      JsonRpc.notification("textDocument/didOpen", %{
        textDocument: %{
          uri: uri,
          languageId: language_id,
          version: version,
          text: text
        }
      })
    )

    {:reply, :ok, state}
  end

  def handle_call({:change_document, uri, version, text}, _from, state) do
    write_message(
      state,
      JsonRpc.notification("textDocument/didChange", %{
        textDocument: %{uri: uri, version: version},
        contentChanges: [%{text: text}]
      })
    )

    {:reply, :ok, state}
  end

  def handle_call({:diagnostics, nil}, _from, state) do
    {:reply, state.diagnostics, state}
  end

  def handle_call({:diagnostics, uri}, _from, state) do
    {:reply, Map.get(state.diagnostics, uri, []), state}
  end

  def handle_call(:metadata, _from, state) do
    {:reply,
     %{
       lsp: :enabled,
       lsp_command: state.command,
       lsp_initialized?: state.initialized?,
       lsp_pending_requests: map_size(state.pending),
       lsp_diagnostic_files: map_size(state.diagnostics),
       lsp_last_error: state.last_error
     }, state}
  end

  def handle_call(:close, _from, state) do
    state = shutdown(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({_port, {:data, chunk}}, state) do
    {messages, buffer} = JsonRpc.decode_messages(state.buffer, chunk)

    state =
      messages
      |> Enum.reduce(%{state | buffer: buffer}, &handle_message/2)

    {:noreply, state}
  end

  def handle_info({_port, {:exit_status, status}}, state) do
    {:noreply, %{state | last_error: "language server exited with status #{status}"}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, method: method}, pending} ->
        GenServer.reply(from, {:error, "#{method} timed out"})
        {:noreply, %{state | pending: pending, last_error: "#{method} timed out"}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    shutdown(state)
    :ok
  end

  def path_uri(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> URI.encode()
    |> then(&("file:///" <> String.trim_leading(&1, "/")))
  end

  defp initialize(state, timeout_ms) do
    params = %{
      processId: System.pid() |> String.to_integer(),
      rootUri: state.root_uri,
      workspaceFolders: [%{uri: state.workspace_uri, name: Path.basename(state.cwd)}],
      capabilities: %{}
    }

    id = state.next_id
    write_message(state, JsonRpc.request(id, "initialize", params))

    case wait_for_response(state, id, timeout_ms) do
      {:ok, _result, state} ->
        write_message(state, JsonRpc.notification("initialized", %{}))
        {:ok, %{state | initialized?: true, next_id: id + 1}}

      {:error, message, state} ->
        {:error, message, %{state | last_error: message, next_id: id + 1}}
    end
  end

  defp wait_for_response(state, id, timeout_ms) do
    receive do
      {port, {:data, chunk}} when port == state.port ->
        {messages, buffer} = JsonRpc.decode_messages(state.buffer, chunk)

        {matching, other} =
          Enum.split_with(messages, fn message -> Map.get(message, "id") == id end)

        state =
          other
          |> Enum.reduce(%{state | buffer: buffer}, &handle_message(&1, &2))

        case matching do
          [message | _] -> response_result(message, state)
          [] -> wait_for_response(state, id, timeout_ms)
        end

      {port, {:exit_status, status}} when port == state.port ->
        {:error, "language server exited with status #{status}", state}
    after
      timeout_ms ->
        {:error, "initialize timed out", state}
    end
  end

  defp response_result(%{"error" => error}, state) do
    {:error, format_error(error), state}
  end

  defp response_result(%{"result" => result}, state), do: {:ok, result, state}
  defp response_result(_message, state), do: {:error, "invalid response", state}

  defp send_request(state, method, params, from) do
    id = state.next_id
    write_message(state, JsonRpc.request(id, method, params))

    {id,
     %{
       state
       | next_id: id + 1,
         pending: Map.put(state.pending, id, %{from: from, method: method})
     }}
  end

  defp handle_message(%{"method" => "textDocument/publishDiagnostics", "params" => params}, state) do
    uri = Map.get(params, "uri")
    diagnostics = Map.get(params, "diagnostics", [])

    if is_binary(uri) do
      %{state | diagnostics: Map.put(state.diagnostics, uri, diagnostics)}
    else
      state
    end
  end

  defp handle_message(%{"id" => id} = message, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {%{from: from}, pending} ->
        GenServer.reply(from, response_reply(message))
        %{state | pending: pending}
    end
  end

  defp handle_message(_message, state), do: state

  defp response_reply(%{"error" => error}), do: {:error, format_error(error)}
  defp response_reply(%{"result" => result}), do: {:ok, result}
  defp response_reply(_message), do: {:error, "invalid response"}

  defp shutdown(%__MODULE__{port: nil} = state), do: state

  defp shutdown(state) do
    state =
      if state.initialized? do
        write_message(state, JsonRpc.request(state.next_id, "shutdown", nil))
        write_message(state, JsonRpc.notification("exit", %{}))
        %{state | next_id: state.next_id + 1}
      else
        state
      end

    close_port(state, nil)
  end

  defp close_port(state, last_error) do
    cond do
      is_port(state.port) -> Port.close(state.port)
      is_pid(state.port) -> send(state.port, {:lsp_stop, self()})
      true -> :ok
    end

    %{state | port: nil, last_error: last_error || state.last_error}
  rescue
    _ -> %{state | port: nil, last_error: last_error || state.last_error}
  end

  defp write_message(state, payload) do
    message = JsonRpc.encode_message(payload)

    cond do
      is_port(state.port) -> Port.command(state.port, message)
      is_pid(state.port) -> send(state.port, {:lsp_write, self(), IO.iodata_to_binary(message)})
    end

    :ok
  end

  defp open_port(command, cwd) do
    {executable, args} = command_parts(command)
    path = resolve_command(executable)

    cond do
      is_nil(path) ->
        {:error, "#{executable} not found on PATH"}

      true ->
        {spawn_path, spawn_args} = spawn_command(path, args)

        port =
          Port.open({:spawn_executable, spawn_path}, [
            :binary,
            :exit_status,
            {:args, spawn_args},
            {:cd, cwd}
          ])

        {:ok, port}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp command_parts([executable | args]), do: {executable, args}
  defp command_parts(command), do: {command, []}

  defp spawn_command(path, args) do
    extension = Path.extname(path) |> String.downcase()

    if windows?() and extension in [".bat", ".cmd"] do
      shell = System.get_env("ComSpec") || "cmd.exe"
      {shell, ["/d", "/c", path | args]}
    else
      {path, args}
    end
  end

  defp resolve_command(command) do
    if String.contains?(command, ["/", "\\"]) do
      path = Path.expand(command)
      if File.exists?(path), do: path
    else
      System.find_executable(command)
    end
  end

  defp find_analyzer do
    Enum.find_value(["v-analyzer", "v-analyzer.exe"], &System.find_executable/1)
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end

  defp format_error(error) when is_map(error) do
    code = Map.get(error, "code")
    message = Map.get(error, "message", inspect(error))

    if code do
      "#{message} (#{code})"
    else
      message
    end
  end

  defp format_error(error), do: inspect(error)
end
