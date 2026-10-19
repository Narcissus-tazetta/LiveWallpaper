# 壁紙スクリプトAPI v4

画像壁紙の「シーン編集」→「スクリプト(JavaScript)」でサンプルを追加し、対象レイヤーと入力を選択する。「実行して適用」でコードと設定を検証して保存する。入力中の下書きは実行中のコードと別に保持される。

追加メニューの先頭は「空白のスクリプト」。`update(ctx)`と空の出力だけが入り、入力依存はすべてオフ、パラメーターは空。対象は全レイヤーで、後から追加したレイヤーも含む。空白を含めて28種類のテンプレートがある。作成・適用するスクリプトはAPI v4。保存済みのAPI v1〜v3も評価できる。

スクリプト、パラメーター、API説明、ログの見出しは行全体で開閉でき、右側の余白もクリック対象になる。

コード欄はキーワード、数値、文字列、コメント、関数、プロパティ、正規表現を色分けする。ライト／ダーク表示に対応し、入力・貼り付け後も更新する。文字の取り消しと下書きの扱いは標準の文字編集に従う。

## 1本で全レイヤーを管理する

追加メニューの2番目にある「1本で全体を管理」を選ぶ。「全レイヤーを管理（追加したレイヤーも含む）」がオンになり、`ctx.targets`へ現在の全レイヤーが渡る。レイヤー追加のたびに対象を選び直す必要はない。選択対象だけを使う場合は、この設定をオフにしてチェックボックスで選ぶ。

1本の`update(ctx)`から、各レイヤーの位置・色・表示・合成モード・立体感・エフェクト・粒子をまとめて返せる。`layer.kind`や`layer.particles`で分岐し、`layer.id`で特定の対象を識別する。既存のエフェクトは`layer.effects`からIDを取得する。全体管理サンプルは画像の運動、時間帯の色、エフェクトの強さ、粒子の色とカーソル反応を組み合わせている。

## 基本

```js
function update(ctx) {
  return ctx.targets.map((layer, i) => ({
    id: layer.id,
    values: {
      offsetY: wave(ctx.phase, ctx.params.cycles, i * 0.1) * ctx.params.amount,
      rotation: wave(ctx.phase) * 5,
    },
  }));
}
```

同期関数`update(ctx)`が、対象ごとの調整を配列で返す。通常スクリプト(`modules`が未指定またはnull)では、グローバル変数は評価ごとに初期化される。任意時刻への移動と動画書き出しで同じ結果を得るには、状態を蓄積せず、時刻などの入力から結果を計算する。モジュール形式では評価間で状態を保持する(後述)。

## 入力

| 項目 | 値 |
| --- | --- |
| `ctx.targets` | 全レイヤー、または選択した現在存在するレイヤーの配列。壁紙の重ね順で並ぶ |
| `ctx.params` | パラメーター欄で指定した数値の辞書 |
| `ctx.canvas` | `width`, `height`, `aspectRatio` |
| `ctx.loopSeconds` | ループの秒数 |
| `ctx.time` | ループ内の秒数。「ループ時刻」が必要 |
| `ctx.elapsedTime` | 入力時刻の秒数。ループ内に折り返さない。「ループ時刻」が必要 |
| `ctx.phase` | ループ内の割合、0以上1未満。「ループ時刻」が必要 |
| `ctx.timeOfDay` | `morning`, `day`, `evening`, `night`。「時間帯」が必要 |
| `ctx.wallClock` | `{epochMilliseconds, timeZoneOffsetMinutes}`。UNIX時刻のミリ秒とUTCからの時差(分)。「時間帯」が必要 |
| `ctx.cursor` | `{x, y}`。画面左・上が-1、右・下が1。平滑化済み。「カーソル」が必要 |
| `ctx.cursorActive` | カーソルへ反応できるか。「カーソル」が必要 |
| `ctx.pointer` | キャンバス座標の`{x,y}`。左上が0、右下が1。反応できない場合はnull。平滑化しない。「カーソル」が必要 |
| `ctx.pointerPresses` | 前回のスクリプト評価以降の主ボタンの押下・解放。古い順の`{isDown,x,y}`配列。座標は`pointer`と同じ。「カーソル」が必要 |
| `ctx.media` | Music / Spotify の曲情報。「曲情報」が必要。詳細は後述 |

