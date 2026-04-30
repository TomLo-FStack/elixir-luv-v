defmodule Elv.JsonRpc do
  @moduledoc false

  @separator "\r\n\r\n"

  def request(id, method, params \\ %{}) do
    %{
      jsonrpc: "2.0",
      id: id,
      method: method,
      params: params
    }
  end

  def notification(method, params \\ %{}) do
    %{
      jsonrpc: "2.0",
      method: method,
      params: params
    }
  end

  def encode_message(payload) when is_map(payload) do
    body = :json.encode(payload) |> IO.iodata_to_binary()
    ["Content-Length: ", Integer.to_string(byte_size(body)), @separator, body]
  end

  def decode_messages(buffer, chunk \\ "") when is_binary(buffer) and is_binary(chunk) do
    do_decode(buffer <> chunk, [])
  end

  defp do_decode(buffer, messages) do
    case :binary.match(buffer, @separator) do
      :nomatch ->
        {Enum.reverse(messages), buffer}

      {header_size, separator_size} ->
        header = binary_part(buffer, 0, header_size)
        body_start = header_size + separator_size

        with {:ok, content_length} <- content_length(header),
             true <- byte_size(buffer) - body_start >= content_length do
          body = binary_part(buffer, body_start, content_length)

          rest =
            binary_part(
              buffer,
              body_start + content_length,
              byte_size(buffer) - body_start - content_length
            )

          case decode_body(body) do
            {:ok, message} -> do_decode(rest, [message | messages])
            {:error, _reason} -> do_decode(rest, messages)
          end
        else
          false -> {Enum.reverse(messages), buffer}
          {:error, _reason} -> {Enum.reverse(messages), ""}
        end
    end
  end

  defp content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length" do
            value
            |> String.trim()
            |> Integer.parse()
            |> case do
              {length, ""} when length >= 0 -> {:ok, length}
              _ -> {:error, :invalid_content_length}
            end
          end

        _ ->
          nil
      end
    end)
    |> case do
      nil -> {:error, :missing_content_length}
      result -> result
    end
  end

  defp decode_body(body) do
    {:ok, :json.decode(body)}
  rescue
    error -> {:error, Exception.message(error)}
  end
end
