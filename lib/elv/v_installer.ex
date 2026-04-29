defmodule Elv.VInstaller do
  @moduledoc false

  alias Elv.Config
  alias Elv.VLocator

  @repo "https://github.com/vlang/v"
  @timeout_ms 600_000

  def install(opts \\ []) do
    dir = opts |> Keyword.get(:dir, default_install_dir()) |> Path.expand()
    force? = Keyword.get(opts, :force, false)
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)
    branch = Keyword.get(opts, :branch)

    with :ok <- ensure_git(),
         :ok <- prepare_dir(dir, force?),
         {:ok, clone_log} <- clone(dir, branch, timeout_ms),
         {:ok, build_log} <- build(dir, timeout_ms),
         {:ok, found} <-
           VLocator.resolve(path: executable_path(dir), config: %{}, explicit_only: true) do
      File.write!(Path.join(dir, ".elv-managed-v"), "#{@repo}\n")

      unless Keyword.get(opts, :no_config, false) do
        Config.set("v.path", found.path)
      end

      {:ok,
       %{
         dir: dir,
         path: found.path,
         version: found.version,
         configured?: not Keyword.get(opts, :no_config, false),
         log: clone_log <> "\n" <> build_log
       }}
    end
  end

  def update(opts \\ []) do
    dir = opts |> Keyword.get(:dir, default_install_dir()) |> Path.expand()
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)

    with :ok <- ensure_managed_dir(dir),
         {:ok, pull_log} <- run("git", ["-C", dir, "pull", "--ff-only"], File.cwd!(), timeout_ms),
         {:ok, build_log} <- build(dir, timeout_ms),
         {:ok, found} <-
           VLocator.resolve(path: executable_path(dir), config: %{}, explicit_only: true) do
      unless Keyword.get(opts, :no_config, false) do
        Config.set("v.path", found.path)
      end

      {:ok,
       %{
         dir: dir,
         path: found.path,
         version: found.version,
         configured?: not Keyword.get(opts, :no_config, false),
         log: pull_log <> "\n" <> build_log
       }}
    end
  end

  def default_install_dir do
    Path.join(data_dir(), "v")
  end

  def data_dir do
    cond do
      windows?() ->
        base =
          System.get_env("LOCALAPPDATA") ||
            Path.join([home_dir(), "AppData", "Local"])

        Path.join(base, "ElixirLuvV")

      macos?() ->
        Path.join([home_dir(), "Library", "Application Support", "Elixir Luv V"])

      System.get_env("XDG_DATA_HOME") not in [nil, ""] ->
        Path.join(System.fetch_env!("XDG_DATA_HOME"), "elixir-luv-v")

      true ->
        Path.join([home_dir(), ".local", "share", "elixir-luv-v"])
    end
  end

  defp ensure_git do
    if System.find_executable("git") do
      :ok
    else
      {:error,
       "git was not found on PATH; install git first, or use `elv config set v.path PATH`."}
    end
  end

  defp prepare_dir(dir, force?) do
    cond do
      not File.exists?(dir) ->
        File.mkdir_p!(Path.dirname(dir))
        :ok

      force? and managed_dir?(dir) ->
        File.rm_rf!(dir)
        File.mkdir_p!(Path.dirname(dir))
        :ok

      force? and safely_inside_data_dir?(dir) ->
        File.rm_rf!(dir)
        File.mkdir_p!(Path.dirname(dir))
        :ok

      true ->
        {:error,
         "#{dir} already exists. Use `elv v update`, choose --dir, or pass --force for an ELV-managed directory."}
    end
  end

  defp ensure_managed_dir(dir) do
    cond do
      not File.dir?(dir) ->
        {:error, "#{dir} does not exist. Run `elv v install` first."}

      not File.dir?(Path.join(dir, ".git")) ->
        {:error, "#{dir} is not a git checkout."}

      true ->
        :ok
    end
  end

  defp clone(dir, nil, timeout_ms) do
    run("git", ["clone", "--depth=1", @repo, dir], File.cwd!(), timeout_ms)
  end

  defp clone(dir, branch, timeout_ms) do
    run("git", ["clone", "--depth=1", "--branch", branch, @repo, dir], File.cwd!(), timeout_ms)
  end

  defp build(dir, timeout_ms) do
    if windows?() do
      run(System.get_env("ComSpec") || "cmd.exe", ["/c", "make.bat"], dir, timeout_ms)
    else
      run("make", [], dir, timeout_ms)
    end
  end

  defp run(command, args, cwd, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(command, args, cd: cwd, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, "#{command} exited with status #{status}\n#{output}"}
      nil -> {:error, "#{command} timed out after #{timeout_ms} ms"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp executable_path(dir) do
    if windows?(), do: Path.join(dir, "v.exe"), else: Path.join(dir, "v")
  end

  defp managed_dir?(dir) do
    File.exists?(Path.join(dir, ".elv-managed-v"))
  end

  defp safely_inside_data_dir?(dir) do
    data = data_dir() |> Path.expand() |> normalize()
    target = dir |> Path.expand() |> normalize()
    String.starts_with?(target, data <> "/")
  end

  defp normalize(path) do
    path
    |> String.replace("\\", "/")
    |> then(fn value -> if windows?(), do: String.downcase(value), else: value end)
  end

  defp home_dir do
    System.user_home!()
  rescue
    _ -> File.cwd!()
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end

  defp macos? do
    match?({:unix, :darwin}, :os.type())
  end
end
