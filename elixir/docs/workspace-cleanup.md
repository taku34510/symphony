# workspace 終了・削除と復旧

## 2026-09-12 の調査結果

対象は `taku34510/symphony` の `plantstella`。稼働用 checkout は
`/home/taku3/symphony-plantstella`、HEAD は `8057839e07e8dc1ae0bce106c268c071128f0741` だった。
未コミット変更はなかった。指定 escript 内の `Orchestrator`、`AgentRunner`、
`ThreadLifecycle`、`Workspace` の BEAM MD5 は、この checkout の既存ビルドと一致した。
バイナリ全体の SHA-256 は `0b9ec43de65c72900b4c0f5919bcebcbacea33e1008e97ede063ddd206656494`。

起動元 `/mnt/c/temp/PlantStella` の `WORKFLOW.md` は polling が 10 秒、同時実行が 3、
workspace root が `/mnt/c/temp/symphony-workspaces`、hook timeout が 600 秒だった。
ローカル差分の `codex.read_timeout_ms: 60000` は保持した。これは別の開始時タイムアウト対策である。
実行環境は Elixir 1.19.5 / Erlang 28.4.1（OTP 28）。

詳細ログ `log/symphony.log.3` から確認した順序は次のとおり。時刻は JST。

| 時刻 | 観測した事実 |
| --- | --- |
| 22:21:44.900577 | TAK-328 の `Done` を検出し、active agent を停止する旨を記録（45321行） |
| 22:21:57.278218 | `item/agentMessage/delta` がなお到着 |
| 22:21:57.397044 | `item/completed` が到着（45541行） |
| 22:21:57.729447 | `.git/symphony/token_usage.jsonl` の `File.write!` が `enoent`。worker が異常終了（45542行） |
| 22:35:33 | 調査開始時に観測した別の稼働プロセスの開始時刻 |
| 22:37:25.192010 | 後のプロセスで TAK-330 を投入（45543行） |

`Done` 検出から使用量の例外まで約 12.829 秒ある。旧コードは Orchestrator の同じ callback 内で
`Workspace.remove_issue_workspaces` → `File.rm_rf` → `terminate_task` の順に実行する。
今回の WORKFLOW には `before_remove` hook がないため、同期処理の主な候補は再帰削除である。
同じ `enoent` は、9月7日の TAK-314 / TAK-310、9月8日の TAK-308 / TAK-316 / TAK-311 / TAK-315、
9月11日の TAK-323 でも記録されていた。

確定したのは、使用量保存先の消失と worker の異常終了である。旧プロセスは調査時点ですでに存在せず、
削除の開始・完了・所要時間のログもない。したがって、長時間停止の全期間を `File.rm_rf` 内にいたと断定はしない。
22:37 の投入再開も、旧プロセスが自然復旧した証拠ではない。使用量例外の後に通常の worker 終了通知を処理したログが
ないこと、同期削除中は snapshot と次回 polling を処理できないことは、削除待ちによる停止と整合する。
worker 単体の例外だけなら TaskSupervisor が Orchestrator に `DOWN` を通知するため、長時間の応答停止は別に説明が必要である。

元の `8057839` を隔離した checkout では、削除経路の hook を barrier で止めるだけで、worker が生存したまま
snapshot が既定の 15 秒でタイムアウトすることを再現した。使用量例外はこの試験では起こしていない。
別の試験で、保存先のない最後の使用量通知が旧版の `File.Error` を再現することも確認した。
この試験は同期削除経路の問題を立証するものであり、実機で hook が長時間待っていたという主張ではない。

履歴では、削除を worker 停止より先に行う順序と同期削除は、初期コミット `fa75ec6`（2026-03-04）から存在する。
`ff65c7c`（2026-03-11）は SSH host 対応を追加したが、この順序を変えていない。
`1d38a67`（2026-09-05）が毎回の token 通知で使用量を永続化し、追記を `File.write!` にした。
つまり、以前からあった競合に継続的な書込みが加わり、今回の worker 例外として表面化した。
「以前動いた」ことは競合の不在を意味しない。以前の削除時間・通知の重なり方を示す計測は残っていない。

## 終了と削除の契約

`Done` 検出 → worker への終了要求 → 最後の通知・終了処理 → worker の `DOWN` → 排他取得・世代照合 → 削除 → 完了通知。

- 終了待機と再帰削除は TaskSupervisor 配下の別 Task で行う。Orchestrator は snapshot、他 issue の投入、再試行処理を続ける。
- 終了中の issue は `cleanups` に保持する。worker の `DOWN` で実行枠を解放し、削除中は枠を消費しない。同じ issue の通常投入・再試行・Rework 投入を抑止する。
- worker と削除 Task の両方を監視する。最後の token 通知と削除完了通知の順序が逆転しても、worker の `DOWN` まで集計情報を保持する。
- ローカル Codex と hook は Linux の subreaper で起動する。shell 終了後に残る子孫や、`setsid` で切り離された子孫も引き取り、回収完了を確認する。
- `after_run` 中も workspace を残す。終了要求によって callback を抜けても後処理を実行する。hook は既存の timeout を適用する。
- 正常な supervisor shutdown も終了要求として扱う。shutdown 猶予内に後処理が終わらず強制終了した場合は、排他を残す。
- 再試行時は ID から最新状態を取得する。worker が自然終了した直後に `Done` へ移り、active candidate 一覧から消えた場合も削除対象を見つける。

