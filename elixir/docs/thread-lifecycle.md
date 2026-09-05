# 工程別モデルと Implementation スレッドの再開

## 設定

PlantStella 用の WORKFLOW は次の設定を持つ。起動コマンドにモデルや推論強度を固定せず、JSON で全実行対象工程を指定する。

```yaml
agent:
  session_phase_by_state:
    Todo: todo
    Design: design
    Implementation: implementation
    "AI Review": ai_review
    "Review Q&A": review_qa
    Rework: rework
    Merging: merging
codex:
  command: codex app-server
  state_policy_file: project/targets/symphony_models.json
```

JSON の形式は次のとおり。実行対象の全工程を `states` に含める。

```json
{
  "version": 1,
  "context_warning_ratio": 0.8,
  "states": {
    "Todo": {"model": "gpt-5.6-terra", "effort": "medium"},
    "Design": {"model": "gpt-6-astra", "effort": "high"},
    "Implementation": {"model": "gpt-6-astra", "effort": "medium"},
    "AI Review": {"model": "gpt-6-astra", "effort": "high"},
    "Review Q&A": {"model": "gpt-6-astra", "effort": "medium"},
    "Rework": {"model": "gpt-5.6-terra", "effort": "medium"},
    "Merging": {"model": "gpt-5.6-terra", "effort": "medium"}
  }
}
```

参照先は起動時に指定した WORKFLOW の場所を基準に解決する。JSON は各実行の開始時に読み、同じ実行の継続ターンでは選択を維持する。再開するスレッドでも次の実行からモデルを変更できる。不正・欠落した設定は実行エラーとし、既定モデルへ切り替えない。指定モデルと effort の組み合わせの利用可否は Codex のモデル一覧で確認する。

現行拡張はローカル worker と通常の git clone を対象にする。SSH worker を設定した場合と `.git` がディレクトリでない workspace は拒否する。永続化先と Codex の履歴保存先を別ホストへ移す機能は持たない。

## ライフサイクル

`implementation` 工程だけは、試行ごとの `.git/symphony/session_state.json` に保存したスレッドを再開する。サービス再起動、max_turns 到達、AI Review や人の修正依頼の後も同じ登録を使う。他の工程は新規スレッドを開始する。同一実行内の継続ターンは既存のセッションを使う。

登録には `version: 1`、`issue_id`、不透明な文字列の `attempt`、`phase`、`active_thread_id`、`implementation_thread_id`、`implementation_head_sha`、`implementation_workflow_hash`、`implementation_usage` を保存する。必要な時点まで任意フィールドは省略する。ファイルは原子的に更新し、issue が異なる登録、壊れた登録、symlink は受け付けない。

再開に成功した場合は最新の Workpad・指摘・HEAD・差分を読む短い指示を渡す。WORKFLOW 本文のハッシュが変わった場合は全文を渡す。履歴消失が確定した場合は、workspace を維持し、新規スレッドで Workpad と成果物から復旧する。認証・権限・通信エラーは既存の再試行へ返す。

`rework` のエージェントは旧 PR と Workpad を整理し、新しい試行で必要な要求を外部の Workpad に残して `Design` へ移る。次の `design` 起動前に Symphony が旧 workspace を削除し、`hooks.after_create` で再作成する。チケットの phase は `rework` の次に必ず `design` とする。

削除前に workspace root の `.symphony-reset-<issue-id-hash>.json` を作り、新しい attempt と issue ID を記録する。削除・再作成中に中断した場合はこの記録から再試行する。完了後は記録を削除する。旧 conversation のファイルを Codex 全体から削除する処理は行わず、登録の破棄によって再利用を防ぐ。

## 引き継ぎと観測

Design の成果物は Workpad の `Implementation Handoff` とする。Goal、設計判断、変更範囲、維持条件、実装手順、検証方法、参照先、未解決事項を記録し、探索の全履歴を次工程へ渡さない。

Reviewer は `.git/symphony/review_findings.json` に `version: 1`、`attempt`、`head_sha`、`review_thread_id`、`findings` 配列を保存する。各 finding は `id`、`classification`、`summary`、`status` を持つ。Symphony は同じ attempt のデータだけを次の起動プロンプトへ渡す。最新の人の指摘の正本は Workpad と PR であり、この JSON の作成・更新は対象リポジトリの WORKFLOW が定める。

`Thread selected` ログでモデルとスレッドの対応を確認できる。`Thread usage` と `.git/symphony/token_usage.jsonl` は tokenUsage 通知の `total`、`last`、`modelContextWindow` を通知された範囲で記録する。入力、cached input、出力、reasoning の未通知項目は補完しない。

Implementation の累積使用量は保存した値を差し引いて Orchestrator へ渡す。再開前の消費を再度加算しない。JSONL を集計するときも、同じスレッドの差分を取る。Rework では JSONL も削除されるので、長期比較では実行サービスのログを保管する。通信中断により未通知の消費がある場合、課金額と一致する保証はない。

context は直近の `last.totalTokens / modelContextWindow` で警告する。自動圧縮、checkpoint、新規 Implementation スレッドへの自動切替は行わない。テストは模擬 app-server と一時 workspace を使い、実サービスや実チケットを変更しない。
