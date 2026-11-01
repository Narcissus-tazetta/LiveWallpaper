const ja = {
    lang: "ja",
    title: "LiveWallpaper — Mac のデスクトップに、動きを。",
    description:
        "好きな動画を Mac の壁紙にできるアプリ。作業の邪魔をしないよう、バッテリーと CPU への負荷を抑える設計です。無料・オープンソース。",
    nav: { features: "機能", light: "軽さ", automation: "自動化", download: "ダウンロード" },
    switchLabel: "English",
    hero: {
        eyebrow: "macOS 13 以降 · 無料 · オープンソース",
        title: ["デスクトップに、", "動きを。"],
        lead: "好きな動画を壁紙にして、作業の邪魔はしない。バッテリーと CPU への負荷を抑える設計の、Mac 用ライブ壁紙アプリです。",
        primary: "ダウンロード",
        secondary: "GitHub で見る",
        demoNote: "実際のアプリの挙動を再現したデモです。カーソルを動かして、クリックしてみてください。",
    },
    demo: {
        appName: "LiveWallpaper",
        wallpapers: "壁紙",
        effects: "カーソルエフェクト",
        presets: { aurora: "オーロラ", dusk: "夕景", deep: "深海" },
        parallax: "視差",
        spotlight: "スポットライト",
        trail: "軌跡",
        ripple: "クリックの波紋",
        menu: ["ファイル", "編集", "表示", "ウインドウ"],
    },
    features: {
        eyebrow: "機能",
        title: "壁紙まわりのことを、ひと通り。",
        items: [
            {
                id: "media",
                title: "あらゆる素材を壁紙に",
                body: "mp4 や mov の動画、GIF・APNG・アニメーション WebP、Web ページ(実験的)まで。そのまま登録できます。",
            },
            {
                id: "multi",
                title: "ディスプレイも、デスクトップも別々に",
                body: "ディスプレイごと、Mission Control のデスクトップ(Space)ごとに、違う壁紙を割り当てられます。",
            },
            {
                id: "auto",
                title: "自動で切り替わる",
                body: "ライト / ダーク、曜日と時間帯(日の出・日の入りも指定可)、集中モードに合わせて壁紙を選びます。",
            },
            {
                id: "edit",
                title: "切り出して、整える",
                body: "トリミング、イントロ付きのループ、ディスプレイごとのフィット調整まで、アプリの中で完結します。",
            },
            {
                id: "cursor",
                title: "カーソルに応える",
                body: "視差、スポットライト、ポインタの軌跡、クリックの波紋。壁紙ごとに設定でき、権限は不要です。",
            },
            {
                id: "playlist",
                title: "プレイリスト",
                body: "複数の動画を順番に。シャッフルと前後の移動に対応しています。",
            },
            {
                id: "saver",
                title: "スクリーンセーバー",
                body: "動画壁紙を、そのままスクリーンセーバーとしても再生できます。",
            },
            {
                id: "store",
                title: "ストア",
                body: "他の人が共有した壁紙をダウンロード。自分の壁紙は、審査を経て投稿できます。",
            },
        ],
    },
    light: {
        eyebrow: "軽さ",
        title: ["邪魔をしない。", "だから、出しっぱなしにできる。"],
        lead: "壁紙は、見えているときだけ動けば十分です。ほかのアプリが画面を覆えば止まり、バッテリーが減れば負荷を下げます。",
        toggleCover: "アプリで画面を覆う",
        toggleUncover: "アプリを閉じる",
        statePlaying: "再生中",
        statePaused: "一時停止",
        windowTitle: "メモ",
        points: [
            {
                title: "覆われたら止まる",
                body: "ほかのアプリが画面を大きく覆っている間は、再生を自動で止めます。除外するアプリやディスプレイも指定できます。",
            },
            {
                title: "バッテリーに合わせる",
                body: "電池駆動時は、通常再生・軽量版・静止から選べます。残量 10% 以下では自動で負荷を下げ、充電すれば元に戻ります。",
            },
            {
                title: "細かく調整できる",
                body: "フレームレート(30 / 60 / 無制限)、品質プリセット、デコード方式を選べます。",
            },
            {
                title: "視差効果の軽減に従う",
                body: "システムの「視差効果を減らす」がオンなら、壁紙を静止します。",
            },
        ],
    },
    automation: {
        eyebrow: "自動化",
        title: ["任せる。", "呼び出す。"],
        lead: "時間や状況に合わせて壁紙を切り替え、ショートカットや URL からも操作できます。",
        scheduleTitle: "スケジュール",
        scheduleNote: "例: 夜だけ別の壁紙にする",
        sunrise: "日の出",
        sunset: "日の入り",
        segments: { night: "夜の壁紙", day: "昼の壁紙" },
        shortcutsTitle: "グローバルショートカット",
        shortcuts: [
            { keys: ["⌃", "⌥", "⌘", "]"], label: "次の壁紙" },
            { keys: ["⌃", "⌥", "⌘", "["], label: "前の壁紙" },
            { keys: ["⌃", "⌥", "⌘", "M"], label: "音声の切り替え" },
            { keys: ["⌃", "⌥", "⌘", "D"], label: "デスクトップアイコンの表示 / 非表示" },
            { keys: ["⌃", "⌥", "⌘", "P"], label: "一時停止 / 再開" },
        ],
        urlTitle: "URL スキーム",
        urlNote: "Shortcuts、Raycast、open コマンドから呼べます。",
        copy: "コピー",
        copied: "コピーしました",
    },
    languages: {
        eyebrow: "多言語",
        title: "11 の言語に対応。",
        lead: "メニュー、設定、通知まで翻訳済み。macOS の言語設定に自動で合わせます。",
        list: [
            "日本語",
            "English",
            "简体中文",
            "繁體中文",
            "한국어",
            "Español",
            "Français",
            "Deutsch",
            "Português (Brasil)",
            "Tiếng Việt",
            "Türkçe",
        ],
    },
    download: {
        title: ["今すぐ、", "無料で。"],
        lead: "macOS 13 以降に対応。Apple シリコンと Intel の両方で動きます。",
        dmg: "DMG をダウンロード",
        brewLabel: "Homebrew でインストール",
        copy: "コピー",
        copied: "コピーしました",
        noteTitle: "初回起動について",
        note: "Apple の公証を受けていないため、初回は macOS の警告が出ることがあります。システム設定 › プライバシーとセキュリティ で「このまま開く」を選んでください。",
        readme: "詳しい使い方は README を参照",
    },
    footer: {
        license: "MIT License",
        github: "GitHub",
        releases: "Releases",
        unofficial: "Apple および macOS は Apple Inc. の商標です。",
    },
};