排他記録は workspace 外の `<workspace.root>/.symphony-leases/<safe_identifier>.lock/owner.json` に置く。
OS の `mkdir` で取得し、worker の開始前と削除前に同じ排他を使う。実行ごとに隣接する `.generation` を更新する。
古い削除要求が待機中に別の実行が始まっていれば、世代の不一致で削除を拒否する。重複削除も同じ排他で拒否する。
Orchestrator 単体が再起動しても、既存 Task と filesystem の排他が再利用を防ぐ。
VM の強制終了、削除失敗、子孫の終了未確認では `.lock` を残す。PID が見つからないという理由だけでは自動解除しない。

`token_usage.jsonl` だけの追記失敗は、issue、thread、path、原因を付けた警告とし、使用量通知の集計を続ける。
失敗を回避するために workspace を再作成しない。Implementation の再開時に累積使用量を差し引く checkpoint は
`session_state.json` の重要な状態なので、破損・書込み失敗は引き続き実行失敗とする。
スレッド登録、工程情報、Rework marker などのエラーを一律に無視する処理は加えない。

## 状態とログ

端末表示の `Cleanup: <identifier> <status>` と snapshot / `/api/v1/state` の `cleanups` で状態を確認する。
`pending` は終了待ちまたは削除中、`finishing` は最後の worker 通知待ち、`failed` は失敗を表す。
失敗には `error` を含める。削除中は定期的な待機ログを、開始・完了・失敗時には issue と所要時間を記録する。
`Workspace removal started/finished` は実際の削除区間、`Workspace cleanup started/completed/failed` は終了待ちを含む全区間を表す。

```bash
rg 'Workspace cleanup|Workspace removal|Workspace worker stopped|Thread usage log write failed|Workspace lease|Workspace processes not stopped' /mnt/c/temp/PlantStella/log/symphony.log.*
```

## 制約

- ローカルプロセスの安全な終了確認には Linux `/proc`、pidfd 対応 kernel、Python 3.9 以降が必要。対象環境の Python は 3.12.3。Python は標準ライブラリのみを使い、helper のソースは escript に埋め込む。
- 子孫の停止には pidfd を使い、PID 再利用による別プロセスへの signal を防ぐ。ローカルの `codex_app_server_pid` は Port が直接所有する guard の PID を示し、その下に shell と Codex がある。
- SSH 側の全子孫の終了確認は今回実装していない。SSH の自動削除は `remote_process_termination_unverified` として拒否する。対象の PlantStella はローカル worker 構成である。
- `failed` と残留 `.lock` は自動的に解除しない。途中まで削除された workspace や、まだ利用されている workspace を再試行で上書きしないためである。
- 終了処理中の hook が長時間待つ場合、その issue は `pending` に留まる。他 issue の管理は継続する。
- tracker の同期 HTTP 問合せや外部 filesystem 自体の障害まで、常に一定時間内の snapshot 応答を保証する変更ではない。

## 適用手順（運用者が実施）

この調査では稼働版の更新・停止・再起動、Linear の変更、既存 workspace の手動削除は実施していない。
以下は PR のレビュー・merge 後に行う。稼働 checkout はそのまま保管し、新しい checkout のバイナリを使う。

1. `plantstella` 向け PR を merge した commit SHA を確認し、専用 checkout でその commit をビルドする。

   ```bash
   git clone --branch plantstella https://github.com/taku34510/symphony.git /home/taku3/symphony-cleanup-release
   cd /home/taku3/symphony-cleanup-release
   git switch --detach <レビュー済みのmerge_commit_SHA>
   cd elixir
   export PATH="/home/taku3/.local/share/mise/installs/elixir/1.19.5-otp-28/bin:/home/taku3/.local/share/mise/installs/erlang/28.4.1/bin:$PATH"
   export MIX_HOME=/home/taku3/.local/share/mise/installs/elixir/1.19.5-otp-28/.mix
   elixir --version
   python3 --version
   mix setup
   mix build
   sha256sum bin/symphony
   ```

2. 起動用 shell で元の設定を確認する。`scripts/symphony.sh` の既定バイナリは `/home/taku3/symphony/elixir/bin/symphony` なので、
   今回の稼働版とは異なる。バイナリを明示する。stdout の既定出力先は `/home/taku3/symphony/elixir/log/symphony.stdout`。
   `SYMPHONY_STDOUT_PATH` / `SYMPHONY_PID_PATH` を運用 shell で上書きしている場合は、現在の値を維持する。

   ```bash
   cd /mnt/c/temp/PlantStella
   printenv SYMPHONY_RUNTIME_BINARY SYMPHONY_STDOUT_PATH SYMPHONY_PID_PATH SYMPHONY_WORKSPACE_ROOT
   rg -n 'read_timeout_ms: 60000' WORKFLOW.md
   ./scripts/symphony.sh status --runtime-binary /home/taku3/symphony-plantstella/elixir/bin/symphony --plain
   ```

