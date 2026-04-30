defmodule ElvTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  defmodule FakeBackend do
    @behaviour Elv.ExecutionBackend

    defstruct [:v_path, :cwd, :tmp_dir, seq: 0]

    @impl true
    def start(v_path, cwd, opts) do
      tmp_root = Keyword.get(opts, :tmp_root) || System.tmp_dir!()
      {:ok, %__MODULE__{v_path: v_path, cwd: cwd, tmp_dir: Path.join(tmp_root, "fake")}}
    end

    @impl true
    def close(_engine), do: :ok

    @impl true
    def restart(engine, _opts), do: {:ok, %{engine | seq: 0}}

    @impl true
    def eval(engine, "crash", _opts) do
      {:error, "v exited with status 139\nsegmentation fault", %{engine | seq: engine.seq + 1}}
    end

    def eval(engine, code, _opts) do
      {:ok, code <> "\n", 7, %{engine | seq: engine.seq + 1}}
    end

    @impl true
    def run_v(_engine, _args, _opts), do: {"fake v", 0}

    @impl true
    def split_forms(code), do: [code]

    @impl true
    def metadata(engine) do
      %{
        backend: :fake,
        v_path: engine.v_path,
        cwd: engine.cwd,
        tmp_dir: engine.tmp_dir,
        tmp_root: Path.dirname(engine.tmp_dir),
        generation: engine.seq,
        imports: 0,
        declarations: 0,
        body_forms: 0
      }
    end
  end

  defmodule CrashingBackend do
    @behaviour Elv.ExecutionBackend

    defstruct [:v_path, :cwd, :tmp_dir, seq: 0]

    @impl true
    def start(v_path, cwd, opts) do
      tmp_root = Keyword.get(opts, :tmp_root) || System.tmp_dir!()

      {:ok,
       %__MODULE__{
         v_path: v_path,
         cwd: cwd,
         tmp_dir: Path.join(tmp_root, "crashing")
       }}
    end

    @impl true
    def close(_engine), do: :ok

    @impl true
    def restart(engine, _opts), do: {:ok, %{engine | seq: 0}}

    @impl true
    def eval(_engine, "boom", _opts), do: exit(:native_worker_crash)

    def eval(engine, code, _opts) do
      {:ok, code <> "\n", 11, %{engine | seq: engine.seq + 1}}
    end

    @impl true
    def run_v(_engine, _args, _opts), do: {"fake v", 0}

    @impl true
    def split_forms(code), do: [code]

    @impl true
    def metadata(engine) do
      %{
        backend: :crashing_fake,
        v_path: engine.v_path,
        cwd: engine.cwd,
        tmp_dir: engine.tmp_dir,
        tmp_root: Path.dirname(engine.tmp_dir),
        generation: engine.seq,
        imports: 0,
        declarations: 0,
        body_forms: 0
      }
    end
  end

  defmodule FakeVDaemonDriver do
    @behaviour Elv.VDaemon.Driver

    defstruct [
      :mode,
      fail_unload_generation: nil,
      built: [],
      loaded: [],
      unloaded: [],
      recycled: []
    ]

    @impl true
    def start(config) do
      {:ok,
       %__MODULE__{
         mode: Map.fetch!(config, :mode),
         fail_unload_generation: Map.get(config, :fail_unload_generation)
       }}
    end

    @impl true
    def stop(_state), do: :ok

    @impl true
    def build(state, spec, _opts) do
      artifact =
        spec
        |> Map.put(:artifact_path, Path.join(spec.tmp_dir, "artifact_#{spec.generation}.mock"))
        |> Map.put(:build_output, "")

      {:ok, artifact, %{state | built: state.built ++ [spec.generation]}}
    end

    @impl true
    def load(state, artifact, _opts) do
      info = %{native_loaded?: true, load_message: "load #{artifact.generation}"}
      {:ok, info, %{state | loaded: state.loaded ++ [artifact.generation]}}
    end

    @impl true
    def unload(%{fail_unload_generation: generation} = state, %{generation: generation}, _opts)
        when not is_nil(generation) do
      {:error, "mock unload failure #{generation}", state}
    end

    def unload(state, record, _opts) do
      {:ok, %{native_unloaded?: true}, %{state | unloaded: state.unloaded ++ [record.generation]}}
    end

    @impl true
    def recycle(state, reason, _opts) do
      {:ok, %{mock_recycled?: true}, %{state | recycled: state.recycled ++ [reason]}}
    end

    @impl true
    def metadata(state) do
      %{
        fake_v_daemon_mode: state.mode,
        fake_v_daemon_built: state.built,
        fake_v_daemon_loaded: state.loaded,
        fake_v_daemon_unloaded: state.unloaded,
        fake_v_daemon_recycled: state.recycled
      }
    end
  end

  defmodule FailingVDaemonDriver do
    @behaviour Elv.VDaemon.Driver

    @impl true
    def start(_config), do: {:error, "native daemon unavailable"}

    @impl true
    def stop(_state), do: :ok

    @impl true
    def build(state, _spec, _opts), do: {:error, "not started", state}

    @impl true
    def load(state, _artifact, _opts), do: {:error, "not started", state}

    @impl true
    def unload(state, _record, _opts), do: {:error, "not started", state}

    @impl true
    def recycle(state, _reason, _opts), do: {:error, "not started", state}

    @impl true
    def metadata(_state), do: %{}
  end

  test "product metadata is stable" do
    assert Elv.product_name() == "Elixir Luv V"
    assert Elv.short_name() == "ELV"
    assert Elv.version() == "0.2.0"
  end

  test "scanner detects incomplete V blocks" do
    refute Elv.Scanner.complete?("fn add(a int, b int) int {")
    assert Elv.Scanner.complete?("fn add(a int, b int) int {\nreturn a + b\n}")
  end

  test "split_forms keeps multi-line declarations together" do
    code = """
    import math

    fn hyp(a f64, b f64) f64 {
      return math.sqrt(a*a + b*b)
    }

    hyp(3, 4)
    """

    assert [
             "import math",
             "fn hyp(a f64, b f64) f64 {\n  return math.sqrt(a*a + b*b)\n}",
             "hyp(3, 4)"
           ] = Elv.Engine.split_forms(code)
  end

  test "form classification is shared across execution and snapshots" do
    assert Elv.Form.classify("import math") == :import

    assert Elv.Form.classify("@[inline]\nfn add(a int, b int) int {\n return a + b\n}") ==
             :declaration

    assert Elv.Form.classify("value + 1") == :execution

    assert Elv.Form.main_function?("fn main() {}")
    assert Elv.Form.side_effecting?("println(value)")
    refute Elv.Form.side_effecting?("value + 1")

    form = Elv.Form.snapshot("println(value)", 2)

    assert form.index == 2
    assert form.kind == :execution
    assert form.source == "println(value)"
    assert form.source_sha256 == Elv.Form.sha256("println(value)")
    assert form.side_effecting?
    refute form.deterministic?
  end

  test "build server renders generation-specific source files and reuses identical source" do
    tmp_dir = Path.join(System.tmp_dir!(), "elv_test_build_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, builder} = Elv.BuildServer.start_link(tmp_dir: tmp_dir)

    assert {:ok, first} = Elv.BuildServer.render(builder, ["import math"], [], ["println(1)"])
    assert first.generation == 1
    assert File.exists?(first.path)
    assert first.source =~ "module main"
    assert first.source =~ "import math"
    assert first.source =~ "println(1)"

    assert {:ok, again} = Elv.BuildServer.render(builder, ["import math"], [], ["println(1)"])
    assert again.path == first.path
    assert again.generation == first.generation

    assert {:ok, second} = Elv.BuildServer.render(builder, ["import math"], [], ["println(2)"])
    assert second.generation == 2
    assert second.path != first.path

    metadata = Elv.BuildServer.metadata(builder)
    assert metadata.build_cache_entries == 2
    assert metadata.build_cache_hits == 1
    assert metadata.build_cache_misses == 2
    assert metadata.last_source_path == second.path
    assert metadata.last_source_sha256 == second.source_sha256

    assert :ok = Elv.BuildServer.close(builder)
  end

  test "hot reload backend loads plugin generations and unloads retired generations" do
    tmp_root = Path.join(System.tmp_dir!(), "elv_test_hot_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp_root) end)

    {:ok, backend} =
      Elv.HotReloadBackend.start("v", File.cwd!(),
        fallback_backend: FakeBackend,
        v_daemon_driver: FakeVDaemonDriver,
        tmp_root: tmp_root,
        hot_reload_mode: :plugin,
        hot_generation_retention: 2
      )

    assert {:ok, "1 + 2\n", 7, backend} = Elv.HotReloadBackend.eval(backend, "1 + 2")
    assert {:ok, "2 + 3\n", 7, backend} = Elv.HotReloadBackend.eval(backend, "2 + 3")
    assert {:ok, "3 + 4\n", 7, backend} = Elv.HotReloadBackend.eval(backend, "3 + 4")

    metadata = Elv.HotReloadBackend.metadata(backend)
    assert metadata.backend == :plugin
    assert metadata.fallback_backend == FakeBackend
    assert metadata.hot_reload == :enabled
    assert metadata.hot_reload_reason =~ "shared-library plugin generations active"
    assert metadata.hot_load_count == 3
    assert metadata.v_daemon_load_count == 3
    assert metadata.v_daemon_unload_count == 1
    assert metadata.v_daemon_loaded_generation_count == 2
    assert length(metadata.fake_v_daemon_built) == 3
    assert length(metadata.fake_v_daemon_loaded) == 3
    assert [retired_generation] = metadata.fake_v_daemon_unloaded
    refute retired_generation in metadata.v_daemon_loaded_generations
    assert metadata.capabilities.replay
    assert metadata.capabilities.plugins
    refute metadata.capabilities.live_reload

    assert :ok = Elv.HotReloadBackend.close(backend)
  end

  test "V daemon recycles when a generation cannot be unloaded" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "elv_test_daemon_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, daemon} =
      Elv.VDaemon.start_link(%{
        mode: :plugin,
        v_path: "v",
        cwd: File.cwd!(),
        tmp_dir: tmp_dir,
        driver: FakeVDaemonDriver,
        generation_retention: 1,
        recycle_after_generations: 10,
        fail_unload_generation: "g1"
      })

    spec = fn generation ->
      %{
        mode: :plugin,
        generation: generation,
        source: "module main",
        source_sha256: generation,
        source_form_sha256: generation,
        source_path: Path.join(tmp_dir, "#{generation}.v"),
        symbol: "elv_generation_entry",
        tmp_dir: tmp_dir
      }
    end

    assert {:ok, first} = Elv.VDaemon.load_generation(daemon, spec.("g1"))
    assert first.generation == "g1"

    assert {:ok, second} = Elv.VDaemon.load_generation(daemon, spec.("g2"))
    assert second.generation == "g2"
    assert [%{recycle: recycle, error: "mock unload failure g1"}] = second.policy.retired
    assert recycle.mock_recycled?
    assert recycle.reason == "unload_failed:generation_g1"

    metadata = Elv.VDaemon.metadata(daemon)
    assert metadata.v_daemon_recycle_count == 1
    assert metadata.v_daemon_loaded_generations == ["g2"]
    assert metadata.v_daemon_active_generation == "g2"
    assert metadata.fake_v_daemon_recycled == ["unload_failed:generation_g1"]
    assert metadata.fake_v_daemon_built == ["g1", "g2", "g2"]
    assert metadata.fake_v_daemon_loaded == ["g1", "g2", "g2"]

    assert :ok = Elv.VDaemon.close(daemon)
  end

  test "live backend exposes live capability through the V daemon lifecycle" do
    tmp_root = Path.join(System.tmp_dir!(), "elv_test_live_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(tmp_root) end)

    {:ok, backend} =
      Elv.HotReloadBackend.start("v", File.cwd!(),
        fallback_backend: FakeBackend,
        v_daemon_driver: FakeVDaemonDriver,
        tmp_root: tmp_root,
        hot_reload_mode: :live,
        hot_recycle_after_generations: 1
      )

    assert {:ok, "fn value() int { return 1 }\n", 7, backend} =
             Elv.HotReloadBackend.eval(backend, "fn value() int { return 1 }")

    metadata = Elv.HotReloadBackend.metadata(backend)
    assert metadata.backend == :live
    assert metadata.hot_reload == :enabled
    assert metadata.hot_load_count == 1
    assert metadata.v_daemon_recycle_count == 1
    assert metadata.capabilities.live_reload
    refute metadata.capabilities.plugins

    assert :ok = Elv.HotReloadBackend.close(backend)
  end

  test "hot reload backend degrades to replay when V daemon cannot start" do
    tmp_root =
      Path.join(System.tmp_dir!(), "elv_test_hot_degraded_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(tmp_root) end)

    assert {:ok, backend} =
             Elv.HotReloadBackend.start("v", File.cwd!(),
               fallback_backend: FakeBackend,
               v_daemon_driver: FailingVDaemonDriver,
               tmp_root: tmp_root,
               hot_reload_mode: :plugin
             )

    assert {:ok, "1 + 2\n", 7, backend} = Elv.HotReloadBackend.eval(backend, "1 + 2")

    metadata = Elv.HotReloadBackend.metadata(backend)
    assert metadata.backend == :plugin
    assert metadata.hot_reload == :degraded
    assert metadata.hot_reload_reason =~ "V daemon unavailable"
    assert metadata.hot_last_error == "native daemon unavailable"
    assert metadata.v_daemon == :disabled
    assert metadata.capabilities.replay
    refute metadata.capabilities.plugins

    assert :ok = Elv.HotReloadBackend.close(backend)
  end

  test "json rpc codec handles content-length framing" do
    payload = Elv.JsonRpc.request(7, "textDocument/completion", %{uri: "file:///tmp/a.v"})
    encoded = Elv.JsonRpc.encode_message(payload) |> IO.iodata_to_binary()

    assert String.starts_with?(encoded, "Content-Length: ")

    {[], partial} = Elv.JsonRpc.decode_messages("", binary_part(encoded, 0, 10))

    {messages, ""} =
      Elv.JsonRpc.decode_messages(partial, binary_part(encoded, 10, byte_size(encoded) - 10))

    assert [%{"id" => 7, "method" => "textDocument/completion"}] = messages
  end

  test "optional lsp client initializes, stores diagnostics, and returns completions" do
    transport = start_mock_lsp_transport()

    {:ok, lsp} =
      Elv.LspClient.start_link(
        transport: transport,
        cwd: File.cwd!(),
        timeout_ms: 5_000
      )

    uri = Elv.LspClient.path_uri(Path.join(File.cwd!(), "mock.v"))

    assert :ok = Elv.LspClient.open_document(lsp, uri, "println")

    wait_until(fn ->
      case Elv.LspClient.diagnostics(lsp, uri) do
        [%{"message" => "mock diagnostic"}] -> true
        _ -> false
      end
    end)

    assert {:ok, %{"items" => [%{"label" => "println"} | _]}} =
             Elv.LspClient.completion(lsp, uri, 0, 7, timeout_ms: 5_000)

    metadata = Elv.LspClient.metadata(lsp)
    assert metadata.lsp == :enabled
    assert metadata.lsp_initialized?
    assert metadata.lsp_diagnostic_files == 1

    assert :ok = Elv.LspClient.close(lsp)
  end

  test "editor server classifies shortcuts and buffers multiline code" do
    {:ok, editor} = Elv.EditorServer.start_link()

    assert :blank = Elv.EditorServer.submit_line(editor, "")
    assert {:ready, {:command, :quit}} = Elv.EditorServer.submit_line(editor, ":quit")

    assert {:ready, {:command, {:help, "println"}}} =
             Elv.EditorServer.submit_line(editor, "?println")

    assert {:ready, {:command, {:shell, "git status"}}} =
             Elv.EditorServer.submit_line(editor, ";git status")

    assert :incomplete = Elv.EditorServer.submit_line(editor, "fn add(a int, b int) int {")
    assert Elv.EditorServer.buffering?(editor)

    assert :incomplete = Elv.EditorServer.submit_line(editor, "  return a + b")

    assert {:ready, {:code, "fn add(a int, b int) int {\n  return a + b\n}"}} =
             Elv.EditorServer.submit_line(editor, "}")

    refute Elv.EditorServer.buffering?(editor)

    assert :ok = Elv.EditorServer.close(editor)
  end

  test "editor server keeps searchable input history" do
    {:ok, editor} = Elv.EditorServer.start_link()

    assert :ok = Elv.EditorServer.record(editor, "value := 41")
    assert :ok = Elv.EditorServer.record(editor, "println(value)")
    assert :ok = Elv.EditorServer.record(editor, "value + 1")

    assert Elv.EditorServer.history(editor) == ["value := 41", "println(value)", "value + 1"]

    assert [
             %{index: 3, source: "value + 1"},
             %{index: 2, source: "println(value)"}
           ] = Elv.EditorServer.search(editor, "VALUE", limit: 2)

    assert [%{index: 2, source: "println(value)"}] =
             Elv.EditorServer.search(editor, "println", case_sensitive?: true)

    assert [] = Elv.EditorServer.search(editor, "")

    assert :ok = Elv.EditorServer.close(editor)
  end

  test "V locator normalizes quoted user paths" do
    assert Elv.VLocator.normalize_user_path("\"/tmp/v\"") == Path.expand("/tmp/v")
  end

  test "session server owns history and structured runtime metadata" do
    snapshot_root =
      Path.join(System.tmp_dir!(), "elv_test_snapshots_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(snapshot_root) end)

    {:ok, session} =
      Elv.SessionServer.start_link(%{
        backend: FakeBackend,
        v_path: "v",
        cwd: File.cwd!(),
        tmp_root: System.tmp_dir!(),
        snapshot_root: snapshot_root
      })

    assert {:ok, "1 + 2\n", 7, ^session} = Elv.SessionServer.eval(session, "1 + 2")
    assert {:error, message, ^session} = Elv.SessionServer.eval(session, "crash")
    assert message =~ "status 139"
    assert message =~ "automatic recovery replayed 1 form(s)"

    metadata = Elv.SessionServer.metadata(session)

    assert metadata.backend == :fake
    assert metadata.history_count == 2
    assert metadata.safe_history_count == 1
    assert metadata.eval_count == 2
    assert metadata.error_count == 1
    assert metadata.crash_count == 1
    assert metadata.last_eval_us == 7
    assert metadata.total_eval_us == 7
    assert metadata.generation == 1
    assert metadata.recovery_count == 1
    assert metadata.auto_recovery_count == 1
    assert metadata.last_auto_recovery.replayed == 1
    assert metadata.poisoned_generations == [2]
    assert metadata.snapshots == :enabled

    assert String.downcase(Path.expand(metadata.snapshot_root)) ==
             String.downcase(Path.expand(snapshot_root))

    assert metadata.snapshot_count == 2
    assert File.exists?(metadata.snapshot_latest)
    assert Elv.SessionServer.history(session) == ["1 + 2", "crash"]

    assert {:ok, snapshot} = Elv.SnapshotStore.read(metadata.snapshot_latest)
    assert snapshot.history == ["1 + 2"]
    assert snapshot.deterministic_count == 1
    assert snapshot.side_effecting_count == 0
    assert [%{kind: :execution, source: "1 + 2", deterministic?: true}] = snapshot.forms
    assert %{replayed: [%{source: "1 + 2"}], skipped: []} = snapshot.replay_plan

    assert {:ok, 1, 0, recovery_us, ^session} = Elv.SessionServer.recover_latest(session)
    assert recovery_us >= 0

    metadata = Elv.SessionServer.metadata(session)
    assert metadata.recovery_count == 2
    assert metadata.last_recovery_us >= 0
    assert metadata.last_replayed_count == 1
    assert metadata.last_skipped_count == 0
    assert metadata.safe_history_count == 1
    assert metadata.snapshot_count == 3

    assert :ok = Elv.SessionServer.close(session)
  end

  test "recovery replays deterministic snapshot forms and skips side-effecting forms" do
    snapshot_root =
      Path.join(System.tmp_dir!(), "elv_test_recovery_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(snapshot_root) end)

    {:ok, session} =
      Elv.SessionServer.start_link(%{
        backend: FakeBackend,
        v_path: "v",
        cwd: File.cwd!(),
        tmp_root: System.tmp_dir!(),
        snapshot_root: snapshot_root
      })

    assert {:ok, "a := 1\n", 7, ^session} = Elv.SessionServer.eval(session, "a := 1")
    assert {:ok, "println(a)\n", 7, ^session} = Elv.SessionServer.eval(session, "println(a)")

    metadata = Elv.SessionServer.metadata(session)
    assert metadata.safe_history_count == 2
    assert {:ok, snapshot} = Elv.SnapshotStore.read(metadata.snapshot_latest)
    assert snapshot.deterministic_count == 1
    assert snapshot.side_effecting_count == 1

    assert %{replayed: [%{source: "a := 1"}], skipped: [%{source: "println(a)"}]} =
             snapshot.replay_plan

    assert {:ok, 1, 1, _recovery_us, ^session} = Elv.SessionServer.recover_latest(session)

    metadata = Elv.SessionServer.metadata(session)
    assert metadata.safe_history_count == 1

    assert {:ok, snapshot} = Elv.SnapshotStore.read(metadata.snapshot_latest)
    assert snapshot.history == ["a := 1"]
    assert snapshot.deterministic_count == 1
    assert snapshot.side_effecting_count == 0
    assert snapshot.replay_plan.skipped == []

    assert :ok = Elv.SessionServer.close(session)
  end

  test "snapshots can be disabled for a session" do
    {:ok, session} =
      Elv.SessionServer.start_link(%{
        backend: FakeBackend,
        v_path: "v",
        cwd: File.cwd!(),
        tmp_root: System.tmp_dir!(),
        snapshots?: false
      })

    assert {:ok, "1\n", 7, ^session} = Elv.SessionServer.eval(session, "1")

    metadata = Elv.SessionServer.metadata(session)
    assert metadata.snapshots == :disabled
    assert metadata.snapshot_count == 0

    assert {:error, "snapshots are disabled", ^session} =
             Elv.SessionServer.recover_latest(session)

    assert :ok = Elv.SessionServer.close(session)
  end

  test "worker backend keeps session alive after worker process crash" do
    if is_nil(Process.whereis(Elv.WorkerSupervisor)) do
      start_supervised!(Elv.WorkerSupervisor)
    end

    snapshot_root =
      Path.join(System.tmp_dir!(), "elv_test_worker_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(snapshot_root) end)

    {:ok, session} =
      Elv.SessionServer.start_link(%{
        backend: Elv.WorkerBackend,
        worker_backend: CrashingBackend,
        v_path: "v",
        cwd: File.cwd!(),
        tmp_root: System.tmp_dir!(),
        snapshot_root: snapshot_root
      })

    assert {:ok, "safe := 1\n", 11, ^session} =
             Elv.SessionServer.eval(session, "safe := 1")

    test_pid = self()

    capture_log(fn ->
      assert {:error, message, ^session} = Elv.SessionServer.eval(session, "boom")
      send(test_pid, {:worker_crash_message, message})
    end)

    assert_receive {:worker_crash_message, message}
    assert message =~ "worker crashed"
    assert message =~ "automatic recovery replayed 1 form(s)"

    metadata = Elv.SessionServer.metadata(session)
    assert metadata.backend == :worker
    assert metadata.worker_alive? == true
    assert metadata.capabilities.worker_isolation
    assert metadata.crash_count == 1
    assert metadata.error_count == 1
    assert metadata.safe_history_count == 1
    assert metadata.recovery_count == 1
    assert metadata.auto_recovery_count == 1
    assert metadata.last_auto_recovery.replayed == 1

    assert {:ok, "safe + 1\n", 11, ^session} = Elv.SessionServer.eval(session, "safe + 1")

    metadata = Elv.SessionServer.metadata(session)
    assert metadata.recovery_count == 1
    assert metadata.safe_history_count == 2

    assert :ok = Elv.SessionServer.close(session)
  end

  test "worker recycle restarts worker and replays checkpoint state" do
    if is_nil(Process.whereis(Elv.WorkerSupervisor)) do
      start_supervised!(Elv.WorkerSupervisor)
    end

    snapshot_root =
      Path.join(System.tmp_dir!(), "elv_test_recycle_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(snapshot_root) end)

    {:ok, session} =
      Elv.SessionServer.start_link(%{
        backend: Elv.WorkerBackend,
        worker_backend: CrashingBackend,
        v_path: "v",
        cwd: File.cwd!(),
        tmp_root: System.tmp_dir!(),
        snapshot_root: snapshot_root,
        worker_recycle_after: 1
      })

    assert {:ok, "safe := 1\n", 11, ^session} =
             Elv.SessionServer.eval(session, "safe := 1")

    metadata = Elv.SessionServer.metadata(session)
    assert metadata.backend == :worker
    assert metadata.worker_recycle_count == 1
    assert metadata.last_worker_recycle.reason == "max_evals=1"
    assert metadata.last_worker_recycle.replayed == 1
    assert metadata.worker_evals_since_start == 1

    assert {:ok, "safe + 1\n", 11, ^session} = Elv.SessionServer.eval(session, "safe + 1")

    metadata = Elv.SessionServer.metadata(session)
    assert metadata.worker_recycle_count == 2
    assert metadata.safe_history_count == 2

    assert :ok = Elv.SessionServer.close(session)
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp start_mock_lsp_transport do
    parent = self()

    spawn_link(fn ->
      send(parent, {:mock_lsp_transport, self()})
      mock_lsp_loop("")
    end)
    |> tap(fn _pid ->
      assert_receive {:mock_lsp_transport, _pid}
    end)
  end

  defp mock_lsp_loop(buffer) do
    receive do
      {:lsp_write, client, chunk} ->
        {messages, buffer} = Elv.JsonRpc.decode_messages(buffer, chunk)
        Enum.each(messages, &mock_lsp_handle(client, &1))
        mock_lsp_loop(buffer)

      {:lsp_stop, _client} ->
        :ok
    after
      5_000 ->
        :ok
    end
  end

  defp mock_lsp_handle(client, %{"method" => "initialize", "id" => id}) do
    mock_lsp_send(client, %{
      jsonrpc: "2.0",
      id: id,
      result: %{capabilities: %{completionProvider: %{triggerCharacters: ["."]}}}
    })
  end

  defp mock_lsp_handle(client, %{"method" => "textDocument/didOpen", "params" => params}) do
    params
    |> get_in(["textDocument", "uri"])
    |> mock_lsp_publish_diagnostic(client)
  end

  defp mock_lsp_handle(client, %{"method" => "textDocument/didChange", "params" => params}) do
    params
    |> get_in(["textDocument", "uri"])
    |> mock_lsp_publish_diagnostic(client)
  end

  defp mock_lsp_handle(client, %{"method" => "textDocument/completion", "id" => id}) do
    mock_lsp_send(client, %{
      jsonrpc: "2.0",
      id: id,
      result: %{
        isIncomplete: false,
        items: [
          %{label: "println", detail: "fn println(value any)"},
          %{label: "print", detail: "fn print(value any)"}
        ]
      }
    })
  end

  defp mock_lsp_handle(client, %{"method" => "shutdown", "id" => id}) do
    mock_lsp_send(client, %{jsonrpc: "2.0", id: id, result: nil})
  end

  defp mock_lsp_handle(_client, _message), do: :ok

  defp mock_lsp_publish_diagnostic(uri, client) when is_binary(uri) do
    mock_lsp_send(client, %{
      jsonrpc: "2.0",
      method: "textDocument/publishDiagnostics",
      params: %{
        uri: uri,
        diagnostics: [
          %{
            range: %{start: %{line: 0, character: 0}, end: %{line: 0, character: 1}},
            severity: 2,
            message: "mock diagnostic"
          }
        ]
      }
    })
  end

  defp mock_lsp_publish_diagnostic(_uri, _client), do: :ok

  defp mock_lsp_send(client, payload) do
    send(client, {self(), {:data, Elv.JsonRpc.encode_message(payload) |> IO.iodata_to_binary()}})
  end
end