未選択の入力にアクセスするとエラーになる。動画書き出しではカーソルは中立の`{x:0,y:0}`、`cursorActive`はfalse、`pointer`はnull、`pointerPresses`は空配列、`media`は`{isAvailable:false}`になる。時間帯は書き出し開始時に固定され、アプリが動いている間は時間帯境界で動画を更新する。`wallClock`はリアルタイム描画では現在時刻、書き出しでは最初のフレームを基準に入力時刻の差分だけ進む。画面上のポインタ操作は、評価までに蓄積した直近32件を保持する。

各対象は`id`, `name`, `kind`, `isLocked`, `transform`, `opacity`, `values`, `appearance`, `effects`, `particles`, `text`, `rigs`を持つ。配置や透明度にはGUIのキーフレームと連動を反映する。画像ファイルやマスクのパスは含まない。`effects`のIDを使って、その対象の既存エフェクトを操作できる。粒子がない対象の`particles`、テキストがない対象の`text`はnull。`rigs`は対象の配置・描画パスで参照しているスケルトンの配列。

対象のIDは`ctx.targets`から取得する。レイヤーを複製すると同じスクリプトの対象へ追加される。表示名は識別子ではなく、エフェクトのIDは複製元と別になる。

## 配置と色

```js
function update(ctx) {
  return ctx.targets.map(layer => ({
    id: layer.id,
    values: {
      offsetX: ctx.cursor.x * 0.05,
      opacity: ctx.cursorActive ? 1 : 0.8,
      warmth: ctx.timeOfDay === "evening" ? 0.4 : 0,
    },
  }));
}
```

この例では「カーソル」と「時間帯」を有効にする。

| `values`の項目 | 許容範囲 | 合成方法 |
| --- | --- | --- |
| `offsetX`, `offsetY` | -4〜4。キャンバス幅・高さに対する割合 | 加算 |
| `rotation` | -3600〜3600。時計回りの度数 | 加算 |
| `scale`, `scaleY` | 通常形式は0.05〜16、モジュール形式は-64〜64 | 乗算。`scale`は横倍率で、`scaleY`未指定時は縦にも同じ倍率 |
| `opacity` | 0〜1 | 乗算 |
| `brightness` | -1〜1。-1で黒、1で明るさ2倍 | 加算 |
| `saturation` | 0〜4。1で変更なし | 乗算 |
| `warmth` | -1〜1。負で寒色、正で暖色 | 加算 |

未指定の項目は変更しない。配置／キーフレーム → GUIの連動 → スクリプト → 視差・奥行きの順に評価する。スクリプトの入力には、前のスクリプトの出力を含めない。

## エフェクトと粒子

```js
function update(ctx) {
  return ctx.targets.map(layer => ({
    id: layer.id,
    effects: layer.effects.map(effect => ({
      id: effect.id,
      isEnabled: ctx.phase < 0.5,
      strength: (wave(ctx.phase) + 1) * 0.25,
    })),
  }));
}
```

エフェクトの調整は`id`と、`kind`, `fixedEdge`, `isEnabled`, `strength`, `scale`, `direction`, `cycles`, `centerX`, `centerY`, `reversed`, `values`の任意の組み合わせ。強さ・大きさ・中心座標は0〜1、周期は整数1〜12、方向は-3600〜3600度。`kind`は既存GUIのエフェクト種類、`fixedEdge`は`none/top/bottom/left/right`。種類によって使用される値が異なり、新しいエフェクトや画像マスクをこの出力で追加することはできない。`values`は種類固有の数値パラメーター辞書で、最大64項目、各値は有限数の-1e9〜1e9。未指定のキーは現在値を維持する。

```js
function update(ctx) {
  return ctx.targets.filter(layer => layer.particles).map(layer => ({
    id: layer.id,
    particles: {
      count: 100,
      opacity: 0.6 + wave(ctx.phase) * 0.3,
      color: hsv(ctx.phase, 0.7, 1),
    },
  }));
}
```

