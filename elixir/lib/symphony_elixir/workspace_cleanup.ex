defmodule SymphonyElixir.WorkspaceCleanup do
  @moduledoc """
  worker の DOWN を待ってから削除する。待機と再帰削除は Orchestrator の外で行う。
  """
  require Logger
  alias SymphonyElixir.{Config, Workspace, WorkspaceLease}

  @spec request(map(), pid() | nil, boolean()) :: Task.t()
  def request(context, worker, remove?) do
    # 設定の再読込や issue 再開で対象が変わらないよう要求時に固定する。
    root = Config.settings!().workspace.root
    paths = WorkspaceLease.paths(root, context.identifier)
    expected = WorkspaceLease.generation(paths)
    workspace = Path.join(root, String.replace(context.identifier, ~r/[^a-zA-Z0-9._-]/, "_"))
    remote? = is_binary(context[:worker_host]) or Config.settings!().worker.ssh_hosts != []

    Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
      started = System.monotonic_time(:millisecond)
      Logger.info("Workspace cleanup started #{log_context(context)} workspace=#{workspace} remove=#{remove?}")
      wait_for_worker(worker, context)
      result = execute(context, workspace, paths, expected, remove?, remote?)
      elapsed = System.monotonic_time(:millisecond) - started

      if result == :ok do
        Logger.info("Workspace cleanup completed #{log_context(context)} workspace=#{workspace} elapsed_ms=#{elapsed}")
      else
        Logger.error("Workspace cleanup failed #{log_context(context)} workspace=#{workspace} elapsed_ms=#{elapsed} reason=#{inspect(result)}")
      end

      result
    end)
  end

  defp wait_for_worker(worker, context) when is_pid(worker) do
    ref = Process.monitor(worker)
    send(worker, :symphony_stop)
    await_down(ref, context)
  end

  defp wait_for_worker(_, _), do: :ok

  defp await_down(ref, context) do
    receive do
      {:DOWN, ^ref, :process, _pid, reason} ->
        Logger.info("Workspace worker stopped #{log_context(context)} reason=#{inspect(reason)}")
        :ok
    after
      30_000 ->
        Logger.warning("Workspace cleanup waiting for worker #{log_context(context)}")
        await_down(ref, context)
    end
  end

  defp execute(_context, _workspace, _paths, _expected, false, _remote?), do: :ok
  defp execute(_context, _workspace, _paths, _expected, true, true), do: {:error, :remote_process_termination_unverified}

  defp execute(context, workspace, paths, expected, true, false) do
    remove(context, workspace, paths, expected)
  rescue
    error -> {:error, {:cleanup_exception, Exception.message(error)}}
  end

  defp remove(context, workspace, paths, expected) do
    owner = %{issue_id: context.issue_id, issue_identifier: context.identifier, operation: "cleanup"}

    with {:ok, _} <- expected,
         :ok <- WorkspaceLease.acquire(paths, owner) do
      case WorkspaceLease.generation(paths) do
        ^expected ->
          remove_locked(context, workspace, paths)

        actual ->
          :ok = WorkspaceLease.release(paths)
          {:error, {:workspace_generation_changed, expected, actual}}
      end
    end
  end

  defp remove_locked(context, workspace, paths) do
    started = System.monotonic_time(:millisecond)
    Logger.info("Workspace removal started #{log_context(context)} workspace=#{workspace}")
    result = Workspace.remove(workspace)
    elapsed = System.monotonic_time(:millisecond) - started
    Logger.info("Workspace removal finished #{log_context(context)} workspace=#{workspace} elapsed_ms=#{elapsed} result=#{inspect(removal_result(result))}")

    case result do
      {:ok, _} -> WorkspaceLease.release(paths)
      error -> error
    end
  end

  defp removal_result({:ok, _paths}), do: :ok
  defp removal_result(error), do: error

  defp log_context(context), do: "issue_id=#{context.issue_id} issue_identifier=#{context.identifier} worker_host=#{context[:worker_host] || "local"}"
end
