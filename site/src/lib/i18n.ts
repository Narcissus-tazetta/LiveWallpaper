const ja = {
    lang: "ja",
    title: "LiveWallpaper — 動画を Mac の壁紙に",
    description:
        "手元の動画や GIF を Mac のデスクトップ壁紙に設定できるオープンソースアプリ。ウィンドウで隠れている間の一時停止やバッテリー駆動時の負荷軽減に対応しています。",
    nav: { features: "機能", download: "インストール", github: "GitHub" },
    switchLabel: "English",
    hero: {
        title: "動画を Mac の壁紙に",
        lead: "手元の動画やアニメーション画像をデスクトップの壁紙として再生する macOS アプリです。他のウィンドウで隠れている間の一時停止や、バッテリー駆動時の負荷軽減に対応しています。",
        meta: "macOS 13 以降 · Apple Silicon / Intel · MIT License",
        primary: "インストール",
        secondary: "GitHub",
        videoLabel: "LiveWallpaper で動画をデスクトップ壁紙にしている様子",
    },
    features: {
        title: "主な機能",
        items: [
            {
                id: "media",
                title: "動画・GIF・Web ページ",
                body: "mp4・mov などの動画、GIF・APNG・アニメーション WebP、Web ページや動画 URL(実験的機能)を登録できます。デスクトップ用とロック画面用(macOS 26 以降)で別の動画を割り当てることも可能です。",
            },
            {
                id: "multi",
                title: "ディスプレイ・Space 別",
                body: "接続中のディスプレイごと、Mission Control のデスクトップ(Space)ごとに別の壁紙を設定できます。",
            },
            {
                id: "auto",
                title: "条件に応じた自動切り替え",
                body: "ライト / ダーク外観、曜日と時間帯(日の出・日の入り指定可)、集中モードに応じて自動で切り替えます。",
            },
            {
                id: "edit",
                title: "トリム・配置編集",
                body: "再生範囲の切り出し、初回だけ流れるイントロ付きループ、ディスプレイごとの表示モード・ズーム・位置調整に対応しています。",
            },
            {
                id: "power",
                title: "自動一時停止と省電力制御",
                body: "他のウィンドウが画面を覆っている間は自動で再生を一時停止します(アプリ・画面単位の除外設定可)。バッテリー駆動時の軽量再生・静止画化、残量 10% 以下での負荷軽減、フレームレート上限(30 / 60 / 無制限)やデコード方式の選択に対応しています。",
            },
            {
                id: "cursor",
                title: "カーソルエフェクト",
                body: "視差、スポットライト、軌跡、クリック時の波紋を壁紙ごとに設定できます。権限は不要で、他のアプリを操作中は停止します。",
            },
            {
                id: "control",
                title: "ショートカット・URL スキーム・スクリーンセーバー",
                body: "プレイリスト再生、動画壁紙をそのまま流すスクリーンセーバー、グローバルショートカット、Shortcuts.app や Raycast・open コマンドから呼べる livewallpaper:// URL スキームを備えています。",
            },
            {
                id: "store",
                title: "ストア・パッケージ共有・11 言語対応",
                body: "他のユーザーが共有した壁紙のダウンロードや投稿(審査あり)、トリム・配置設定を含む .lwpkg パッケージの書き出し・読み込みに対応。UI は日本語・英語を含む 11 言語に翻訳されています。",
            },
        ],
    },
    screens: {
        title: "設定画面",
        items: [
            {
                id: "display",
                label: "表示",
                caption:
                    "表示するディスプレイ、動画のフィット、切り替えエフェクト、デスクトップの見やすさを調整します。",
            },
            {
                id: "integrations",
                label: "連携",
                caption: "壁紙の共有、Web 壁紙、グローバルショートカットを設定します。",
            },
            {
                id: "general",
                label: "一般",
                caption: "クリック貫通、ログイン時の自動起動、音声、言語、アップデートを設定します。",
            },
        ],
    },
    download: {
        title: "インストール",
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
        unofficial: "Apple および macOS は Apple Inc. の商標です。",
        videoCredit: "ヒーロー動画: Chandresh Uike / Pexels",
    },
};