粒子の調整は`preset`, `cursorMode`, `seed`, `count`, `size`, `cycles`, `direction`, `sway`, `opacity`, `color`。`preset`は`snow/rain/petals/fireflies/dust/embers/bubbles/stars`、`cursorMode`は`none/repel/attract`。シードは整数0〜2147483647、数は整数5〜2000、周期は整数1〜12、方向は-3600〜3600度、それ以外の数値は0〜1。色は`{red,green,blue,alpha}`の全項目が必要。プリセットの切り替えは他の数値を維持する。必要に応じて`appearance.blendMode`も設定する。

複数スクリプトは一覧順に評価する。位置などは上の合成規則を使い、同じエフェクト／粒子の項目は後の指定で上書きする。1回の出力内で同じ対象やエフェクトのIDを重複させることはできない。

## 表示・合成・立体感・カーソルマスク

```js
function update(ctx) {
  return ctx.targets.map(layer => ({
    id: layer.id,
    appearance: {
      isVisible: ctx.timeOfDay === "night",
      blendMode: "screen",
      cursorMask: { mode: "show", radius: 0.2, softness: 0.5 }
    }
  }));
}
```

この例では「時間帯」と「カーソル」をオンにする。

| `appearance`の項目 | 仕様 |
| --- | --- |
| `isVisible` | boolean。表示のオン／オフ |
| `tint` | `{red,green,blue,alpha}`。全項目が必要で、各値0〜1 |
| `blendMode` | `normal/multiply/screen/overlay/add` |
| `parallaxDepth` | 0〜1。レイヤー全体の視差 |
| `depthStrength` | 0〜1。既存の深度マップの強さ |
| `depthFollowsCursor` | boolean。深度による視差をカーソルへ連動 |
| `depthAutoMotion` | 0〜1。深度の自動運動 |
| `depthAutoCycles` | 整数1〜12 |
| `cursorMask` | `mode:hide/show`、`radius:0.01〜1`、`softness:0〜1`。未指定項目は現在値を維持。ない場合は既定値から作る |
| `clearCursorMask` | trueでカーソルマスクを除く。同時に`cursorMask`は指定できない |

入力の`layer.appearance`には現在の設定と`hasDepthMap`が入る。ファイルのパスは入らず、深度画像の新規作成や読み込みはGUIで行う。視差・カーソルマスク・粒子のカーソル反応を使う場合は「カーソル」、自動運動を使う場合は「ループ時刻」を宣言する。

## 曲情報

「曲情報」を有効にすると`ctx.media`を読める。Music / Spotify の情報取得にはmacOSのオートメーション許可が必要。取得できない場合は`{isAvailable:false}`だけが渡るので、他の項目を読む前に確認する。

Sceneの画像レイヤーに`usesMediaArtwork: true`を指定すると、再生中のアルバム画像を表示する。元画像の透明部分を保ち、曲が変わると画像も更新する。画像がない場合や曲情報を取得できない場合は元画像を表示する。画像本体は描画に渡され、スクリプトの入力には含まれない。

| `media`の項目 | 仕様 |
| --- | --- |
| `isAvailable` | 曲情報を取得できるか |
| `playback` | `stopped/playing/paused` |
| `title`, `artist`, `album` | 曲名・アーティスト・アルバム名の文字列 |
| `position`, `duration` | 再生位置・曲の長さ(秒) |
| `artworkID` | アートワーク変更時に変わる識別子。ない場合は空文字列 |
| `palette` | アートワークから抽出した色。取得できた場合のみ存在する。`primary`, `secondary`, `tertiary`, `text`, `highContrast`がそれぞれ0〜1の`[red,green,blue]` |

```js
function update(ctx) {
  const title = ctx.media.isAvailable ? ctx.media.title : "";
  return ctx.targets.filter(layer => layer.text !== null).map(layer => ({
    id: layer.id,
    text: { string: title },
  }));
}
```

## テキスト・描画順・スケルトン再生

出力には`values`などに加えて、以下も指定できる。いずれも既存の対象を調整する。

