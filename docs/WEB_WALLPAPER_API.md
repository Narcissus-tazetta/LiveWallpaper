# Web壁紙フォルダ(手書きHTML)

「壁紙」タブの「Web壁紙を追加」→「フォルダから追加…」で、HTMLのフォルダを壁紙として登録できる。フォルダの中身はライブラリにコピーされ、元のフォルダを動かしても壁紙は動く。HTMLを直したら、フォルダを選び直して追加する。

ページは `http://127.0.0.1:<port>/<token>/…` で配信される。ポートとトークンは再起動しても変わらない。

## フォルダの構成

- `index.html` があれば登録できる。
- 設定項目、プレビュー、音・曲情報の対応を宣言したいときだけ、同じフォルダに `web-wallpaper.json` を置く。
- フォルダ内のシンボリックリンクがあると登録できない。フォルダの外のファイルは読めない。

`web-wallpaper.json` が無いとき、音のスペクトルと再生中の曲の切り替えは、`index.html` に `subscribe('spectrum')` / `subscribe('media')` が書かれているときだけ設定画面に出る。

## web-wallpaper.json

| キー | 型 | 内容 |
| --- | --- | --- |
| `entryPoint` | 文字列(必須) | 開くHTML。フォルダ内の相対パス |
| `warnings` | 文字列の配列 | 壁紙カードに出す注意書き |
| `preview` | 文字列 | サムネイル画像。フォルダ内の相対パス |
| `properties` | 配列 | 設定項目(下記)。`id` は重複不可 |
| `supportsSpectrum` | 真偽値 | 設定画面に「システム音に反応」を出す |
| `supportsMedia` | 真偽値 | 設定画面に「再生中の曲」を出す |
| `displayAdjustment` | 辞書 | 色補正と左右反転を、どの項目で操作するか(下記) |

### properties

各項目は `id`, `kind`, `label`, `value` を持つ。`label` は言語コード(`en`, `ja`, `zh-Hans` など。`default` も可)から文字列への辞書。

| `kind` | `value` | 追加キー |
| --- | --- | --- |
| `bool` | 真偽値 | |
| `slider` | 数値 | `minimum`, `maximum`, `step` |
| `combo` | 選択肢の `value` | `options`: `{label, value}` の配列 |
| `color` | `"r g b"`(各 0〜1 を空白区切り) | |
| `textinput` | 文字列 | |
| `file` | 空文字 | 利用者が選んだファイルはコピーされ、ページには配信URLが渡る |
| `directory` | 空文字 | `fileType`: `image` / `video` / 省略で全て |
| `group` | | 見出しだけ |
| `text` | | 説明文だけ |

`condition` に `"enabled.value && mode.value == 'a'"` のような式を書くと、条件を満たすときだけ項目を表示する。使えるのは項目参照(`id` または `id.value`)、比較(`== != === !== < > <= >=`)、`&& || !`、括弧、数値と文字列。

### displayAdjustment

キー `flipHorizontally`, `colorEnabled`, `brightness`, `contrast`, `saturation`, `hue` に項目の `id` を割り当てる。スライダーは 0〜100 で、50 が変化なし。

## ページから使うAPI

`window.liveWallpaper` は読み取り専用。

| 項目 | 内容 |
| --- | --- |
| `liveWallpaper.properties` | 現在の設定値(`id` → 値)。`file` 項目は配信URL、`directory` 項目は `Z:/…` 形式のパス |
| `liveWallpaper.state` | `{paused, audioEnabled, volume, fps, language}` |
| `liveWallpaper.media` | 最後に届いた再生中の曲。届く前は `null` |
| `liveWallpaper.directories` | `directory` 項目ごとのファイル名一覧 |
| `liveWallpaper.subscribe(feature)` | `'spectrum'` または `'media'` を購読する。それ以外は `RangeError` |

イベントは `window` に届く。値は `event.detail`。

| イベント | `detail` |
| --- | --- |
| `livewallpaper:properties` | 設定値(`liveWallpaper.properties` と同じ形)。設定が変わるたび |
| `livewallpaper:state` | `liveWallpaper.state` と同じ形 |
| `livewallpaper:spectrum` | 128個の数値の配列。`subscribe('spectrum')` 後、利用者が「システム音に反応」を許可したときだけ。許可がなければ全て0 |
| `livewallpaper:media` | `{value, enabled}`。`value` は `title, artist, album, albumArtist, duration, position, state, artwork, source, trackID, primaryColor, textColor`。`subscribe('media')` 後、利用者が許可したときだけ。許可がなければ `enabled` が偽で、`value` は停止状態 |
| `livewallpaper:directory` | `{property, added, removed}` |

`window.__liveWallpaperSubscribe(feature)` は `liveWallpaper.subscribe` の旧名で、同じ動作をする。

## 一時停止中の動作

ホストは画面が隠れている間、ページを一時停止する。

- `requestAnimationFrame` は止まり、再開すると再び呼ばれる。
- `setTimeout` / `setInterval` は止まる。止まっている間に期限が来たものは、再開時に1回ずつ実行される。
- 再生中の `<audio>` / `<video>` は止まり、再開で続きから再生される。
- 音量は `liveWallpaper.state.volume` が全ての `AudioContext` と `<audio>` / `<video>` に掛かる。壁紙の音がオフのとき、ページの音は鳴らない。
