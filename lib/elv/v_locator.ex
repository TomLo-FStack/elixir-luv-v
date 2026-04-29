defmodule Elv.VLocator do
  @moduledoc false

  alias Elv.Config

  @timeout_ms 5_000
  @env_keys ~w(ELV_V_PATH V_EXE V_PATH VROOT V_HOME VLANG_HOME)

  def resolve(opts \\ []) do
    opts = normalize_opts(opts)

    opts
    |> candidates()
    |> expand_candidates()
    |> validate_first(opts)
  end

  def inspect_candidates(opts \\ []) do
    opts = normalize_opts(opts)

    opts
    |> candidates()
    |> expand_candidates()
    |> Enum.map(fn candidate ->
      case validate(candidate.path, opts[:timeout_ms]) do
        {:ok, version} -> Map.merge(candidate, %{status: :ok, version: version, error: nil})
        {:error, error} -> Map.merge(candidate, %{status: :error, version: nil, error: error})
      end
    end)
  end

  def normalize_user_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("'")
    |> Path.expand()
  end

  def normalize_user_path(path), do: path

  defp validate_first(candidates, opts) do
    case Enum.find_value(candidates, &validated_candidate(&1, opts[:timeout_ms])) do
      nil -> {:error, diagnostic(candidates)}
      found -> {:ok, found}
    end
  end

  defp validated_candidate(candidate, timeout_ms) do
    case validate(candidate.path, timeout_ms) do
      {:ok, version} -> Map.merge(candidate, %{version: version})
      {:error, _reason} -> nil
    end
  end

  def validate(path, timeout_ms \\ @timeout_ms) do
    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, "blank path"}

      File.dir?(path) ->
        {:error, "is a directory"}

      not File.exists?(path) ->
        {:error, "not found"}

      true ->
        run_version(path, timeout_ms)
    end
  end

  defp run_version(path, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(path, ["version"], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        version = String.trim(output)

        if String.starts_with?(version, "V ") do
          {:ok, version}
        else
          {:error, "does not look like V: #{version}"}
        end

      {:ok, {output, status}} ->
        {:error, "version exited #{status}: #{String.trim(output)}"}

      nil ->
        {:error, "version timed out after #{timeout_ms} ms"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp normalize_opts(opts) do
    config = Keyword.get(opts, :config, Config.read())

    opts
    |> Keyword.put_new(:cwd, File.cwd!())
    |> Keyword.put_new(:config, config)
    |> Keyword.put_new(:timeout_ms, @timeout_ms)
  end

  defp candidates(opts) do
    cwd = opts[:cwd]
    config = opts[:config]

    explicit =
      [opts[:path], opts[:v], opts[:v_path]]
      |> Enum.reject(&blank?/1)
      |> Enum.map(&candidate("cli --v", &1))

    if opts[:explicit_only] do
      explicit
    else
      rest_candidates(explicit, cwd, config)
    end
  end

  defp rest_candidates(explicit, cwd, config) do
    config_candidates =
      case Map.get(config, "v.path") do
        path when is_binary(path) and path != "" -> [candidate("config v.path", path)]
        _ -> []
      end

    env_candidates =
      @env_keys
      |> Enum.flat_map(fn key ->
        case System.get_env(key) do
          value when is_binary(value) and value != "" -> [candidate("env #{key}", value)]
          _ -> []
        end
      end)

    path_candidates =
      path_executables()
      |> Enum.map(&candidate("PATH", &1))

    project_candidates =
      [
        Path.join([cwd, "tools", "v"]),
        Path.join([cwd, "vendor", "v"]),
        Path.join([cwd, ".v"]),
        Path.join([cwd, "v"])
      ]
      |> Enum.map(&candidate("project", &1))

    explicit ++
      config_candidates ++
      env_candidates ++ path_candidates ++ project_candidates ++ common_candidates()
  end

  defp expand_candidates(candidates) do
    candidates
    |> Enum.flat_map(&expand_candidate/1)
    |> Enum.uniq_by(fn candidate -> normalize_key(candidate.path) end)
  end

  defp expand_candidate(%{path: path} = candidate) do
    path = normalize_user_path(path)

    cond do
      blank?(path) ->
        []

      File.dir?(path) ->
        executable_names()
        |> Enum.flat_map(fn exe ->
          [
            Path.join(path, exe),
            Path.join([path, "cmd", exe]),
            Path.join([path, "bin", exe])
          ]
        end)
        |> Enum.map(&%{candidate | path: Path.expand(&1)})

      command_name?(path) ->
        case System.find_executable(path) do
          nil -> [%{candidate | path: path}]
          found -> [%{candidate | path: Path.expand(found)}]
        end

      true ->
        [%{candidate | path: Path.expand(path)}]
    end
  end

  defp candidate(source, path) do
    %{source: source, path: path}
  end

  defp path_executables do
    executable_names()
    |> Enum.flat_map(fn name ->
      [System.find_executable(name)] ++ manual_path_lookup(name)
    end)
    |> Enum.reject(&blank?/1)
  end

  defp manual_path_lookup(name) do
    System.get_env("PATH", "")
    |> String.split(path_separator(), trim: true)
    |> Enum.map(&Path.join(&1, name))
  end

  defp common_candidates do
    home = user_home()

    paths =
      cond do
        windows?() ->
          local = System.get_env("LOCALAPPDATA") || Path.join([home, "AppData", "Local"])
          program_files = System.get_env("ProgramFiles") || "C:\\Program Files"
          scoop = System.get_env("SCOOP") || Path.join(home, "scoop")
          chocolatey = System.get_env("ChocolateyInstall") || "C:\\ProgramData\\chocolatey"

          [
            "C:\\v",
            Path.join(home, "v"),
            Path.join([local, "v"]),
            Path.join([local, "Programs", "v"]),
            Path.join([program_files, "V"]),
            Path.join([scoop, "apps", "v", "current"]),
            Path.join([chocolatey, "bin", "v.exe"])
          ]

        macos?() ->
          [
            "/opt/homebrew/bin/v",
            "/opt/homebrew/opt/v/bin/v",
            "/usr/local/bin/v",
            "/usr/local/opt/v/bin/v",
            "/opt/local/bin/v",
            "/opt/v",
            "/Applications/V.app/Contents/MacOS/v",
            Path.join(home, "v"),
            Path.join([home, ".v"]),
            Path.join([home, ".vlang"]),
            Path.join([home, "Developer", "v"]),
            Path.join([home, "code", "v"]),
            Path.join([home, "src", "v"]),
            Path.join([home, ".local", "bin", "v"])
          ]

        true ->
          [
            "/usr/local/bin/v",
            "/usr/bin/v",
            "/opt/v",
            Path.join(home, "v"),
            Path.join([home, ".v"]),
            Path.join([home, ".vlang"]),
            Path.join([home, ".local", "bin", "v"]),
            Path.join([home, "code", "v"]),
            Path.join([home, "src", "v"])
          ]
      end

    Enum.map(paths, &candidate("common", &1))
  end

  defp diagnostic(candidates) do
    tried =
      candidates
      |> Enum.map(fn candidate -> "  - #{candidate.source}: #{candidate.path}" end)
      |> Enum.join("\n")

    """
    Could not find a working V compiler.

    Configure one of these:
      elv v install
      elv config set v.path /absolute/path/to/v
      elv --v /absolute/path/to/v
      set V_EXE=/absolute/path/to/v
      put v on PATH

    Config file:
      #{Config.path()}

    Checked:
    #{if tried == "", do: "  (no candidates)", else: tried}
    """
    |> String.trim()
  end

  defp executable_names do
    if windows?(), do: ["v.exe", "v.bat", "v.cmd", "v"], else: ["v"]
  end

  defp command_name?(value) do
    not String.contains?(value, ["/", "\\"])
  end

  defp normalize_key(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> then(fn value -> if windows?(), do: String.downcase(value), else: value end)
  end

  defp blank?(value), do: value in [nil, ""]

  defp windows? do
    match?({:win32, _}, :os.type())
  end

  defp macos? do
    match?({:unix, :darwin}, :os.type())
  end

  defp path_separator do
    if windows?(), do: ";", else: ":"
  end

  defp user_home do
    System.user_home!()
  rescue
    _ -> File.cwd!()
  end
end
