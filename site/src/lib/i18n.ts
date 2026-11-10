const ja = {
    lang: "ja",
    title: "LiveWallpaper — 動画を Mac の壁紙に",
    description:
        "手元の動画や GIF を Mac のデスクトップ壁紙に設定できるオープンソースアプリ。ウィンドウで隠れている間の一時停止やバッテリー駆動時の負荷軽減に対応しています。",
    nav: { features: "機能", faq: "FAQ", download: "インストール", github: "GitHub" },
    switchLabel: "English",
    locale: "ja_JP",
    hero: {
        title: "動画を Mac の壁紙に",
        lead: "手元の動画やアニメーション画像をデスクトップの壁紙として再生する macOS アプリです。他のウィンドウで隠れている間の一時停止や、バッテリー駆動時の負荷軽減に対応しています。",
        meta: "macOS 13 以降 · Apple Silicon / Intel · 無料・オープンソース",
        downloads: (count: string) => `${count} ダウンロード`,
        primary: "インストール",
        secondary: "GitHub",
        videoLabel: "LiveWallpaper で動画をデスクトップ壁紙にしている様子",
    },
    features: {
        title: "主な機能",
        headline: "動く壁紙を、Mac に負担をかけずに。",
        lead: "見えていない間は止まり、バッテリー駆動中は自動で軽くなります。そのうえで、画面ごと・時間ごとに細かく設定できます。",
        stats: [
            { value: "≈0%", label: "ウィンドウで覆われている間の CPU" },
            { value: "2–3%", label: "再生中のアプリの CPU" },
            { value: "60–110MB", label: "再生中のメモリ" },
        ],
        statsNote:
            "MacBook Air(M5)でフル HD・30fps の動画 1 本を再生した実測例。動画やディスプレイの構成によって変わります。",
        items: [
            {
                id: "media",
                title: "動画・GIF・Web ページ",
                body: "手元の動画やアニメーション画像を、そのままデスクトップで再生します。",
                tags: ["mp4 / mov", "GIF / APNG / WebP", "Web・動画 URL(実験的)"],
            },
            {
                id: "power",
                title: "見えない間は止まる",
                body: "ウィンドウで覆われると再生を止めます。バッテリー駆動中は軽量再生や静止画に切り替えられます。",
                tags: ["自動一時停止", "残量 10% で軽量化", "30 / 60 fps 上限"],
            },
            {
                id: "multi",
                title: "ディスプレイ・Space ごと",
                body: "画面ごと、Mission Control のデスクトップごとに別の壁紙を割り当てられます。",
                tags: ["マルチディスプレイ", "Space 別", "ロック画面(macOS 26+)"],
            },
            {
                id: "auto",
                title: "条件で自動切り替え",
                body: "外観、曜日と時間帯、集中モードに合わせて壁紙が切り替わります。",
                tags: ["ライト / ダーク", "日の出・日の入り", "集中モード"],
            },
            {
                id: "edit",
                title: "トリムと配置の編集",
                body: "使う部分だけを切り出し、イントロ付きのループも作れます。ズームと位置はディスプレイごとに保存されます。",
                tags: ["カット", "ループ開始位置", "ズーム・位置"],
            },
            {
                id: "cursor",
                title: "カーソルエフェクト",
                body: "マウスの動きに壁紙が反応します。権限は不要で、他のアプリを使っている間は止まります。",
                tags: ["視差", "スポットライト", "軌跡・波紋"],
            },
        ],
        more: [
            {
                id: "control",
                title: "ショートカット・URL スキーム",
                body: "Shortcuts.app や Raycast から操作",
            },
            { id: "screensaver", title: "スクリーンセーバー", body: "動画の壁紙をそのまま再生" },
            { id: "playlist", title: "プレイリスト", body: "順番・シャッフル再生" },
            { id: "store", title: "Store・パッケージ共有", body: "壁紙を設定ごと共有・ダウンロード" },
            { id: "language", title: "11 言語", body: "UI 全体を翻訳済み" },
            { id: "update", title: "自動アップデート", body: "アプリ内から最新版へ" },
        ],
    },
    screens: {
        title: "アプリの画面",
        items: [
            {
                id: "library",
                label: "壁紙",
                caption:
                    "動画や写真を並べて、デスクトップ・ロック画面・スクリーンセーバーにそれぞれ別の壁紙を割り当てられます。",
            },
            {
                id: "edit",
                label: "編集",
                caption: "ディスプレイごとの配置、再生範囲、カーソルエフェクトを調整します。",
            },
            {
                id: "scene",
                label: "シーンエディタ",
                caption: "1 枚の写真に、舞う花びらや雲の流れなどの動きを重ねて、動く壁紙にできます。",
            },
        ],
    },
    faq: {
        title: "よくある質問",
        items: [
            {
                q: "無料ですか？",
                a: "無料です。MIT License のオープンソースで、ソースコードは GitHub で公開しています。",
            },
            {
                q: "バッテリーや CPU に負担はかかりませんか？",
                a: "他のウィンドウで覆われている間は再生を止め、覆われた状態が続くとデコード用のリソースも解放します。MacBook Air(M5)でフル HD・30fps の動画 1 本を再生した例では、CPU 使用率は数 % 程度、メモリは約 60〜110MB でした。動画の解像度やディスプレイの枚数によって変わります。",
            },
            {
                q: "初回起動時に警告が出るのはなぜですか？",
                a: "Apple の公証を受けずに配布しているためです。「システム設定 › プライバシーとセキュリティ」で「このまま開く」を選ぶと起動できます。ソースコードはすべて公開しており、自分でビルドすることもできます。",
            },
            {
                q: "どんなファイルを壁紙にできますか？",
                a: "mp4・mov などの動画と、GIF・APNG・アニメーション WebP です。アニメーション画像は読み込み時に動画へ変換されます。Web ページや YouTube・Vimeo の URL も実験的機能として使えます。",
            },
            {
                q: "アップデートはどうすればいいですか？",
                a: "アプリ内の自動アップデートで最新版に更新できます。Homebrew でインストールした場合は brew upgrade --cask livewallpaper でも更新できます。",
            },
            {
                q: "不具合を見つけたときは？",
                a: "設定 › その他 › サポートの「診断情報を書き出す…」で情報をまとめ、「不具合を報告…」から GitHub の issue に添付してください。動画ファイルや Web 壁紙の URL は含まれません。",
            },
        ],
    },
    download: {
        title: "インストール",
        latest: (version: string, date: string) => `最新版 v${version}(${date} 公開)`,
        lead: "macOS 13 以降に対応しています。Homebrew または DMG からインストールできます。",
        dmg: "DMG をダウンロード (Releases)",
        brewLabel: "Homebrew (推奨)",
        copy: "コピー",
        copied: "コピー済",
        noteTitle: "初回起動時の警告について",
        note: "Apple の公証を受けていないため、初回起動時に macOS のセキュリティ警告が出る場合があります。「システム設定 › プライバシーとセキュリティ」で「このまま開く」を選択してください。自動アップデートを有効にするため、アプリは「アプリケーション」フォルダに配置して起動してください。",
        readme: "詳しい使い方・仕様は README を参照",
    },
    footer: {
        license: "MIT License",
        github: "GitHub",
        releases: "Releases",
        donate: "支援する",
        unofficial: "Apple および macOS は Apple Inc. の商標です。",
        videoCredit: "ヒーロー動画: Chandresh Uike / Pexels",
        photoCredit: "湖の写真: bernardouploud / Pixabay",
        cloudsCredit: "雲の動画: Pixabay",
    },
};

