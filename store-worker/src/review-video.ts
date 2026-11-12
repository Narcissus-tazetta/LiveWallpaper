import { Unzip, UnzipInflate, UnzipPassThrough } from "fflate";
import { MAX_PREVIEW_ARCHIVE_BYTES, MAX_REVIEW_VIDEO_EXPANDED_BYTES } from "./constants";
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

const PUSH_SLICE_BYTES = 4 * 1024;

/// .lwpkg(ZIP)の中から動画本体(content/videos/<id>.mp4)だけを取り出して返す。
/// Unzipで動画エントリ以外(metadata.json/previews/*.png)は start() せず展開をスキップし、
/// Worker内メモリ使用量を動画本体分だけに抑える。
export function extractVideoEntry(zipBytes: Uint8Array): Uint8Array | null {
	const videoPathRe = /^content\/videos\/[^/]+$/i;
	let matchedKey: string | null = null;
	let rejectedForSize = false;
	let hasError = false;
	const chunks: Uint8Array[] = [];
	let totalExtractedBytes = 0;

	try {
		const unzipper = new Unzip();
		unzipper.register(UnzipInflate);
		// ストア(無圧縮)のエントリも受け付ける。登録しないと start() が例外を投げる。
		unzipper.register(UnzipPassThrough);
		unzipper.onfile = (file) => {
			if (matchedKey || rejectedForSize || hasError) {
				return;
			}
			if (videoPathRe.test(file.name)) {
				if (
					file.originalSize !== undefined &&
					(file.originalSize < 0 || file.originalSize > MAX_REVIEW_VIDEO_EXPANDED_BYTES)
				) {
					rejectedForSize = true;
					return;
				}
				matchedKey = file.name;
				file.ondata = (err, chunk) => {
					if (err) {
						hasError = true;
						chunks.length = 0;
						file.terminate?.();
						return;
					}
					if (rejectedForSize) {
						return;
					}
					if (chunk) {
						totalExtractedBytes += chunk.byteLength;
						if (totalExtractedBytes > MAX_REVIEW_VIDEO_EXPANDED_BYTES) {
							rejectedForSize = true;
							chunks.length = 0;
							file.terminate?.();
							return;
						}
						chunks.push(chunk);
					}
				};
				file.start();
			}
		};
		// ローカルヘッダの originalSize は偽装できる(0 や未設定)。UnzipInflate は1回の push の
		// 出力を1チャンクにまとめるため、ZIP全体を一度に渡すと上限検査の前に数百MBを確保する。
		// 入力を小さく刻めば、上限超過後の確保は入力1スライス分の展開量で済む。
		for (let offset = 0; offset < zipBytes.byteLength && !rejectedForSize && !hasError; offset += PUSH_SLICE_BYTES) {
			const end = Math.min(offset + PUSH_SLICE_BYTES, zipBytes.byteLength);
			unzipper.push(zipBytes.subarray(offset, end), end === zipBytes.byteLength);
		}
	} catch {
		return null;
	}

	if (!matchedKey || rejectedForSize || hasError || totalExtractedBytes === 0) {
		return null;
	}

	const result = new Uint8Array(totalExtractedBytes);
	let offset = 0;
	for (const chunk of chunks) {
		result.set(chunk, offset);
		offset += chunk.byteLength;
	}
	return result;
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
