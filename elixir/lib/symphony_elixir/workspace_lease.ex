defmodule SymphonyElixir.WorkspaceLease do
  @moduledoc """
  workspace 外の排他記録。異常な VM 終了後は自動解除せず、再利用と削除を拒否する。
  世代は実行のたびに更新し、古い削除要求が新しい実行を削除することを防ぐ。
  """

  @spec paths(String.t(), String.t()) :: map()
  def paths(root, identifier) do
    key = String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
    base = Path.join([root, ".symphony-leases", key])
    %{lock: base <> ".lock", generation: base <> ".generation"}
  end

  @spec generation(map()) :: {:ok, binary() | nil} | {:error, term()}
  def generation(paths) do
    case File.read(paths.generation) do
      {:ok, value} -> {:ok, value}
      {:error, :enoent} -> {:ok, nil}
      error -> error
    end
  end

  @spec acquire(map(), map()) :: :ok | {:error, term()}
  def acquire(paths, context) do
    with :ok <- File.mkdir_p(Path.dirname(paths.lock)),
         :ok <- File.mkdir(paths.lock) do
      # 記録に失敗した場合も lock を残す。安全性を確認せず引き継がない。
      context = Map.merge(context, %{beam_os_pid: System.pid(), erlang_pid: inspect(self()), started_at: DateTime.to_iso8601(DateTime.utc_now())})
      File.write(Path.join(paths.lock, "owner.json"), Jason.encode!(context))
    end
  end

  @spec advance(map()) :: :ok | {:error, term()}
  def advance(paths) do
    value = Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
    File.write(paths.generation, value)
  end

  @spec release(map()) :: :ok | {:error, term()}
  def release(paths) do
    with :ok <- File.rm(Path.join(paths.lock, "owner.json")), do: File.rmdir(paths.lock)
  end
end