| 出力の項目 | 仕様 |
| --- | --- |
| `text.string` | テキストレイヤーの文字列。最大4096文字 |
| `text.color` | `{red,green,blue}`。全項目が必要で、各値0〜1。既存のアルファを維持する |
| `order` | 描画順を指定する整数。0〜全レイヤー数-1。未指定は元の順序。同順位は元のレイヤー順 |
| `rigs` | `[{id,playback:[{index,frame?,rate?,weight?}]}]`。対象に属するスケルトンの既存再生設定を調整する |

`layer.text`は`{string,color:{red,green,blue}}`。`layer.rigs`の各要素は`id`と`playback`を持つ。各再生設定には`index`, `name`, `frameCount`, `framesPerSecond`, `startFrame`, `rate`, `weight`, `loops`が入る。

`rigs[].playback`の`index`は既存再生設定のインデックス。`frame`は-1e9〜1e9で、そのフレームに固定する(`rate`を0にする)。`rate`は-1000〜1000、`weight`は0〜1。`frame`と`rate`は同時指定できない。1つの対象の出力で同じリグID・再生インデックスは重複指定できない。共有リグへの調整は、そのリグを参照する他のレイヤーにも反映される。

## モジュール形式

シーンドキュメントのスクリプトに`modules`辞書がある場合は、ソースをESモジュールとして扱う。空の辞書`{}`でもモジュール形式になり、エントリーソースは`update`を名前付きでexportする。通常の追加メニューのテンプレートは`modules`未指定の通常形式。

同梱するモジュールは`modules`のキーを名前、値をJavaScriptソースとする。エントリーのファイル名は`entry.js`。相対importは参照元から解決され、解決後の名前が辞書にあるソースだけを読み込む。ディスクやネットワークからの取得は行わない。

たとえば`modules`に以下を同梱する。

```json
{
  "lib/motion.js": "export const amplitude = 0.05;"
}
```

エントリーソース:

```js
import { amplitude } from "./lib/motion.js";

export function update(ctx) {
  return ctx.targets.map(layer => ({
    id: layer.id,
    values: { offsetY: wave(ctx.phase) * amplitude },
  }));
}
```

モジュールの初期化は一度だけで、変数の状態を評価間で保持する。「ループ時刻」が有効で`elapsedTime`が前回より小さくなった場合は、再コンパイルして状態を初期化する。スクリプトのソースや設定が変わった場合も再コンパイルする。状態を使う処理の結果は評価履歴に依存するため、任意時刻への移動・書き出しで同じ結果が必要な処理は入力時刻から計算する。

モジュール形式の戻り値は通常の調整配列に加えて、`{adjustments: [...], warnings: [...]}`も使える。`warnings`は最大16個の文字列で、各メッセージはUTF-8で1KiB以内。警告を表示しながら正常な部分の調整を適用できる。例外をthrowした場合はスクリプト全体の失敗として扱う。非同期の初期化・`update`は利用できない。

## 補助関数と診断

- `wave(phase, cycles=1, offset=0)`: -1〜1の正弦波。
- `clamp(value, min, max)`: 範囲へ収める。
- `lerp(a, b, t)`: 線形補間。
- `smoothstep(a, b, value)`: 0〜1の滑らかな補間。
- `random(seed, key=0)`: 整数のシードとキーから0以上1未満の固定値を返す。
- `noise(x, seed=0)`: 隣り合う固定乱数を滑らかに補間する1次元ノイズ。
- `hsv(h, s, v, alpha=1)`: 色相を1周で指定し、RGBA色を返す。
- `console.log(...)`: エディター内の診断欄へ文字列を出す。1回の評価で最大16呼び出し、約4KiB。システムのログや外部には送らない。

さらに以下を利用できる。