type Dict = typeof ja;

const en: Dict = {
    lang: "en",
    title: "LiveWallpaper — Video wallpapers for Mac",
    description:
        "An open-source macOS app that plays local videos and GIFs as your desktop wallpaper, with automatic pause when covered and reduced load on battery power.",
    nav: { features: "Features", faq: "FAQ", download: "Install", github: "GitHub" },
    switchLabel: "日本語",
    locale: "en_US",
    hero: {
        title: "Video wallpapers for Mac",
        lead: "A macOS app that plays local videos and animated images on your desktop, with automatic pause when covered by other windows and reduced load on battery power.",
        meta: "macOS 13+ · Apple silicon & Intel · Free and open source",
        downloads: (count: string) => `${count} downloads`,
        primary: "Install",
        secondary: "GitHub",
        videoLabel: "A video playing as the desktop wallpaper with LiveWallpaper",
    },
    features: {
        title: "Features",
        headline: "Moving wallpapers, without weighing down your Mac.",
        lead: "Playback stops when nothing can see it and gets lighter on battery. On top of that, every display and every hour can have its own wallpaper.",
        stats: [
            { value: "≈0%", label: "CPU while covered by windows" },
            { value: "2–3%", label: "App CPU while playing" },
            { value: "60–110 MB", label: "Memory while playing" },
        ],
        statsNote:
            "Measured on a MacBook Air (M5) playing one 1080p 30 fps video. Results vary with the video and display setup.",
        items: [
            {
                id: "media",
                title: "Videos, GIFs, and web pages",
                body: "Play your own videos and animated images right on the desktop.",
                tags: ["mp4 / mov", "GIF / APNG / WebP", "Web & video URLs (experimental)"],
            },
            {
                id: "power",
                title: "Stops when it can't be seen",
                body: "Playback pauses while windows cover the screen. On battery, switch to lightweight playback or a still frame.",
                tags: ["Auto-pause", "Lighter at 10% battery", "30 / 60 fps cap"],
            },
            {
                id: "multi",
                title: "Per display and Space",
                body: "Assign a different wallpaper to each display and each Mission Control desktop.",
                tags: ["Multiple displays", "Per Space", "Lock screen (macOS 26+)"],
            },
            {
                id: "auto",
                title: "Automatic switching",
                body: "Wallpapers follow your appearance, weekday and time of day, or Focus mode.",
                tags: ["Light / Dark", "Sunrise & sunset", "Focus"],
            },
            {
                id: "edit",
                title: "Trim and fit editor",
                body: "Cut to the part you want, loop with an intro, and save zoom and position per display.",
                tags: ["Trim", "Loop start", "Zoom & offset"],
            },
            {
                id: "cursor",
                title: "Cursor effects",
                body: "The wallpaper reacts to your pointer. No permissions needed, and it stops while you use other apps.",
                tags: ["Parallax", "Spotlight", "Trail & ripple"],
            },
        ],
        more: [
            {
                id: "control",
                title: "Shortcuts and URL scheme",
                body: "Control it from Shortcuts or Raycast",
            },
            { id: "screensaver", title: "Screen saver", body: "Your video wallpaper as a screen saver" },
            { id: "playlist", title: "Playlists", body: "Sequential or shuffled playback" },
            { id: "store", title: "Store and packages", body: "Share wallpapers with their settings" },
            { id: "language", title: "11 languages", body: "Fully localized UI" },
            { id: "update", title: "Automatic updates", body: "Update from inside the app" },
        ],
    },
    screens: {
        title: "Inside the app",
        items: [
            {
                id: "library",
                label: "Wallpaper",
                caption:
                    "Keep videos and photos in one library, and give the desktop, lock screen, and screen saver each their own wallpaper.",
            },
            {
                id: "edit",
                label: "Edit",
                caption: "Adjust the fit for each display, the playback range, and cursor effects.",
            },
            {
                id: "scene",
                label: "Scene Editor",
                caption:
                    "Turn a single photo into a moving wallpaper by layering falling petals, drifting clouds, and other motion on top.",
            },
        ],
    },
    faq: {
        title: "FAQ",
        items: [
            {
                q: "Is it free?",
                a: "Yes. LiveWallpaper is open source under the MIT License, and the source code is on GitHub.",
            },
            {
                q: "Does it drain battery or CPU?",
                a: "Playback stops while other windows cover the screen, and decoding resources are released if it stays covered. Playing one 1080p 30 fps video on a MacBook Air (M5) used a few percent of CPU and about 60–110 MB of memory. Results vary with video resolution and the number of displays.",
            },
            {
                q: "Why does macOS warn me on first launch?",
                a: "The app is distributed without Apple notarization. Choose Open Anyway in System Settings › Privacy & Security to launch it. All of the source code is public, so you can also build it yourself.",
            },
            {
                q: "Which files can I use?",
                a: "Videos such as mp4 and mov, plus GIF, APNG, and animated WebP, which are converted to video on import. Web pages and YouTube or Vimeo URLs are available as an experimental feature.",
            },
            {
                q: "How do I update?",
                a: "Use the built-in automatic updates. If you installed with Homebrew, brew upgrade --cask livewallpaper also works.",
            },
            {
                q: "How do I report a bug?",
                a: "Use Export Diagnostics… under Settings › Other › Support, then attach the file to a GitHub issue via Report a Problem…. Video files and web wallpaper URLs are not included.",
            },
        ],
    },
    download: {
        title: "Install",
        latest: (version: string, date: string) => `Latest: v${version}, released ${date}`,
        lead: "Requires macOS 13 or later. Install via Homebrew or download the DMG.",
        dmg: "Download DMG (Releases)",
        brewLabel: "Homebrew (recommended)",
        copy: "Copy",
        copied: "Copied",
        noteTitle: "First launch warning",
        note: "Because the app is distributed without Apple notarization, macOS may show a warning on first launch. Choose Open Anyway in System Settings › Privacy & Security. Move LiveWallpaper.app into Applications before launching so in-app updates work properly.",
        readme: "Read the README for full documentation",
    },
    footer: {
        license: "MIT License",
        github: "GitHub",
        releases: "Releases",
        donate: "Support",
        unofficial: "Apple and macOS are trademarks of Apple Inc.",
        videoCredit: "Hero video: Chandresh Uike / Pexels",
        photoCredit: "Lake photo: bernardouploud / Pixabay",
        cloudsCredit: "Cloud video: Pixabay",
    },
};

export const dictionaries = { ja, en } as const;
export type Lang = keyof typeof dictionaries;
export type { Dict };

export const donateUrl = "https://ko-fi.com/prason";
export const repo = "https://github.com/Narcissus-tazetta/LiveWallpaper";
export const repoApi = "https://api.github.com/repos/Narcissus-tazetta/LiveWallpaper";
export const brewCommand = "brew install --cask narcissus-tazetta/tap/livewallpaper";
export const siteUrl = "https://livewallpaper.prason.dev";
