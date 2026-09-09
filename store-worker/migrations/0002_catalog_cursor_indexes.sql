-- Existing deployments already have the original index names without the final id
-- tie-breaker. New names guarantee D1 creates the corrected definitions.
CREATE INDEX IF NOT EXISTS idx_store_entries_status_created_v2
ON store_entries(status, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_store_entries_status_downloads_v2
ON store_entries(status, download_count DESC, created_at DESC, id DESC);
