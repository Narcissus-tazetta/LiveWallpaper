function base64UrlEncode(bytes: Uint8Array): string {
	let binary = "";
	for (const byte of bytes) {
		binary += String.fromCharCode(byte);
	}
	return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// 審査用ワンタイムトークンの生トークンを生成する(256bit)。この文字列自体が
/// 認証情報になるため、DBにはハッシュのみ保存しメール本文にのみ埋め込む。
export function generateRawToken(): string {
	return base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));
}

export async function hashToken(raw: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw));
	return Array.from(new Uint8Array(digest))
		.map((b) => b.toString(16).padStart(2, "0"))
		.join("");
}
