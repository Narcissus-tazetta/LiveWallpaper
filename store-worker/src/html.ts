/// 審査ページ(HTML)に投稿者由来の文字列(タイトル/作者名など)を埋め込む前に
/// 必ず通す。投稿時点では未審査のため、stored XSSを防ぐ目的で必須。
export function escapeHtml(s: string): string {
	return s
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;")
		.replace(/'/g, "&#39;");
}