type Dict = typeof ja;

const en: Dict = {
    lang: "en",
    title: "LiveWallpaper — Bring your Mac desktop to life.",
    description:
        "Set your favorite videos as your Mac wallpaper, with a design that stays out of your way and keeps battery and CPU usage low. Free and open source.",
    nav: { features: "Features", light: "Efficiency", automation: "Automation", download: "Download" },
    switchLabel: "日本語",
    hero: {
        eyebrow: "macOS 13+ · Free · Open source",
        title: ["Bring your", "desktop to life."],
        lead: "Use your favorite videos as your wallpaper without getting in the way of your work. A live wallpaper app for Mac, designed to keep battery and CPU usage low.",
        primary: "Download",
        secondary: "View on GitHub",
        demoNote: "A demo that recreates how the app behaves. Move the cursor and click.",
    },
    demo: {
        appName: "LiveWallpaper",
        wallpapers: "Wallpapers",
        effects: "Cursor effects",
        presets: { aurora: "Aurora", dusk: "Dusk", deep: "Deep" },
        parallax: "Parallax",
        spotlight: "Spotlight",
        trail: "Trail",
        ripple: "Click ripple",
        menu: ["File", "Edit", "View", "Window"],
    },
    features: {
        eyebrow: "Features",
        title: "Everything around your wallpaper.",
        items: [
            {
                id: "media",
                title: "Any source, as a wallpaper",
                body: "mp4 and mov videos, GIF, APNG and animated WebP, even web pages (experimental). Register them as they are.",
            },
            {
                id: "multi",
                title: "Per display, per desktop",
                body: "Assign a different wallpaper to each display and to each Mission Control desktop (Space).",
            },
            {
                id: "auto",
                title: "Switches by itself",
                body: "Pick wallpapers by light or dark appearance, weekday and time of day (sunrise and sunset included), or Focus mode.",
            },
            {
                id: "edit",
                title: "Trim and fit it",
                body: "Trimming, loops with an intro, and per-display fit adjustment, all inside the app.",
            },
            {
                id: "cursor",
                title: "Responds to your cursor",
                body: "Parallax, spotlight, a pointer trail and click ripples. Set per wallpaper, with no permissions needed.",
            },
            {
                id: "playlist",
                title: "Playlists",
                body: "Play several videos in sequence, with shuffle and previous/next.",
            },
            {
                id: "saver",
                title: "Screen saver",
                body: "Play your video wallpaper as the screen saver too.",
            },
            {
                id: "store",
                title: "Store",
                body: "Download wallpapers shared by other people, or submit your own for review.",
            },
        ],
    },
    light: {
        eyebrow: "Efficiency",
        title: ["Out of your way.", "So you can leave it on."],
        lead: "A wallpaper only needs to move while you can see it. It stops when another app covers the screen, and eases off when the battery runs low.",
        toggleCover: "Cover the screen with an app",
        toggleUncover: "Close the app",
        statePlaying: "Playing",
        statePaused: "Paused",
        windowTitle: "Notes",
        points: [
            {
                title: "Stops when covered",
                body: "Playback pauses automatically while another app heavily covers the screen. Exclude apps and displays that shouldn't trigger it.",
            },
            {
                title: "Follows your battery",
                body: "On battery, play as usual, play the Lightweight version, or freeze. At 10% or less the load drops automatically, and returns when you plug in.",
            },
            {
                title: "Tunable",
                body: "Choose the frame rate (30 / 60 / unlimited), a quality preset and the decode mode.",
            },
            {
                title: "Respects Reduce Motion",
                body: "When the system's Reduce Motion setting is on, the wallpaper freezes.",
            },
        ],
    },
    automation: {
        eyebrow: "Automation",
        title: ["Let it run.", "Or call it."],
        lead: "Switch wallpapers by time and context, and drive the app from shortcuts or URLs.",
        scheduleTitle: "Schedule",
        scheduleNote: "Example: a different wallpaper for the night",
        sunrise: "Sunrise",
        sunset: "Sunset",
        segments: { night: "Night wallpaper", day: "Day wallpaper" },
        shortcutsTitle: "Global shortcuts",
        shortcuts: [
            { keys: ["⌃", "⌥", "⌘", "]"], label: "Next wallpaper" },
            { keys: ["⌃", "⌥", "⌘", "["], label: "Previous wallpaper" },
            { keys: ["⌃", "⌥", "⌘", "M"], label: "Toggle audio" },
            { keys: ["⌃", "⌥", "⌘", "D"], label: "Show / hide desktop icons" },
            { keys: ["⌃", "⌥", "⌘", "P"], label: "Pause / resume" },
        ],
        urlTitle: "URL scheme",
        urlNote: "Call it from Shortcuts, Raycast, or the open command.",
        copy: "Copy",
        copied: "Copied",
    },
    languages: {
        eyebrow: "Languages",
        title: "Available in 11 languages.",
        lead: "Menus, settings and notifications are all translated, and follow your macOS language automatically.",
        list: ja.languages.list,
    },
    download: {
        title: ["Get it now.", "It's free."],
        lead: "Requires macOS 13 or later. Runs on both Apple silicon and Intel.",
        dmg: "Download the DMG",
        brewLabel: "Install with Homebrew",
        copy: "Copy",
        copied: "Copied",
        noteTitle: "About the first launch",
        note: "The app is not notarized by Apple, so macOS may show a warning the first time. Choose Open Anyway in System Settings › Privacy & Security.",
        readme: "Read the README for details",
    },
    footer: {
        license: "MIT License",
        github: "GitHub",
        releases: "Releases",
        unofficial: "Apple and macOS are trademarks of Apple Inc.",
    },
};

export const dictionaries = { ja, en } as const;
export type Lang = keyof typeof dictionaries;
export type { Dict };

export const repo = "https://github.com/Narcissus-tazetta/LiveWallpaper";
export const brewCommand = "brew install --cask narcissus-tazetta/tap/livewallpaper";
export const siteUrl = "https://narcissus-tazetta.github.io/LiveWallpaper";
