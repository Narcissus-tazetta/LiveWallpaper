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
    download_count INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_store_entries_status_created ON store_entries(status, created_at DESC);

CREATE TABLE store_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id TEXT NOT NULL REFERENCES store_entries(id),
    reason TEXT,
    reporter_ip TEXT NOT NULL,
    reported_at TEXT NOT NULL
);

-- 同一IPからの同一エントリへの重複報告を防ぐ(素朴な多重投票対策)。
CREATE UNIQUE INDEX idx_store_reports_entry_reporter ON store_reports(entry_id, reporter_ip);
