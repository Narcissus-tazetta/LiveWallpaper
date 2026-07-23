#!/usr/bin/env bash
# ストア管理用の簡易CLI。個別削除と全削除(purge-all)をまとめて扱う。
#
# 使い方:
#   ADMIN_KEY=xxx STORE_WORKER_URL=https://your-worker.example.com ./scripts/admin.sh list
#   ADMIN_KEY=xxx STORE_WORKER_URL=https://your-worker.example.com ./scripts/admin.sh delete <entry-id>
#   ADMIN_KEY=xxx STORE_WORKER_URL=https://your-worker.example.com ./scripts/admin.sh requests
#   ADMIN_KEY=xxx STORE_WORKER_URL=https://your-worker.example.com ./scripts/admin.sh approve <entry-id>
#   ADMIN_KEY=xxx STORE_WORKER_URL=https://your-worker.example.com ./scripts/admin.sh reject <entry-id>
#   ADMIN_KEY=xxx STORE_WORKER_URL=https://your-worker.example.com ./scripts/admin.sh resend-review <entry-id>
#   ./scripts/admin.sh purge-all
#
# list / delete / requests / approve / reject / resend-review は Worker の /admin/* を
# curl で叩くだけ(ADMIN_KEY必須)。審査依頼メールが迷惑メール判定等で届かない場合、
# requests で申請中の投稿を確認し、approve/reject で直接決定できる(メール非依存の
# フォールバック)。reject しても R2 上のオブジェクトは残るので、不要なら delete で
# ストレージを解放すること。
# purge-all は wrangler で直接 D1/R2 を操作するため ADMIN_KEY は不要だが、
# wrangler のCloudflareログインが必要(`wrangler login`済みであること)。

set -euo pipefail

D1_DATABASE="${STORE_D1_DATABASE:-livewallpaper-store-db}"
R2_BUCKET="${STORE_R2_BUCKET:-livewallpaper-store}"

usage() {
	echo "usage: $0 <list|delete <entry-id>|requests|approve <entry-id>|reject <entry-id>|resend-review <entry-id>|purge-all>" >&2
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

cmd_requests() {
	require_admin_env
	curl -sS "${STORE_WORKER_URL%/}/admin/requests" -H "x-admin-key: ${ADMIN_KEY}" | \
		(command -v jq >/dev/null 2>&1 && jq . || cat)
}

cmd_approve() {
	local id="${1:-}"
	[[ -n "$id" ]] || usage
	require_admin_env
	curl -sS -X POST "${STORE_WORKER_URL%/}/admin/entries/${id}/approve" -H "x-admin-key: ${ADMIN_KEY}"
	echo
}

cmd_reject() {
	local id="${1:-}"
	[[ -n "$id" ]] || usage
	require_admin_env
	curl -sS -X POST "${STORE_WORKER_URL%/}/admin/entries/${id}/reject" -H "x-admin-key: ${ADMIN_KEY}"
	echo
}

cmd_resend_review() {
	local id="${1:-}"
	[[ -n "$id" ]] || usage
	require_admin_env
	curl -sS -X POST "${STORE_WORKER_URL%/}/admin/entries/${id}/resend-review" -H "x-admin-key: ${ADMIN_KEY}"
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
	requests) cmd_requests ;;
	approve) cmd_approve "${2:-}" ;;
	reject) cmd_reject "${2:-}" ;;
	resend-review) cmd_resend_review "${2:-}" ;;
	purge-all) cmd_purge_all ;;
	*) usage ;;
esac