3. 実行中タスクを確認し、後処理と子孫の停止を確認できる保守時間に切り替える。
   旧版は新しい排他を持たないため、旧版の worker / Codex / hook が残ったまま新版を併走させない。
   `restart --runtime-binary <新版>` は新版のプロセスだけを探索するため、旧版の停止には使わない。

   ```bash
   ./scripts/symphony.sh stop --runtime-binary /home/taku3/symphony-plantstella/elixir/bin/symphony
   # 旧版の worker / Codex / hook が終了したことを確認してから次を実行する。
   export SYMPHONY_RUNTIME_BINARY=/home/taku3/symphony-cleanup-release/elixir/bin/symphony
   export SYMPHONY_WORKSPACE_ROOT=/mnt/c/temp/symphony-workspaces
   ./scripts/symphony.sh start
   ```

4. 同じ起動元で status と詳細ログを確認する。`read_timeout_ms: 60000` を保持し、既存 workspace のまま
   Implementation の再開、AI Review の新規スレッド、Rework → Design の初期化を確認する。
   次の承認済みタスクが `Done` になる際、`Workspace worker stopped` → `Workspace cleanup completed` の順序、
   `elapsed_ms`、削除中も状態の更新と他 issue の投入が継続することを確認する。
   HTTP port は現在の起動引数にはないため、今回の適用で勝手に追加しない。

## 切り戻しと残留排他

新版バイナリを明示して停止し、新版 worker と削除 Task の終了を確認する。
`.symphony-leases/*.lock` が残っている間は旧版を起動しない。旧版は排他記録を理解しない。

```bash
cd /mnt/c/temp/PlantStella
./scripts/symphony.sh stop --runtime-binary /home/taku3/symphony-cleanup-release/elixir/bin/symphony
# 全 worker・子孫・削除 Task が停止し、残留排他を調査済みであることを確認する。
export SYMPHONY_RUNTIME_BINARY=/home/taku3/symphony-plantstella/elixir/bin/symphony
./scripts/symphony.sh start
```

旧版のソース・escript を上書きしていないので、そのまま切り戻せる。ただし旧版では今回の障害が再発し得る。
終了確認ファイルは `/tmp/symphony-process-*/stopped`、排他の所有情報は `owner.json` にある。
残留排他があれば、ログと所有情報、対象 workspace を利用するプロセスを照合し、稼働インスタンスを停止した保守作業として扱う。
PID の不在だけで安全と判断せず、子孫と部分削除の有無、必要な成果物の退避を確認する。
解除する場合も、確認した単一 issue の `.lock` だけを別の退避先へ移す。workspace 自体や `.generation` は手動で削除しない。
調査中のこの作業では、その解除は行っていない。

## 回帰試験

`workspace_cleanup_test.exs` は message barrier と hook の解除ファイルで順序を制御し、Done 後の最後の通知、
worker の終了処理、遅い削除中の snapshot と別 issue の投入、重複削除、世代変更、Orchestrator 再起動、
削除失敗・Task 異常終了、存在しない workspace、通常の supervisor shutdown、子孫・切り離された子孫の回収を確認する。
`thread_lifecycle_test.exs` は使用量追記失敗と重要状態保存失敗の境界を追加し、既存の Implementation 再開、
AI Review 新規スレッド、Rework 初期化も確認する。

試験用の起動済み Orchestrator が長い試験の途中で別テストの不正設定を読む干渉を避けるため、
共通 setup で既定 Orchestrator の自動 tick を無効にする。各 Orchestrator 試験は専用プロセスと明示的な tick を使う。
実 Linear / Codex の E2E は、状態変更を避けるため実行対象に含めない。

## 検証結果

- 旧版 `8057839`：244件、失敗0件、2件スキップ。既存の計測対象カバレッジ100%。
- 旧版の独立した再現試験：2件成功。15秒のsnapshot timeoutと使用量の `File.Error` を確認。
- 修正版の `make all`：成功。264件、失敗0件、2件スキップ。計測対象カバレッジ100%。除外対象や基準の引下げは行っていない。
- `mix format --check-formatted`、`mix specs.check`、Credo：成功。Dialyzer：エラー0件。
- escript のビルド：成功。埋め込みモジュールをビルド済みescriptから読み出し、コマンド実行と子孫の回収を確認した。
- 検証用バイナリ：`/tmp/symphony-cleanup-fix-20260912/elixir/bin/symphony`。
  SHA-256：`0170c1d22c7477c300b49ccd4121fad9b3dd534714879b56fd374f2585a7aaf4`。
- 詳細な検証出力：`/tmp/symphony-cleanup-make-all.log`。稼働用バイナリのSHA-256は調査前後で一致した。

`mix setup` は既存の依存パッケージについてセキュリティ勧告を報告した。今回の変更で `mix.lock` は更新しておらず、
品質ゲートの成功は、それらの勧告を解消したという意味ではない。今回の実機障害が依存パッケージに起因する証拠は得られていない。
