defmodule SymphonyElixir.ContextPolicy do
  @moduledoc """
  WORKFLOW と同じ場所を基準に、工程別モデル設定を実行開始時に読み込む。
  読み込み失敗時は既定モデルへ切り替えず、その実行を停止する。
  """

  alias SymphonyElixir.{Config, Workflow}

  @efforts ~w(none minimal low medium high xhigh max ultra)

  @spec load(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def load(state) do
    config = Config.settings!()

    case config.codex.state_policy_file do
      nil -> {:ok, nil}
      file -> load_file(file, state, config)
    end
  end

  defp load_file(file, state, config) do
    path = Path.expand(file, Path.dirname(Workflow.workflow_file_path()))

    with :ok <- local_workers(config.worker.ssh_hosts),
         {:ok, content} <- File.read(path),
         {:ok, json} <- Jason.decode(content),
         {:ok, states, ratio} <- validate(json, config.tracker.active_states),
         {:ok, selected} <- Map.fetch(states, normalize(state)) do
      {:ok, Map.put(selected, :context_warning_ratio, ratio)}
    else
      error -> {:error, {:invalid_state_policy, path, error}}
    end
  end

  @spec validate(term(), [String.t()]) :: {:ok, map(), float()} | {:error, term()}
  def validate(%{"version" => 1, "states" => states} = json, required) when is_map(states) do
    ratio = Map.get(json, "context_warning_ratio", 0.8)

    with true <- Map.keys(json) -- ~w(version states context_warning_ratio) == [],
         true <- is_number(ratio) and ratio > 0 and ratio <= 1,
         {:ok, normalized} <- normalize_states(states),
         true <- Enum.all?(required, &Map.has_key?(normalized, normalize(&1))) do
      {:ok, normalized, ratio / 1}
    else
      _ -> {:error, :invalid_or_missing_state_settings}
    end
  end

  def validate(_, _), do: {:error, :invalid_policy_schema}

  defp normalize_states(states) do
    Enum.reduce_while(states, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      key = normalize(name)

      if valid_selection?(value) and key != "" and not Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, %{model: value["model"], effort: value["effort"]})}}
      else
        {:halt, {:error, :invalid_state}}
      end
    end)
  end

  defp valid_selection?(%{"model" => model, "effort" => effort} = value)
       when is_binary(model) and effort in @efforts do
    String.trim(model) != "" and map_size(value) == 2
  end

  defp valid_selection?(_), do: false

  defp local_workers([]), do: :ok
  defp local_workers(_), do: {:error, :persistent_threads_require_local_worker}
  defp normalize(value), do: value |> String.trim() |> String.downcase()
end
