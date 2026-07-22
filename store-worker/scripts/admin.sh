#!/usr/bin/env bash
# ストア管理用の簡易CLI。個別削除と全削除(purge-all)をまとめて扱う。
#
# 使い方:
#   ADMIN_KEY=xxx STORE_WORKER_URL=https://your-worker.example.com ./scripts/admin.sh list
#   ADMIN_KEY=xxx STORE_WORKER_URL=https://your-worker.example.com ./scripts/admin.sh delete <entry-id>
#   ./scripts/admin.sh purge-all
#
# list / delete は Worker の /admin/reports, /admin/entries/:id を curl で叩くだけ(ADMIN_KEY必須)。
# purge-all は wrangler で直接 D1/R2 を操作するため ADMIN_KEY は不要だが、
# wrangler のCloudflareログインが必要(`wrangler login`済みであること)。

set -euo pipefail

D1_DATABASE="${STORE_D1_DATABASE:-livewallpaper-store-db}"
R2_BUCKET="${STORE_R2_BUCKET:-livewallpaper-store}"

usage() {
	echo "usage: $0 <list|delete <entry-id>|purge-all>" >&2
	exit 1
}

require_admin_env() {
	if [[ -z "${ADMIN_KEY:-}" || -z "${STORE_WORKER_URL:-}" ]]; then
		echo "error: ADMIN_KEY and STORE_WORKER_URL env vars are required for this command" >&2
		exit 1
	fi
}

cmd_list() {
	require_admin_env
	curl -sS "${STORE_WORKER_URL%/}/admin/reports" -H "x-admin-key: ${ADMIN_KEY}" | \
		(command -v jq >/dev/null 2>&1 && jq . || cat)
}

cmd_delete() {
	local id="${1:-}"
	[[ -n "$id" ]] || usage
	require_admin_env
	curl -sS -X DELETE "${STORE_WORKER_URL%/}/admin/entries/${id}" -H "x-admin-key: ${ADMIN_KEY}"
	echo
}

cmd_purge_all() {
	echo "This will PERMANENTLY delete ALL store entries (D1 rows + R2 objects) in:"
	echo "  D1 database: ${D1_DATABASE}"
	echo "  R2 bucket:   ${R2_BUCKET}"
	read -r -p "Type 'delete everything' to confirm: " confirm
	if [[ "$confirm" != "delete everything" ]]; then
		echo "aborted."
		exit 1
	fi

	local rows
	rows=$(npx wrangler d1 execute "$D1_DATABASE" --remote \
		--command "SELECT object_key, thumbnail_key FROM store_entries" --json)

	local keys
	keys=$(echo "$rows" | jq -r '.[0].results[] | .object_key, (.thumbnail_key // empty)')

	if [[ -n "$keys" ]]; then
		while IFS= read -r key; do
			[[ -n "$key" ]] || continue
			npx wrangler r2 object delete "${R2_BUCKET}/${key}" --remote
		done <<< "$keys"
	else
		echo "no objects to delete in R2."
	fi

	npx wrangler d1 execute "$D1_DATABASE" --remote \
		--command "DELETE FROM store_reports; DELETE FROM store_entries;"

	echo "purge-all complete."
}

case "${1:-}" in
	list) cmd_list ;;
	delete) cmd_delete "${2:-}" ;;
	purge-all) cmd_purge_all ;;
	*) usage ;;
esac
