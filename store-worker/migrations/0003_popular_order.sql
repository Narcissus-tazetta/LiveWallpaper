CREATE TABLE store_popular_order (
    snapshot INTEGER NOT NULL,
    position INTEGER NOT NULL,
    entry_id TEXT NOT NULL,
    ranked_downloads INTEGER NOT NULL,
    PRIMARY KEY (snapshot, position)
) WITHOUT ROWID;
