# AGENTS.md — SplatShell プロジェクト知識

## これは何

[SuperSplat](https://github.com/playcanvas/supersplat)（PlayCanvas 製の 3D Gaussian Splatting エディタ、MIT）のビルド成果物を `WKWebView` で包んだ macOS アプリ。数千万 splat の PLY を、サーバなしでローカルから開くのが目的。レンダラも編集機能も SuperSplat のもので、このリポジトリが持つのは殻（ウィンドウ、メニュー、ファイルの受け渡し、アップデータ）だけ。

SuperSplat を選んだ理由：巨大シーンを滑らかに出す鍵は LOD と GPU ソートで、2026-11 時点でそれを持つのは Web 系（PlayCanvas、Spark）だけだった。ネイティブの MetalSplatter に LOD はなく、RealityKit 27 の splat 描画は splat 数に内部上限がある。Chrome と `WKWebView` の速度は同水準だったので、Electron にはしていない。

## 構成

- `Sources/SplatShell/main.swift`: アプリ本体。ページに注入する JS（`shellScript`、`benchScript`）もここ
- `Sources/SplatShell/WebAppSchemeHandler.swift`: 同梱した SuperSplat を `splat://app/` で配信する
- `scripts/bundle.sh`: `build/SplatShell.app` を組み立てる。SuperSplat は固定コミットを `.build/supersplat` に取得してビルドする
- `scripts/generate_icon.swift`: アイコンを描いて `Resources/AppIcon.icns` を書く
- `scripts/release.sh` `package_dmg.sh` `update_appcast.sh` `detach_dmg_mounts.sh`: リリース。`/release` コマンドから使う
- `Sources/SplatShell/KeyboardLayout.swift`: 物理キー位置 → 今のキーボード配列での刻印の対応を作り、`window.keyboardLayoutLabels` としてページに渡す。配列が切り替わると送り直して `keyboardlayoutchange` イベントを出す
- `patches/*.patch`: SuperSplat に当てるパッチ。`bundle.sh` が固定コミットを取得したあと名前順に当てる。固定コミットかパッチが変わると `.build/supersplat` を取り直す（`.splatshell-stamp` で判定）。パッチを作り直すときは `.build/supersplat` で編集して `git diff > patches/<name>.patch`。`SUPERSPLAT_DIR` を指定したときは当てない
- Sparkle と SuperSplat はどちらもバージョン固定（`Package.swift`、`scripts/bundle.sh`）。上げるときは単独のコミットにする
- SuperSplat の新リリースは `.github/workflows/follow-supersplat.yml` が毎日 00:17 UTC に確かめる。今の固定より新しいタグがあれば `scripts/follow_supersplat.sh` が固定を動かし、macOS ランナーで `bundle.sh` を丸ごと通して、結果つきの PR（ブランチ `supersplat/<tag>`）を作る。ビルドが失敗しても PR は作り、タイトルに `(build failed)` が付く。ランナーは描画できないので、マージ前に手元で大きいシーンを開いて飛ぶ。公開はマージ後に Mac で `/release`。鍵は GitHub に置いていない（自動公開にしないと決めた）
- 追うのはリリースタグだけ。固定がリリースより先のコミット（main から拾った修正）なら戻さない。PR を作るにはリポジトリ設定 Actions > General の「Allow GitHub Actions to create and approve pull requests」が要る
- パッチが当たらないときは `.build/supersplat` で新しいタグの上に手で当て直して `git diff > patches/<name>.patch`。`git apply` は前後の行が一致しないと失敗する（v3.7.0 に今のパッチを当てると `src/shortcuts.ts` で失敗する、と確認済み）
- 手元での空打ち：`DRY_RUN=1 ./scripts/follow_supersplat.sh`（新しいリリースがなければ何もしない）。`TAG=<tag> FORCE=1 DRY_RUN=1` で任意のタグを試せる。空打ちは固定を書き換えたままにするので、終わったら戻す

## コマンド

```bash
./scripts/bundle.sh                       # build/SplatShell.app（ad-hoc 署名）
open -a build/SplatShell.app scene.ply    # Finder と同じ経路で開く
swift scripts/generate_icon.swift         # アイコンを作り直す
```

確認用の起動オプション（バンドル内のバイナリを直接実行する）：

```bash
B=build/SplatShell.app/Contents/MacOS/SplatShell
$B --pixels 1924x1418 --bench scene.ply                 # 計測して RESULT <json> を出して終了
$B --stochastic disabled --snapshot out.png scene.ply   # 開いて落ち着いたら画面を PNG に書いて終了
$B --snapshot out.png --eval 'return window.scene.events.invoke("view.stochastic")' scene.ply
```

`--eval` の中身はページ内の async 関数の本体として実行される。`--downloads <dir>` を付けると、ページが保存するファイルを保存パネルなしでそのフォルダに書き、`SAVED <path>` を出す。`window.scene` と `window.scene.events` が SuperSplat の入口。

SuperSplat の保存設定を初期状態に戻す：

```bash
$B --snapshot /tmp/x.png --eval 'localStorage.removeItem("supersplat:preferences"); return "cleared"' scene.ply
```

## ハマりどころ（実体験）

- **splat ファイルを独自スキームや HTTP で流さない**。`WKURLSchemeHandler` には受け手の読む速さに合わせる仕組みがなく、11 GB を流すと WebKit 側に溜まる。SuperSplat は URL から読むとき Range 対応を調べ、非対応ならファイル全体をメモリに落とす。なのでページに本物の `File` を渡している：ページが `<input type=file>` を `click()` し、アプリが `runOpenPanelWith` の応答としてパスを返す（`filesForNextChooser`）。`File` は必要な分だけディスクから読まれる
- **`evaluateJavaScript` から呼んだ `input.click()` はファイル選択を開ける**。ユーザー操作として扱われる。上の受け渡しはこれに依存している
- **`--snapshot`（`takeSnapshot`）は stochastic 描画のあと、実画面と違う画を出す**。実画面は止まると並べ替え描画のきれいな画に戻るが、スナップショットにはざらついた画が写る。レンダラの状態（`projectedSplatRenderer.stochastic`、ブレンド設定）は正しい値を返すので、状態を読んでも気づけない。これを WebKit の不具合と誤診して既定を `disabled` に変えかけた。画の確認に使うときは `--stochastic disabled` を付ける。実画面の確認は人の目でやる
- **青い点が一面に出たら Edit View**。SuperSplat の機能で、Tab キーで切り替わり、`view.setCenters` などの表示オーバーレイを操作しても自動でオンになる。`localStorage` の `supersplat:preferences` に保存されて次回起動に残る。検証中に意図せずオンになり、別の不具合に見えた。上の初期化コマンドで戻す
- **`view.setStochastic` などのイベントを `--eval` で発火すると保存設定が書き換わる**。確認のつもりの操作が次回起動に残る
- **SuperSplat の既定 `auto` は巨大シーンでカクつく**。並べ替えありの 1 フレームが 60 ms を超えたときだけ移動中の stochastic 描画に切り替わる。40〜50 ms の視点では切り替わらず 20 fps 前後になる。なので保存された設定がないとき、起動時に `movement` を設定している。SuperSplat はこの値を Preferences と一緒に保存するので、保存値があるときは触らない（ユーザーが Preferences で選んだ値が残る）。`--stochastic` を付けたときだけ上書きする
- **`disabled` にすると SuperSplat が GPU タイマーを止める**。`scene.frameTimings.gpu` が 0 になる。`--bench` の並べ替え計測は `auto` のまま `scene.autoEngageMs = 1e9` にしてタイマーを生かしている
- **読み込み直後にシーンが見えないことがある**。原点から遠いデータではカメラの視界に入らない。開いたあと `camera.focus` を発火している。外れ値の splat があると `camera.focus` は引きすぎる
- **Fly（ドローン）移動キーは物理キー位置（`KeyW` など）で照合される**。macOS の Dvorak 配列なら QWERTY の WASD の位置でそのまま動き、表示だけ配列の刻印に合わせている（`KeyboardLayout.swift` → `window.keyboardLayoutLabels`）。ハードウェアで Dvorak のキーボードは刻印どおりのキーコードを送るので、ソフトからは QWERTY と区別できない。なので View > Dvorak Keyboard for Fly Keys（`UserDefaults` の `flyKeyLayout`）で割り当てを `,` `A` `O` `E`（上下 `'` `.`）に切り替える。この組は `,` `.`（タイムラインのフレーム送り）と `O`（Flood 選択）とぶつかるので、Fly の割り当ては Fly カメラのときだけ有効にして、先に照合させている。Orbit では元の機能が効く。押下だけを判定し、離したときは常に照合する（押しっぱなし状態が残らないように）
- **メニューに Undo / Redo / Select All を足さない**。キー入力がメニューに取られてページに届かなくなる。SuperSplat はそれらのキーを自前の編集履歴と選択に使う
- **Sparkle は `.app` の外では動かない**。`.build/release/SplatShell` を直接実行すると `Bundle.main.bundleIdentifier` が nil なので、アップデータを作らない。`--bench` `--snapshot` `--eval` `--downloads` のときも作らない（更新ダイアログが自動実行の邪魔になる）
- **独自スキーム `splat://app` は secure context 扱いで、WebGPU が使える**（macOS 26.6 で確認）。HTTP サーバに戻す必要はない

リリース関連（Canopy で実体験、スクリプトごと持ってきた）：

- **Time Machine notarize hang**: Time Machine のバックアップ中はホーム配下に I/O ロックがかかり、`notarytool submit` がそこで固まる。zip と DMG は `/tmp` で作って提出する
- **notarytool DMG-mount hang**: `notarytool` と `generate_appcast` は DMG をマウントしたまま残すことがある。残ったマウントは次回の `notarytool submit` を固まらせる。`scripts/detach_dmg_mounts.sh` が前後で外す。公証の実行中には走らせない

## 検証で使える基準値

M4 Max / 64 GB、macOS 26.6、描画 1924 × 1385、SH 3 次の無圧縮 PLY、`--bench` の値。

| シーン | 読み込み | 静止（並べ替え） | 移動中（`movement`） |
|---|---|---|---|
| 251 万 splat（0.6 GB） | 1.7 秒 | 60 fps | 60 fps |
| 989 万 splat（2.3 GB） | 約 18 秒 | 60 fps | 60 fps |
| 4,799 万 splat（11 GB） | 約 88 秒 | 17〜20 fps、GPU 47〜59 ms | 60 fps、GPU 8〜9 ms |

4,799 万 splat のメモリは WebContent 約 12 GB + GPU プロセス約 5 GB。Chrome 156 で同じ SuperSplat を動かした値も同水準（読み込み 90 秒、移動中 60 fps）。

## リリース

`/release` コマンド（`.claude/commands/release.md`）に手順がある。署名は Developer ID、公証は `notarytool-profile`、配布は DMG、更新フィードは `gh-pages` ブランチの `appcast.xml`。Sparkle の EdDSA 鍵は Canopy と共用で、秘密鍵はログインキーチェーンにある。

0.1.0 でこの流れを最後まで通した。`gh-pages` への最初の push で GitHub Pages が自動で有効になり、約 30 秒で `appcast.xml` が配信された。個人の Developer ID（`VCFY2GFR89`）は MBP から書き出してこの Mac（Mac Studio）にも入れてあるので、どちらでもリリースできる。0.1.0 から 0.1.1 への更新は Check for Updates… で届き、インストール・再起動まで通った。`update_appcast.sh` は前の版からの差分更新（数十 KB）も作ってリリースに添付する。

## 残タスク

- 保存は SuperSplat のダウンロード経路（`<a download>` のクリック → `WKDownloadDelegate` → 保存パネル）で動く。ただし SuperSplat は結果を全部メモリに溜めてから渡すので、巨大シーンの PLY 書き出しはメモリに収まらない可能性がある。確認したのは画像の書き出し（`render.image`）だけで、splat の書き出しとプロジェクト保存は未確認。ディスクへ逐次書き出すには、ページ側に `showSaveFilePicker` 相当を用意してネイティブへ流す必要がある
- `--snapshot` が stochastic のあと実画面と食い違う件

やらないと決めたこと：

- Z-up データの自動回転。Z-up のデータは横倒しで出る（X 軸 −90° で地面が水平になることは確認済み）が、アプリが勝手に回すとデータ本来の向きと区別がつかなくなる。向きは SuperSplat の Transform でユーザーが決める
