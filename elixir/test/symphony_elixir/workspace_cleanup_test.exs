defmodule SymphonyElixir.WorkspaceCleanupTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ManagedProcess, WorkspaceCleanup, WorkspaceLease}

  setup do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces")
    options = [tracker_kind: "memory", workspace_root: root, poll_interval_ms: 60_000, codex_command: "exit 1"]
    write_workflow_file!(Workflow.workflow_file_path(), options)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    issue = %Issue{id: "cleanup-1", identifier: "MT-CLEAN", state: "In Progress", title: "cleanup"}
    workspace = Path.join(root, issue.identifier)
    File.mkdir_p!(workspace)
    {:ok, root: root, issue: issue, workspace: workspace, context: %{issue_id: issue.id, identifier: issue.identifier, worker_host: nil}}
  end

  test "Done waits for last usage and worker finalization before deleting", c do
    parent = self()

    worker =
      spawn(fn ->
        receive do
          :symphony_stop ->
            # Done 検出後にも届き得る最後の通知と、workspace に触る終了処理。
            send(parent, :stopping)

            receive do
              {:finish, orchestrator} ->
                usage = %{"tokenUsage" => %{"total" => %{"inputTokens" => 7, "outputTokens" => 3, "totalTokens" => 10}}}

                send(
                  orchestrator,
                  {:codex_worker_update, c.issue.id, %{event: :notification, timestamp: DateTime.utc_now(), usage: usage}}
                )

                File.write!(Path.join(c.workspace, "finalized"), "done")
                send(parent, :finalized)
            end
        end
      end)

    orchestrator = start_orchestrator()
    reconcile(orchestrator, c.issue, worker)
    assert_receive :stopping
    assert %{running: [], cleanups: [%{status: :pending}]} = Orchestrator.snapshot(orchestrator, 200)
    assert File.dir?(c.workspace)
    send(worker, {:finish, orchestrator})
    assert_receive :finalized
    eventually(fn -> Orchestrator.snapshot(orchestrator, 200).cleanups == [] end)
    refute File.exists?(c.workspace)
    assert Orchestrator.snapshot(orchestrator, 200).codex_totals.total_tokens == 10
  end

  test "slow deletion serves snapshots and dispatches another issue; duplicate and Rework are fenced", c do
    {entered, release} = removal_barrier(c)
    orchestrator = start_orchestrator()
    reconcile(orchestrator, c.issue, nil)
    eventually(fn -> File.exists?(entered) end)
    assert %{cleanups: [%{status: :pending}]} = Orchestrator.snapshot(orchestrator, 200)
    rework = %{c.issue | state: "Rework"}
    state = :sys.get_state(orchestrator)
    refute Orchestrator.should_dispatch_issue_for_test(rework, state)
    # 実際の worker 入口でも、別 Orchestrator からの再開を拒否する。
    assert_raise RuntimeError, ~r/workspace lease failed/, fn -> AgentRunner.run(rework) end
    duplicate = WorkspaceCleanup.request(c.context, nil, true)
    assert {:error, :eexist} = Task.await(duplicate)
    other = %Issue{id: "cleanup-2", identifier: "MT-OTHER", state: "In Progress", title: "other"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [other])
    send(orchestrator, :tick)
    eventually(fn -> File.dir?(Path.join(c.root, other.identifier)) end)
    assert is_map(Orchestrator.snapshot(orchestrator, 200))
    File.write!(release, "go")
    eventually(fn -> Orchestrator.snapshot(orchestrator, 200).cleanups == [] end)
    refute File.exists?(c.workspace)
    assert File.dir?(Path.join(c.root, other.identifier))
  end

  test "cleanup failure is logged, retained in snapshot, and does not stop management", c do
    # 削除開始後に permission error を起こす。root では実行しない通常の WSL テスト。
    File.write!(Path.join(c.workspace, "retained"), "data")
    File.chmod!(c.workspace, 0o500)
    on_exit(fn -> File.chmod(c.workspace, 0o700) end)
    orchestrator = start_orchestrator()

    log =
      capture_log(fn ->
        reconcile(orchestrator, c.issue, nil)
        eventually(fn -> match?([%{status: :failed}], Orchestrator.snapshot(orchestrator, 200).cleanups) end)
      end)

    assert log =~ "Workspace cleanup failed"
    assert log =~ "issue_id=cleanup-1"
    assert log =~ "elapsed_ms="
    assert File.read!(Path.join(c.workspace, "retained")) == "data"
    assert %{cleanups: [%{error: error}]} = Orchestrator.snapshot(orchestrator, 200)
    assert error =~ "eacces" or error =~ "eexist"
    assert is_map(GenServer.call(orchestrator, :request_refresh, 200))
    File.chmod!(c.workspace, 0o700)
  end

  test "old cleanup request cannot delete a newer generation", c do
    parent = self()

    old =
      spawn(fn ->
        receive do
          :symphony_stop -> send(parent, :waiting)
        end

        receive do
          :finish -> :ok
        end
      end)

    task = WorkspaceCleanup.request(c.context, old, true)
    assert_receive :waiting
    paths = WorkspaceLease.paths(c.root, c.issue.identifier)
    :ok = WorkspaceLease.acquire(paths, %{operation: "new-worker"})
    :ok = WorkspaceLease.advance(paths)
    File.write!(Path.join(c.workspace, "new-work"), "preserve")
    :ok = WorkspaceLease.release(paths)
    send(old, :finish)
    assert {:error, {:workspace_generation_changed, _, _}} = Task.await(task)
    assert File.read!(Path.join(c.workspace, "new-work")) == "preserve"
    refute File.exists?(paths.lock)
  end

  test "Orchestrator restart during deletion cannot reuse the locked workspace", c do
    {entered, release} = removal_barrier(c)
    orchestrator = start_orchestrator()
    reconcile(orchestrator, c.issue, nil)
    eventually(fn -> File.exists?(entered) end)
    cleanup = :sys.get_state(orchestrator).cleanups[c.issue.id]
    cleanup_ref = Process.monitor(cleanup.pid)
    GenServer.stop(orchestrator)
    assert Process.alive?(cleanup.pid)
    restarted = start_orchestrator()
    assert %{running: []} = Orchestrator.snapshot(restarted, 200)
    assert_raise RuntimeError, ~r/workspace lease failed/, fn -> AgentRunner.run(c.issue) end
    File.write!(release, "go")
    assert_receive {:DOWN, ^cleanup_ref, :process, _, :normal}, 3_000
    refute File.exists?(c.workspace)
    # 完了後に作成された workspace を、遅い完了通知は削除しない。
    File.mkdir_p!(c.workspace)
    File.write!(Path.join(c.workspace, "new"), "keep")
    send(restarted, {cleanup.ref, :ok})
    assert is_map(Orchestrator.snapshot(restarted, 200))
    assert File.exists?(Path.join(c.workspace, "new"))
  end

  test "abrupt death leaves a durable lease that fences cleanup and restart", c do
    paths = WorkspaceLease.paths(c.root, c.issue.identifier)
    :ok = WorkspaceLease.acquire(paths, %{operation: "interrupted-worker"})
    :ok = WorkspaceLease.advance(paths)
    task = WorkspaceCleanup.request(c.context, nil, true)
    assert {:error, :eexist} = Task.await(task)
    assert_raise RuntimeError, ~r/workspace lease failed/, fn -> AgentRunner.run(c.issue) end
    assert File.dir?(c.workspace)
  end

  test "normal, abnormal, and already missing workspaces complete cleanup", c do
    for reason <- [:normal, :failure] do
      File.mkdir_p!(c.workspace)

      worker =
        spawn(fn ->
          receive do
            :symphony_stop -> exit(reason)
          end
        end)

      task = WorkspaceCleanup.request(c.context, worker, true)
      assert :ok = Task.await(task)
      refute File.exists?(c.workspace)
    end

    assert :ok = c.context |> WorkspaceCleanup.request(nil, true) |> Task.await()
  end

  test "managed process stops descendants after their shell exits", c do
    {:ok, port} = ManagedProcess.open("sleep 60 </dev/null >/dev/null 2>&1 & echo $!", c.workspace)
    assert_receive {^port, {:data, {:eol, data}}}, 3_000
    descendant = String.trim(data)
    assert_receive {^port, {:exit_status, 0}}, 3_000
    assert :ok = ManagedProcess.stop(port)
    assert :ok = ManagedProcess.stop(port)
    refute process_running?(descendant)
    assert :ok = ManagedProcess.stop_all()
  end

  test "hook descendants are gone when the hook finishes or times out", c do
    for command <- ["sleep 60 & echo $! > child", "sleep 60 & echo $! > child; wait"] do
      result = ManagedProcess.command(command, c.workspace, 200)
      assert match?({:ok, {_, 0}}, result) or result == {:error, :timeout}
      child = Path.join(c.workspace, "child") |> File.read!() |> String.trim()
      refute process_running?(child)
    end
  end

  test "detached descendants are reaped before a command reports completion", c do
    assert {:ok, {_, 0}} = ManagedProcess.command("setsid bash -c 'sleep 60 & echo $! > detached' & wait", c.workspace, 2_000)
    pid = Path.join(c.workspace, "detached") |> File.read!() |> String.trim()
    refute process_running?(pid)
  end

  test "a missing process guard handshake refuses successful shutdown", c do
    bin = Path.join(c.root, "fake-bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "python3"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(bin, "python3"), 0o755)
    previous = System.get_env("PATH")

    try do
      System.put_env("PATH", bin)
      assert {:error, :process_guard_unverified} = ManagedProcess.open("unused", c.workspace)
      assert {:error, {:process_guard_unverified, completion}} = ManagedProcess.stop_all()
      refute File.exists?(completion)
      File.rmdir!(Path.dirname(completion))
    after
      restore_env("PATH", previous)
    end
  end

  test "command preserves an unterminated output line", c do
    assert {:ok, {"partial", 0}} = ManagedProcess.command("printf partial", c.workspace, 2_000)
  end

  test "unreadable generation and remote cleanup are explicit failures", c do
    paths = WorkspaceLease.paths(c.root, c.issue.identifier)
    File.mkdir_p!(paths.generation)
    assert {:error, :eisdir} = WorkspaceLease.generation(paths)
    assert {:error, :eisdir} = c.context |> WorkspaceCleanup.request(nil, true) |> Task.await()
    context = %{c.context | worker_host: "worker.example"}
    assert {:error, :remote_process_termination_unverified} = context |> WorkspaceCleanup.request(nil, true) |> Task.await()
    assert File.dir?(c.workspace)
  end

  test "configuration errors during removal are logged without losing the workspace", c do
    parent = self()

    worker =
      spawn(fn ->
        receive do
          :symphony_stop -> send(parent, :stopping)
        end

        receive do
          :finish -> :ok
        end
      end)

    task = WorkspaceCleanup.request(c.context, worker, true)
    assert_receive :stopping
    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: %{invalid: true})
    send(worker, :finish)
    assert {:error, {:cleanup_exception, message}} = Task.await(task)
    assert message =~ "Invalid WORKFLOW.md config"
    assert File.dir?(c.workspace)
  end

  @tag timeout: 40_000
  test "long worker finalization emits a waiting log and retains the workspace", c do
    parent = self()

    worker =
      spawn(fn ->
        receive do
          :symphony_stop -> send(parent, :stopping)
        end

        receive do
          :finish -> :ok
        end
      end)

    log =
      capture_log(fn ->
        task = WorkspaceCleanup.request(c.context, worker, true)
        assert_receive :stopping
        assert File.dir?(c.workspace)
        Process.send_after(worker, :finish, 30_200)
        assert :ok = Task.await(task, 35_000)
      end)

    assert log =~ "Workspace cleanup waiting for worker"
    assert log =~ "issue_identifier=MT-CLEAN"
    refute File.exists?(c.workspace)
  end

  test "real runner completes after_run and stops Codex descendants before deletion", c do
    entered = Path.join(c.root, "after-run-entered")
    release = Path.join(c.root, "after-run-release")
    app_pid = Path.join(c.root, "app-pid")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: c.root,
      codex_command: "echo $$ > '#{app_pid}'; sleep 60",
      hook_after_run: "touch '#{entered}'; while [ ! -f '#{release}' ]; do sleep 0.01; done; echo finalized > finalized"
    )

    {:ok, worker} = Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn -> AgentRunner.run(c.issue) end)
    eventually(fn -> File.exists?(app_pid) end)
    os_pid = File.read!(app_pid) |> String.trim()
    task = WorkspaceCleanup.request(c.context, worker, true)
    eventually(fn -> File.exists?(entered) end)
    assert Process.alive?(worker)
    assert File.dir?(c.workspace)
    refute Task.yield(task, 0)
    File.write!(release, "go")
    assert :ok = Task.await(task, 5_000)
    refute Process.alive?(worker)
    refute process_running?(os_pid)
    refute File.exists?(c.workspace)
  end

  test "supervisor shutdown gracefully releases the worker lease", c do
    app_pid = Path.join(c.root, "shutdown-app-pid")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: c.root, codex_command: "echo $$ > '#{app_pid}'; sleep 60")
    {:ok, worker} = Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn -> AgentRunner.run(c.issue) end)
    eventually(fn -> File.exists?(app_pid) end)
    assert :ok = Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, worker)
    refute File.exists?(WorkspaceLease.paths(c.root, c.issue.identifier).lock)
    assert File.dir?(c.workspace)
    refute process_running?(File.read!(app_pid) |> String.trim())
  end

  test "cleanup task crash retains failure state and snapshot responsiveness", c do
    {entered, release} = removal_barrier(c)
    orchestrator = start_orchestrator()
    reconcile(orchestrator, c.issue, nil)
    eventually(fn -> File.exists?(entered) end)
    cleanup = :sys.get_state(orchestrator).cleanups[c.issue.id]
    Process.exit(cleanup.pid, :kill)
    File.write!(release, "go")
    eventually(fn -> match?([%{status: :failed}], Orchestrator.snapshot(orchestrator, 200).cleanups) end)
    assert File.dir?(WorkspaceLease.paths(c.root, c.issue.identifier).lock)
    assert File.dir?(c.workspace)
  end

  defp removal_barrier(c) do
    entered = Path.join(c.root, "entered")
    release = Path.join(c.root, "release")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: c.root,
      poll_interval_ms: 60_000,
      codex_command: "exit 1",
      tracker_active_states: ["In Progress", "Rework"],
      hook_before_remove: "touch '#{entered}'; while [ ! -f '#{release}' ]; do sleep 0.01; done"
    )

    on_exit(fn -> File.write(release, "go") end)
    {entered, release}
  end

  defp start_orchestrator do
    name = String.to_atom("cleanup-orchestrator-#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  defp reconcile(orchestrator, issue, worker) do
    :sys.replace_state(orchestrator, fn state ->
      entry = %{
        pid: worker,
        ref: nil,
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        session_id: nil
      }

      state = %{state | running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
      Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Done"}], state)
    end)
  end

  defp process_running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, data} -> not String.contains?(data, ") Z ")
      _ -> false
    end
  end

  defp eventually(fun, attempts \\ 500)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