type Dict = typeof ja;

const en: Dict = {
    lang: "en",
    title: "LiveWallpaper — Video wallpapers for Mac",
    description:
        "An open-source macOS app that plays local videos and GIFs as your desktop wallpaper, with automatic pause when covered and reduced load on battery power.",
    nav: { features: "Features", download: "Install", github: "GitHub" },
    switchLabel: "日本語",
    hero: {
        title: "Video wallpapers for Mac",
        lead: "A macOS app that plays local videos and animated images on your desktop, with automatic pause when covered by other windows and reduced load on battery power.",
        meta: "macOS 13+ · Apple silicon & Intel · MIT License",
        primary: "Install",
        secondary: "GitHub",
        videoLabel: "A video playing as the desktop wallpaper with LiveWallpaper",
    },
    features: {
        title: "Features",
        items: [
            {
                id: "media",
                title: "Videos, GIFs, and web pages",
                body: "Use mp4 and mov videos, GIF, APNG, animated WebP, or web pages and video URLs (experimental). Separate videos can also be assigned to the desktop and lock screen (macOS 26+).",
            },
            {
                id: "multi",
                title: "Per display and Space",
                body: "Assign different wallpapers to each connected display and to each Mission Control desktop (Space).",
            },
            {
                id: "auto",
                title: "Automatic switching",
                body: "Switch wallpapers by light or dark appearance, weekday and time-of-day rules (including sunrise and sunset), or Focus mode.",
            },
            {
                id: "edit",
                title: "Trim and fit editor",
                body: "Cut videos to a specific range, set a separate loop start point with an intro pass, and adjust fit mode, zoom, and offset per display.",
            },
            {
                id: "power",
                title: "Auto-pause and power control",
                body: "Automatically pauses playback while another window covers the screen (with per-app and per-display exclusions). Supports lightweight or frozen playback on battery, automatic load reduction at 10% battery, frame rate limits (30 / 60 / unlimited), and decode mode selection.",
            },
            {
                id: "cursor",
                title: "Cursor effects",
                body: "Configure parallax, spotlight, pointer trail, and click ripples per wallpaper. Requires no permissions and stops while another app is active.",
            },
            {
                id: "control",
                title: "Shortcuts, URL scheme, and screen saver",
                body: "Includes sequential or shuffled playlists, a native screen saver using your video wallpaper, global keyboard shortcuts, and a livewallpaper:// URL scheme for Shortcuts, Raycast, or open.",
            },
            {
                id: "store",
                title: "Store, package sharing, and 11 languages",
                body: "Download community wallpapers or submit your own for review, and export or import .lwpkg packages with trim and fit metadata. Full UI localization in 11 languages.",
            },
        ],
    },
    screens: {
        title: "Settings",
        items: [
            {
                id: "display",
                label: "Display",
                caption:
                    "Choose where wallpapers appear, how videos fit, the switch effect, and desktop readability.",
            },
            {
                id: "integrations",
                label: "Integrations",
                caption: "Configure wallpaper sharing, web wallpapers, and global shortcuts.",
            },
            {
                id: "general",
                label: "General",
                caption: "Set click-through, launch at login, audio, language, and updates.",
            },
        ],
    },
    download: {
        title: "Install",
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
        unofficial: "Apple and macOS are trademarks of Apple Inc.",
        videoCredit: "Hero video: Chandresh Uike / Pexels",
    },
};

export const dictionaries = { ja, en } as const;
export type Lang = keyof typeof dictionaries;
export type { Dict };

export const repo = "https://github.com/Narcissus-tazetta/LiveWallpaper";
export const brewCommand = "brew install --cask narcissus-tazetta/tap/livewallpaper";
export const siteUrl = "https://narcissus-tazetta.github.io/LiveWallpaper";
