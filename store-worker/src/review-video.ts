import { unzipSync } from "fflate";
import { MAX_PREVIEW_ARCHIVE_BYTES, MAX_VIDEO_PREVIEW_BYTES } from "./constants";
import type { Env } from "./env";

/// Rangeヘッダ("bytes=start-end"等)を解釈する。ブラウザの<video>は再生開始時や
/// シーク時に必ずRangeで問い合わせてくる(特にSafariはRange非対応のサーバーからは
/// 動画そのものを再生してくれない)ため、プレビューエンドポイントは対応必須。
/// 不正な形式やtotalLengthを超える範囲は無視して全体を返す(仕様上のフォールバック)。
export function parseRangeHeader(
	rangeHeader: string | null,
	totalLength: number,
): { start: number; end: number } | null {
	if (!rangeHeader) {
		return null;
	}
	const match = rangeHeader.match(/^bytes=(\d*)-(\d*)$/);
	if (!match || (match[1] === "" && match[2] === "")) {
		return null;
	}
	let start: number;
	let end: number;
	if (match[1] === "") {
		// "bytes=-500" 形式: 末尾500バイト。
		const suffixLength = Number.parseInt(match[2], 10);
		start = Math.max(totalLength - suffixLength, 0);
		end = totalLength - 1;
	} else {
		start = Number.parseInt(match[1], 10);
		end = match[2] === "" ? totalLength - 1 : Number.parseInt(match[2], 10);
	}
	if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end < start || start >= totalLength) {
		return null;
	}
	return { start, end: Math.min(end, totalLength - 1) };
}

/// .lwpkg(ZIP)の中から動画本体(content/videos/<id>.mp4)だけを取り出して返す。
/// unzipSyncのfilterで動画エントリ以外(metadata.json/previews/*.png)の展開を
/// スキップさせ、Worker内メモリ使用量を動画本体分だけに抑える。
function extractVideoEntry(zipBytes: Uint8Array): Uint8Array | null {
	const videoPathRe = /^content\/videos\/[^/]+$/i;
	let matchedKey: string | null = null;
	let rejectedForSize = false;
	let unzipped: Record<string, Uint8Array>;
	try {
		unzipped = unzipSync(zipBytes, {
			filter(file) {
				if (matchedKey || rejectedForSize) {
					return false;
				}
				if (videoPathRe.test(file.name)) {
					// 圧縮後のパッケージではなく、ZIPヘッダの展開後サイズで
					// 展開前に拒否する。unzipSync後の検査ではZIP爆弾を防げない。
					if ((file.originalSize ?? Number.POSITIVE_INFINITY) > MAX_VIDEO_PREVIEW_BYTES) {
						rejectedForSize = true;
						return false;
					}
					matchedKey = file.name;
					return true;
				}
				return false;
			},
		});
	} catch {
		return null;
	}
	if (!matchedKey) {
		return null;
	}
	const video = unzipped[matchedKey] ?? null;
	return video && video.byteLength <= MAX_VIDEO_PREVIEW_BYTES ? video : null;
}

/// R2から取得したZIPをまるごとメモリ展開するのはピークメモリも計算量も大きいため、
/// 一度展開した動画バイト列をエッジのCache APIに載せて使い回す(#3)。同じ動画に対する
/// <video>タグからの複数回のRangeリクエストが、毎回R2フェッチ+unzipをやり直さずに
/// 済むようにする(初回のみR2+unzipのコストを払う)。Range処理自体はここでは行わず
/// 常に「展開済みの動画全体」を返す(呼び出し元がparseRangeHeaderでスライスする)。
export async function getCachedExtractedVideo(env: Env, objectKey: string): Promise<Uint8Array | null> {
	const cache = caches.default;
	// R2のオブジェクトキーをそのままキャッシュキーにする、実在しないhttps URLで
	// (Cache APIはRequest/URLをキーにする必要があるための便宜上のもの)。
	const cacheKey = new Request(`https://review-video-cache.internal/${encodeURIComponent(objectKey)}`);

	const cached = await cache.match(cacheKey);
	if (cached) {
		return new Uint8Array(await cached.arrayBuffer());
	}

	const object = await env.STORE_BUCKET.get(objectKey);
	if (!object) {
		return null;
	}
	if (object.size > MAX_PREVIEW_ARCHIVE_BYTES) {
		return null;
	}
	const zipBytes = new Uint8Array(await object.arrayBuffer());
	const video = extractVideoEntry(zipBytes);
	if (!video) {
		return null;
	}

	await cache.put(
		cacheKey,
		new Response(video, {
			headers: {
				"content-type": "video/mp4",
				"content-length": video.byteLength.toString(),
				"cache-control": "private, max-age=3600",
			},
		}),
	);
	return video;
}
