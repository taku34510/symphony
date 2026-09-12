defmodule SymphonyElixir.ManagedProcess do
  @moduledoc """
  Linux の subreaper でローカルコマンドと子孫を所有し、終了確認を待つ。
  helper は escript に埋め込み、稼働 checkout に外部スクリプトを要求しない。
  """
  @external_resource Path.expand("../../priv/process_guard.py", __DIR__)
  @guard_source File.read!(@external_resource)

  @spec open(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def open(command, workspace, opts \\ []) do
    with executable when is_binary(executable) <- System.find_executable("python3"),
         true <- File.dir?("/proc/self") do
      directory = Path.join(System.tmp_dir!(), "symphony-process-" <> Base.encode16(:crypto.strong_rand_bytes(16)))
      :ok = File.mkdir(directory)
      :ok = File.chmod(directory, 0o700)
      completion = Path.join(directory, "stopped")
      {capture?, opts} = Keyword.pop(opts, :capture, false)
      output = if capture?, do: Path.join(directory, "output"), else: ""
      args = Enum.map(["-c", @guard_source, command, completion, output], &String.to_charlist/1)
      cwd = String.to_charlist(workspace)
      port_opts = [:binary, :exit_status, :stderr_to_stdout, args: args, cd: cwd]

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          port_opts ++ Keyword.put_new(opts, :line, 1_048_576)
        )

      guard = %{pid: nil, identity: nil, completion: completion, output: output}
      Process.put({__MODULE__, port}, guard)

      receive do
        {^port, {:data, {:eol, "__SYMPHONY_SESSION__ " <> value}}} ->
          {pid, ""} = Integer.parse(value)
          Process.put({__MODULE__, port}, %{guard | pid: pid, identity: identity(pid)})
          {:ok, port}
      after
        5_000 -> {:error, :process_guard_unverified}
      end
    else
      _ -> {:error, :managed_process_requires_linux_python3}
    end
  end

  @spec stop(port()) :: :ok | {:error, term()}
  def stop(port) do
    case Process.get({__MODULE__, port}) do
      nil ->
        close(port)

      guard ->
        if guard.identity && identity(guard.pid) == guard.identity do
          System.cmd("kill", ["-TERM", "--", to_string(guard.pid)], stderr_to_stdout: true)
        end

        result = await_stop(guard.completion, System.monotonic_time(:millisecond) + 5_000)
        close(port)

        if result == :ok do
          forget(port, guard)
        end

        result
    end
  end

  defp forget(port, guard) do
    File.rm(guard.completion)
    if guard.output != "", do: File.rm(guard.output)
    File.rmdir(Path.dirname(guard.completion))
    Process.delete({__MODULE__, port})
  end

  @spec stop_all() :: :ok | {:error, term()}
  def stop_all do
    Process.get_keys()
    |> Enum.filter(&match?({__MODULE__, _}, &1))
    |> Enum.reduce(:ok, fn {__MODULE__, port}, result ->
      case stop(port) do
        :ok -> result
        error -> error
      end
    end)
  end

  @spec command(String.t(), String.t(), pos_integer()) :: {:ok, {binary(), integer()}} | {:error, term()}
  def command(command, workspace, timeout) do
    with {:ok, port} <- open(command, workspace, capture: true) do
      try do
        output = Process.get({__MODULE__, port}).output
        collect(port, System.monotonic_time(:millisecond) + timeout, output)
      after
        :ok = stop(port)
      end
    end
  end

  defp collect(port, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:exit_status, status}} -> {:ok, {File.read!(output), status}}
    after
      remaining -> {:error, :timeout}
    end
  end

  defp await_stop(completion, deadline) do
    cond do
      File.read(completion) == {:ok, "stopped\n"} ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:process_guard_unverified, completion}}

      true ->
        receive do
        after
          10 -> :ok
        end

        await_stop(completion, deadline)
    end
  end

  defp identity(pid) do
    with {:ok, data} <- File.read("/proc/#{pid}/stat"),
         [_, fields] <- Regex.run(~r/^.*\) (.*)$/s, data),
         values when length(values) >= 20 <- String.split(fields) do
      Enum.at(values, 19)
    else
      _ -> nil
    end
  end

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
