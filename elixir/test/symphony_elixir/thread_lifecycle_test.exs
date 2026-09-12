defmodule SymphonyElixir.ThreadLifecycleTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ContextPolicy, ThreadLifecycle}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    workspace = Path.join(root, "workspaces/MT-1")
    File.mkdir_p!(Path.join(workspace, ".git"))

    policy = %{
      "version" => 1,
      "states" =>
        Map.new(
          ~w(Todo Design Implementation Rework) ++ ["AI Review", "Review Q&A", "Merging"],
          &{&1, %{"model" => "gpt-6-astra", "effort" => "medium"}}
        )
    }

    path = Path.join(root, "models.json")
    File.write!(path, Jason.encode!(policy))
    phases = %{"Design" => "design", "Implementation" => "implementation", "AI Review" => "ai_review", "Rework" => "rework"}

    write_workflow_file!(Workflow.workflow_file_path(),
      state_policy_file: "models.json",
      tracker_active_states: Map.keys(policy["states"]),
      workspace_root: Path.join(root, "workspaces"),
      session_phase_by_state: phases,
      hook_after_create: "mkdir -p .git"
    )

    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "Implementation", title: "test", labels: []}
    {:ok, root: root, workspace: workspace, issue: issue, policy: policy, path: path}
  end

  test "policy validates explicit states and rejects malformed or incomplete configuration", %{policy: policy} do
    assert {:ok, _, 0.8} = ContextPolicy.validate(policy, ["Implementation"])

    for invalid <- [
          nil,
          %{},
          %{policy | "version" => 2},
          Map.put(policy, "context_warning_ratio", 0),
          Map.put(policy, "unexpected", true),
          %{policy | "states" => %{}},
          put_in(policy, ["states", "Implementation"], %{"model" => " ", "effort" => "medium"}),
          put_in(policy, ["states", "Implementation"], %{"model" => "x", "effort" => "bad"}),
          put_in(policy, ["states", "Implementation"], %{"model" => "x", "effort" => "medium", "typo" => 1}),
          put_in(policy, ["states", " implementation "], %{"model" => "x", "effort" => "medium"})
        ] do
      assert {:error, _} = ContextPolicy.validate(invalid, ["Implementation"])
    end
  end

  test "JSON changes apply on next execution, with no default fallback on error", context do
    assert {:ok, %{model: "gpt-6-astra"}} = ContextPolicy.load("Implementation")
    File.write!(context.path, Jason.encode!(put_in(context.policy, ["states", "Implementation", "model"], "gpt-5.6-terra")))
    assert {:ok, %{model: "gpt-5.6-terra"}} = ContextPolicy.load("Implementation")
    File.write!(context.path, "broken")
    assert {:error, _} = ContextPolicy.load("Implementation")
    File.rm!(context.path)
    assert {:error, _} = ContextPolicy.load("Implementation")
    write_workflow_file!(Workflow.workflow_file_path(), state_policy_file: "models.json", worker_ssh_hosts: ["remote"])
    assert {:error, {_, _, {:error, :persistent_threads_require_local_worker}}} = ContextPolicy.load("Implementation")
    write_workflow_file!(Workflow.workflow_file_path())
    assert {:ok, nil} = ContextPolicy.load("Implementation")
    assert {:ok, nil} = ThreadLifecycle.prepare(context.workspace, context.issue)
    assert [] == ThreadLifecycle.session_options(nil)
    assert {:ok, nil} = ThreadLifecycle.attach(nil, "id")
    assert :ok = ThreadLifecycle.finish_turn(nil)
    assert "prompt" == ThreadLifecycle.prompt(nil, "prompt")
    assert %{} == ThreadLifecycle.observe(nil, %{})
  end

  test "implementation survives review, human wait, restart and changed workflow", %{workspace: workspace, issue: issue} do
    {:ok, initial} = ThreadLifecycle.prepare(workspace, issue)
    assert initial.mode == "fresh"
    {:ok, initial} = ThreadLifecycle.attach(initial, "implementation-1")
    assert ThreadLifecycle.prompt(initial, "FULL") =~ "FULL"
    assert :ok = ThreadLifecycle.finish_turn(initial)
    {:ok, review} = ThreadLifecycle.prepare(workspace, %{issue | state: "AI Review"})
    assert review.thread_id == nil
    {:ok, _} = ThreadLifecycle.attach(review, "review-1")
    {:ok, resumed} = ThreadLifecycle.prepare(workspace, issue)
    assert resumed.thread_id == "implementation-1"
    {:ok, resumed} = ThreadLifecycle.attach(resumed, "implementation-1")
    refute ThreadLifecycle.prompt(resumed, "FULL") =~ "FULL"
    assert resumed.state["attempt"] == initial.state["attempt"]
    {:ok, another_review} = ThreadLifecycle.prepare(workspace, %{issue | state: "AI Review"})
    assert another_review.thread_id == nil
    File.write!(Workflow.workflow_file_path(), File.read!(Workflow.workflow_file_path()) <> "\nNew workflow rule")
    {:ok, resumed} = ThreadLifecycle.prepare(workspace, issue)
    {:ok, resumed} = ThreadLifecycle.attach(resumed, "implementation-1")
    assert ThreadLifecycle.prompt(resumed, "UPDATED") =~ "UPDATED"
  end

  test "missing rollout recovers but transient and permission failures do not", %{workspace: workspace, issue: issue} do
    assert ThreadLifecycle.recoverable?({:response_error, %{"message" => "no rollout found for id"}})
    refute ThreadLifecycle.recoverable?(:response_timeout)
    refute ThreadLifecycle.recoverable?({:response_error, %{"message" => "permission denied"}})
    {:ok, context} = ThreadLifecycle.prepare(workspace, issue)
    recovered = ThreadLifecycle.recovered(context)
    {:ok, recovered} = ThreadLifecycle.attach(recovered, "replacement")
    assert ThreadLifecycle.prompt(recovered, "FULL") =~ "新規スレッドで復旧"
  end

  test "usage is persisted and resumed totals exclude previously observed tokens", %{workspace: workspace, issue: issue} do
    {:ok, context} = ThreadLifecycle.prepare(workspace, issue)
    {:ok, context} = ThreadLifecycle.attach(context, "impl")

    usage = %{
      "total" => %{"inputTokens" => 100, "cachedInputTokens" => 80, "outputTokens" => 10, "reasoningOutputTokens" => 5, "totalTokens" => 110},
      "last" => %{"totalTokens" => 85},
      "modelContextWindow" => 100
    }

    event = %{payload: %{"params" => %{"tokenUsage" => usage}}}
    assert capture_log(fn -> ThreadLifecycle.observe(context, event) end) =~ "Context soft limit"
    {:ok, resumed} = ThreadLifecycle.prepare(workspace, issue)
    {:ok, resumed} = ThreadLifecycle.attach(resumed, "impl")
    updated = ThreadLifecycle.observe(resumed, put_in(event, [:payload, "params", "tokenUsage", "total", "inputTokens"], 150))
    assert get_in(updated, [:usage, "tokenUsage", "total", "inputTokens"]) == 50
    assert get_in(updated, [:usage, "tokenUsage", "total", "cachedInputTokens"]) == 0
    assert File.read!(Path.join(workspace, ".git/symphony/token_usage.jsonl")) =~ "reasoningOutputTokens"
    assert %{} == ThreadLifecycle.observe(context, %{})
  end

  test "late usage tolerates a missing workspace without recreating it", %{workspace: workspace, issue: issue} do
    {:ok, context} = ThreadLifecycle.prepare(workspace, %{issue | state: "Merging"})
    {:ok, context} = ThreadLifecycle.attach(context, "last-thread")
    File.rm_rf!(workspace)
    event = %{payload: %{"params" => %{"tokenUsage" => %{"total" => %{"inputTokens" => 7}}}}}

    log =
      capture_log(fn ->
        assert get_in(ThreadLifecycle.observe(context, event), [:usage, "tokenUsage", "total", "inputTokens"]) == 7
      end)

    assert log =~ "Thread usage log write failed"
    assert log =~ "issue_identifier=MT-1"
    assert log =~ "thread_id=last-thread"
    assert log =~ ":enoent"
    refute File.exists?(workspace)
  end

  test "usage append failure is nonfatal but critical state persistence still fails", %{workspace: workspace, issue: issue} do
    {:ok, context} = ThreadLifecycle.prepare(workspace, issue)
    {:ok, context} = ThreadLifecycle.attach(context, "impl")
    File.mkdir_p!(Path.join(workspace, ".git/symphony/token_usage.jsonl"))
    event = %{payload: %{"params" => %{"tokenUsage" => %{"total" => %{"inputTokens" => 7}}}}}
    assert capture_log(fn -> ThreadLifecycle.observe(context, event) end) =~ ":unsafe_session_file"
    File.rm!(Path.join(workspace, ".git/symphony/session_state.json"))
    File.mkdir_p!(Path.join(workspace, ".git/symphony/session_state.json"))
    assert {:error, :unsafe_session_file} = ThreadLifecycle.attach(context, "new")
    assert_raise RuntimeError, fn -> ThreadLifecycle.observe(context, event) end
  end

  test "review input is scoped to the attempt and rework deletes old workspace", %{workspace: workspace, issue: issue} do
    {:ok, initial} = ThreadLifecycle.prepare(workspace, issue)
    {:ok, initial} = ThreadLifecycle.attach(initial, "impl")
    file = Path.join(workspace, ".git/symphony/review_findings.json")
    File.write!(file, Jason.encode!(%{"attempt" => initial.state["attempt"], "findings" => [%{"id" => "F-1"}]}))
    assert ThreadLifecycle.prompt(initial, "FULL") =~ "F-1"
    File.write!(file, Jason.encode!(%{"attempt" => "wrong", "findings" => [%{"id" => "STALE"}]}))
    refute ThreadLifecycle.prompt(initial, "FULL") =~ "STALE"
    File.write!(Path.join(workspace, "uncommitted.txt"), "old")
    {:ok, rework} = ThreadLifecycle.prepare(workspace, %{issue | state: "Rework"})
    {:ok, _} = ThreadLifecycle.attach(rework, "rework")
    assert {:error, :rework_requires_design} = ThreadLifecycle.prepare(workspace, issue)
    {:ok, design} = ThreadLifecycle.prepare(workspace, %{issue | state: "Design"})
    refute File.exists?(Path.join(workspace, "uncommitted.txt"))
    refute design.state["attempt"] == initial.state["attempt"]
    {:ok, impl} = ThreadLifecycle.prepare(workspace, issue)
    assert impl.thread_id == nil
  end

  test "state corruption and symlinks never resume another issue", %{workspace: workspace, issue: issue, root: root} do
    {:ok, _} = ThreadLifecycle.prepare(workspace, issue)
    state_path = Path.join(workspace, ".git/symphony/session_state.json")
    File.write!(state_path, "invalid")
    assert {:error, :invalid_session_state} = ThreadLifecycle.prepare(workspace, issue)
    File.rm!(state_path)
    File.ln_s!(Path.join(root, "outside.json"), state_path)
    assert {:error, :unsafe_session_file} = ThreadLifecycle.prepare(workspace, issue)
  end

  test "runner uses fresh reviewer and resumes implementation with next-execution model", context do
    configure_runner(context, "ok")
    stop = fn _ -> {:ok, [%{context.issue | state: "Human Review"}]} end
    assert :ok = AgentRunner.run(context.issue, nil, issue_state_fetcher: stop)
    assert :ok = AgentRunner.run(%{context.issue | state: "AI Review"}, nil, issue_state_fetcher: stop)
    File.write!(context.path, Jason.encode!(put_in(context.policy, ["states", "Implementation", "model"], "gpt-5.6-terra")))
    assert :ok = AgentRunner.run(context.issue, nil, issue_state_fetcher: stop)
    assert :ok = AgentRunner.run(%{context.issue | state: "AI Review"}, nil, issue_state_fetcher: stop)
    requests = requests(context)
    starts = Enum.filter(requests, &(&1["method"] == "thread/start"))
    resumes = Enum.filter(requests, &(&1["method"] == "thread/resume"))
    assert length(starts) == 3
    assert length(resumes) == 1
    assert hd(resumes)["params"]["model"] == "gpt-5.6-terra"
    refute Map.has_key?(hd(resumes)["params"], "dynamicTools")
    turns = Enum.filter(requests, &(&1["method"] == "turn/start"))
    assert Enum.at(turns, 0)["params"]["threadId"] == Enum.at(turns, 2)["params"]["threadId"]
    refute Enum.at(turns, 1)["params"]["threadId"] == Enum.at(turns, 3)["params"]["threadId"]
    assert Enum.at(turns, 2)["params"]["model"] == "gpt-5.6-terra"
    assert Enum.at(turns, 2)["params"]["effort"] == "medium"
    assert hd(Enum.at(turns, 2)["params"]["input"])["text"] =~ "同じ試行・同じスレッド"
  end

  test "runner recovers a missing thread but never replaces a permission failure", context do
    configure_runner(context, "ok")
    stop = fn _ -> {:ok, [%{context.issue | state: "Human Review"}]} end
    assert :ok = AgentRunner.run(context.issue, nil, issue_state_fetcher: stop)
    configure_runner(context, "missing")
    assert :ok = AgentRunner.run(context.issue, nil, issue_state_fetcher: stop)
    turns = Enum.filter(requests(context), &(&1["method"] == "turn/start"))
    refute hd(turns)["params"]["threadId"] == List.last(turns)["params"]["threadId"]
    assert hd(List.last(turns)["params"]["input"])["text"] =~ "新規スレッドで復旧"
    configure_runner(context, "denied")
    assert_raise RuntimeError, fn -> AgentRunner.run(context.issue, nil, issue_state_fetcher: stop) end
    assert length(Enum.filter(requests(context), &(&1["method"] == "turn/start"))) == 2
  end

  test "reset journal retries failed recreation without reusing a thread", context do
    {:ok, state} = ThreadLifecycle.prepare(context.workspace, context.issue)
    {:ok, _} = ThreadLifecycle.attach(state, "old")
    {:ok, _} = ThreadLifecycle.prepare(context.workspace, %{context.issue | state: "Rework"})
    config_text = File.read!(Workflow.workflow_file_path())
    File.write!(Workflow.workflow_file_path(), String.replace(config_text, "mkdir -p .git", "exit 1"))
    assert {:error, _} = ThreadLifecycle.prepare(context.workspace, %{context.issue | state: "Design"})
    assert {:error, :rework_requires_design} = ThreadLifecycle.prepare(context.workspace, context.issue)
    File.write!(Workflow.workflow_file_path(), config_text)
    assert {:ok, fresh} = ThreadLifecycle.prepare(context.workspace, %{context.issue | state: "Design"})
    assert fresh.thread_id == nil
    refute fresh.state["attempt"] == state.state["attempt"]
  end

  defp configure_runner(context, mode) do
    command = "python3 #{Path.expand("../support/context_app_server.py", __DIR__)} #{context.root}/trace.jsonl #{mode}"
    text = File.read!(Workflow.workflow_file_path())
    text = Regex.replace(~r/^  command:.*$/m, text, "  command: \"#{command}\"")
    File.write!(Workflow.workflow_file_path(), text)
  end

  test "persistent state refuses corrupt counters, wrong issues and unsafe storage", context do
    {:ok, initial} = ThreadLifecycle.prepare(context.workspace, context.issue)
    path = Path.join(context.workspace, ".git/symphony/session_state.json")

    for corrupt <- [
          Map.put(initial.state, "issue_id", "another"),
          Map.put(initial.state, "implementation_thread_id", 12),
          Map.put(initial.state, "implementation_usage", %{"inputTokens" => "bad"}),
          Map.put(initial.state, "review_round", "bad")
        ] do
      File.write!(path, Jason.encode!(corrupt))
      assert {:error, :invalid_session_state} = ThreadLifecycle.prepare(context.workspace, context.issue)
    end

    File.write!(path, "broken")
    {:ok, attached} = ThreadLifecycle.attach(initial, "impl")
    File.write!(path, "broken")

    assert_raise RuntimeError, fn ->
      ThreadLifecycle.observe(attached, %{payload: %{"params" => %{"tokenUsage" => %{"total" => %{"inputTokens" => 1}}}}})
    end

    File.write!(path, Jason.encode!(initial.state))
    File.chmod!(path, 0o000)
    assert {:error, :eacces} = ThreadLifecycle.prepare(context.workspace, context.issue)
    File.chmod!(path, 0o600)
    unsafe = Path.join(context.root, "unsafe")
    File.mkdir_p!(unsafe)
    assert {:error, :unsafe_session_storage} = ThreadLifecycle.prepare(unsafe, context.issue)
    File.ln_s!(Path.join(context.workspace, ".git"), Path.join(unsafe, ".git"))
    assert {:error, :unsafe_session_storage} = ThreadLifecycle.prepare(unsafe, context.issue)
  end

  test "implementation checkpoint records a real HEAD", context do
    System.cmd("git", ["init", "-b", "main", context.workspace])
    {_, 0} = System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial"], cd: context.workspace)
    {:ok, initial} = ThreadLifecycle.prepare(context.workspace, context.issue)
    :ok = ThreadLifecycle.finish_turn(initial)
    {:ok, readback} = ThreadLifecycle.prepare(context.workspace, context.issue)
    assert String.length(readback.state["implementation_head_sha"]) == 40
  end

  test "phase and sandbox settings reject invalid boundaries" do
    alias SymphonyElixir.Config.Schema
    assert Schema.normalize_state_string_map(nil) == %{}
    assert Schema.normalize_state_string_map(%{"Design" => 42}) == %{"design" => "42"}
    assert {:error, _} = Schema.parse(%{"tracker" => %{"api_key" => "test"}, "agent" => %{"session_phase_by_state" => %{"Design" => ""}}})
    {:ok, base} = Schema.parse(%{"tracker" => %{"api_key" => "test"}})

    policies = [
      %{"type" => "workspaceWrite"},
      %{"type" => "workspaceWrite", "readOnlyAccess" => %{"type" => "fullAccess"}},
      %{"type" => "workspaceWrite", "writableRoots" => [".", "/tmp"]}
    ]

    for policy <- policies do
      settings = %{base | codex: %{base.codex | turn_sandbox_policy: policy}}
      assert {:ok, _} = Schema.resolve_runtime_turn_sandbox_policy(settings, "/tmp", remote: true)
      assert {:error, _} = Schema.resolve_runtime_turn_sandbox_policy(settings, "relative", remote: true)
      settings = %{settings | workspace: %{settings.workspace | root: nil}}
      assert {:error, _} = Schema.resolve_runtime_turn_sandbox_policy(settings, nil)
    end

    for roots <- ["bad", [nil], ["../outside"]] do
      settings = %{base | codex: %{base.codex | turn_sandbox_policy: %{"type" => "workspaceWrite", "writableRoots" => roots}}}
      assert {:error, _} = Schema.resolve_runtime_turn_sandbox_policy(settings, "/tmp/root", remote: true)
    end
  end

  defp requests(context) do
    Path.join(context.root, "trace.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end
end
