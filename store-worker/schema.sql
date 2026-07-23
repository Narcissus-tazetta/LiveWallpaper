CREATE TABLE store_entries (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    author TEXT NOT NULL,
    description TEXT,
    object_key TEXT NOT NULL,
    thumbnail_key TEXT,
    sha256 TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    duration_seconds REAL,
    has_audio INTEGER,
    license TEXT,
    created_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'published',
    report_count INTEGER NOT NULL DEFAULT 0,
    download_count INTEGER NOT NULL DEFAULT 0,
    -- 投稿者本人が自己サービスで取り下げる(DELETE /entries/:id/withdraw)ための
    -- 秘密トークンのSHA-256ハッシュ。生トークンは/submitのレスポンスで一度だけ返し、
    -- サーバー側には保存しない(store_review_tokens.token_hashと同じ方針)。
    -- このカラム追加前に投稿されたエントリはNULLのままで、取り下げ不可。
    withdraw_token_hash TEXT
);

CREATE INDEX idx_store_entries_status_created ON store_entries(status, created_at DESC);

-- /catalog?sort=popular (download_count DESC, created_at DESC でのカーソルページング) 用。
CREATE INDEX idx_store_entries_status_downloads ON store_entries(status, download_count DESC, created_at DESC);

CREATE TABLE store_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id TEXT NOT NULL REFERENCES store_entries(id),
    reason TEXT,
    reporter_ip TEXT NOT NULL,
    reported_at TEXT NOT NULL
);

-- 同一IPからの同一エントリへの重複報告を防ぐ(素朴な多重投票対策)。
CREATE UNIQUE INDEX idx_store_reports_entry_reporter ON store_reports(entry_id, reporter_ip);

-- status='requested' なエントリの審査用ワンタイムトークン。生トークンは保存せず
-- token_hash (SHA-256) のみ保存する。consumed_at は「このトークン経由で決定が
-- 行われたか」を意味し、resend-review による強制失効では expires_at のみ更新する。
CREATE TABLE store_review_tokens (
    id TEXT PRIMARY KEY,
    entry_id TEXT NOT NULL REFERENCES store_entries(id),
    token_hash TEXT NOT NULL,
    action TEXT,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    consumed_at TEXT,
    resend_email_id TEXT
);

CREATE UNIQUE INDEX idx_store_review_tokens_hash ON store_review_tokens(token_hash);
CREATE INDEX idx_store_review_tokens_entry ON store_review_tokens(entry_id);