| API | 仕様 |
| --- | --- |
| `fract(x)`, `mod(x,n)` | 小数部分、負の値も扱える剰余 |
| `mapRange(v,a,b,c,d)` | 入力範囲a〜bを出力範囲c〜dへ変換 |
| `pingPong(x)` | 0〜1〜0を周期2で往復 |
| `triangle(phase)` | -1〜1の三角波 |
| `pulse(phase,duty=0.5)` | 周期1の矩形波。0または1 |
| `hash(text)` | 文字列から固定した32bit整数を作る |
| `ease(t,kind="smooth")` | tを0〜1へ収めてイージング。下記の種類を選ぶ |
| `curve(t,keys)` | `{time,value,ease?}`の配列を補間。時刻は昇順で重複なし、2点以上。終端外は端点の値 |
| `noise2(x,y,seed=0)` | 固定した2次元の滑らかなノイズ、0〜1 |
| `fbm2(x,y,seed=0,octaves=4)` | 1〜8層の2次元ノイズを合成、0〜1 |
| `vec.of(x=0,y=0)` | `{x,y}`を作る |
| `vec.add/sub(a,b)`, `vec.mul(a,n)` | ベクトルの加減算・倍数 |
| `vec.dot(a,b)`, `vec.length(a)`, `vec.distance(a,b)` | 内積・長さ・距離 |
| `vec.normalize(a)`, `vec.rotate(a,degrees)`, `vec.mix(a,b,t)` | 正規化・回転・補間。ゼロベクトルはゼロのまま |
| `path.circle(t,r=1)`, `path.ellipse(t,rx=1,ry=0.5)` | 原点を中心とした周期1の軌道 |
| `path.lissajous(t,a=3,b=2,offset=0.25)` | リサージュ軌道 |
| `path.bezier(a,b,c,d,t)` | 4つの`{x,y}`点による3次ベジェ曲線 |
| `path.polyline(points,t)` | 2点以上の折れ線を0〜1でたどる |
| `color.rgb(r,g,b,alpha=1)`, `color.hsv(h,s,v,alpha=1)` | RGBA色を作る |
| `color.hex(text)` | `#RRGGBB`または`#RRGGBBAA` |
| `color.mix(a,b,t)`, `color.alpha(c,a)` | 色の補間、透明度の設定 |

イージングの種類は`linear/smooth/smoother/inQuad/outQuad/inOutQuad/inCubic/outCubic/inOutCubic/inOutSine/outBack/outElastic/outBounce`。BackとElasticは途中で0〜1を超えるので、透明度などへ使う場合は`clamp`で収める。軌道の座標はキャンバス比率で扱い、必要なら`ctx.canvas.aspectRatio`で補正する。

時間・乱数は明示した入力から計算する。`Date`、`Math.random`、タイマー、非同期の`update`、Promiseを使う処理、バンドル外のモジュール、ファイル、ネットワーク、外部コマンドは利用できない。

## 実行制限と停止

スクリプトはメインスレッド外で実行する。上限はスクリプト32個、ソース64KiB、パラメーター64個、エディターで適用する対象128個、評価時の対象・出力調整512個、エフェクト調整16個／対象、出力256KiB。パラメーター名はUTF-8で128バイト以内、値は有限数。モジュールは最大256個で、名前とソースのUTF-8合計は1MiBまで。VMごとのメモリは16MiB、評価器全体のVMメモリは128MiB、スタックは最大512KiBで、実行スレッドの残り容量の半分までに抑える。コンパイルは100ms。ライブ評価のフレーム実行は1スクリプト8ms・全体16ms、書き出し用評価器は1スクリプト250ms・全体1秒を上限とする。モジュール形式の初回評価(初期化と最初の`update`)には、通常のフレーム予算とは別に最低100msを割り当てる。本数にかかわらず重い組み合わせは総予算で停止する。

値の型・範囲、対象外ID、未知の項目、NaN・Infinity、資源上限違反はエラーになる。エラーになったスクリプトは停止し、エディターへ理由を表示する。実行時間超過は一時停止として扱い、ライブ評価では2秒後に再試行する。それ以外は自動再試行しない。修正して「実行して適用」を押すと再開する。モジュールの部分的な失敗は、返された`warnings`を表示し、残りの調整を適用する。書き出し中の失敗では旧動画を保持する。

共有・Storeから取り込んだスクリプトは、保存元の有効設定にかかわらず利用者の許可なしでは動かない。許可は端末内の壁紙パス・ソース内容・API版・同梱モジュールに結び付く。未許可の間は添付動画を維持する。

コードは既存の描画を調整する機能であり、画像の追加・削除、マスク生成、シェーダー生成はGUIで行う。ループのつながりは作者が周期関数などで設計し、既存の終端確認操作で確認する。
