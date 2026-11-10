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
- Sparkle と SuperSplat はどちらもバージョン固定（`Package.swift`、`scripts/bundle.sh`）。上げるときは単独のコミットにする

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

リリーススクリプト（`release.sh` `package_dmg.sh` `update_appcast.sh`）は構文確認だけで、まだ一度も実行していない。最初のリリースで `gh-pages` ブランチができる。GitHub Pages が有効になって `appcast.xml` が配信されるかは、そのとき確かめる。

## 残タスク

- 保存は SuperSplat のダウンロード経路（`<a download>` のクリック → `WKDownloadDelegate` → 保存パネル）で動く。ただし SuperSplat は結果を全部メモリに溜めてから渡すので、巨大シーンの PLY 書き出しはメモリに収まらない可能性がある。確認したのは画像の書き出し（`render.image`）だけで、splat の書き出しとプロジェクト保存は未確認。ディスクへ逐次書き出すには、ページ側に `showSaveFilePicker` 相当を用意してネイティブへ流す必要がある
- ウィンドウへのドラッグ&ドロップで開けるかは未確認
- `--snapshot` が stochastic のあと実画面と食い違う件
- リリースビルドのバイナリにツールチェーンの絶対パスの rpath が入っている（`otool -l` で見える）。動作には影響なし、公証で問題になるかは未確認
- ライセンス未設定

やらないと決めたこと：

- Z-up データの自動回転。Z-up のデータは横倒しで出る（X 軸 −90° で地面が水平になることは確認済み）が、アプリが勝手に回すとデータ本来の向きと区別がつかなくなる。向きは SuperSplat の Transform でユーザーが決める
