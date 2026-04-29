defmodule Elv.Config do
  @moduledoc false

  @app_dir "elixir-luv-v"
  @windows_app_dir "ElixirLuvV"

  def path do
    Path.join(config_dir(), "config.ini")
  end

  def config_dir do
    cond do
      windows?() ->
        base =
          System.get_env("APPDATA") ||
            Path.join([home_dir(), "AppData", "Roaming"])

        Path.join(base, @windows_app_dir)

      System.get_env("XDG_CONFIG_HOME") not in [nil, ""] ->
        Path.join(System.fetch_env!("XDG_CONFIG_HOME"), @app_dir)

      true ->
        Path.join([home_dir(), ".config", @app_dir])
    end
  end

  def read do
    case File.read(path()) do
      {:ok, contents} -> parse(contents)
      {:error, :enoent} -> %{}
      {:error, _reason} -> %{}
    end
  end

  def get(key) do
    Map.get(read(), key)
  end

  def set(key, value) do
    config = Map.put(read(), key, value)
    write(config)
  end

  def unset(key) do
    config = Map.delete(read(), key)
    write(config)
  end

  def write(config) when is_map(config) do
    File.mkdir_p!(config_dir())

    body =
      config
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
      |> Enum.join("\n")

    File.write!(path(), body <> if(body == "", do: "", else: "\n"))
    :ok
  end

  defp parse(contents) do
    contents
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      cond do
        line == "" ->
          acc

        String.starts_with?(line, "#") ->
          acc

        String.contains?(line, "=") ->
          [key, value] = String.split(line, "=", parts: 2)
          Map.put(acc, String.trim(key), String.trim(value))

        true ->
          acc
      end
    end)
  end

  defp home_dir do
    System.user_home!()
  rescue
    _ -> File.cwd!()
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end
end
