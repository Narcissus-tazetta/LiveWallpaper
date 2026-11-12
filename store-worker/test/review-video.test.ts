import { deflateSync, zipSync } from "fflate";
import { describe, expect, it } from "vitest";
import { MAX_REVIEW_VIDEO_EXPANDED_BYTES } from "../src/constants";
import { extractVideoEntry } from "../src/review-video";

const NAME = new TextEncoder().encode("content/videos/x.mp4");

function crc32(data: Uint8Array): number {
	let crc = 0xffffffff;
	for (const byte of data) {
		crc ^= byte;
		for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
	}
	return (crc ^ 0xffffffff) >>> 0;
}

/// ローカルヘッダの展開後サイズだけを偽装した1エントリZIP。zipSyncでは作れない。
function zipWithLocalSize(raw: Uint8Array, localSize: number): Uint8Array {
	const compressed = deflateSync(raw);
	const crc = crc32(raw);
	const local = new Uint8Array(30 + NAME.length);
	const lv = new DataView(local.buffer);
	lv.setUint32(0, 0x04034b50, true);
	lv.setUint16(4, 20, true);
	lv.setUint16(8, 8, true);
	lv.setUint32(14, crc, true);
	lv.setUint32(18, compressed.length, true);
	lv.setUint32(22, localSize, true);
	lv.setUint16(26, NAME.length, true);
	local.set(NAME, 30);

	const central = new Uint8Array(46 + NAME.length);
	const cv = new DataView(central.buffer);
	cv.setUint32(0, 0x02014b50, true);
	cv.setUint16(4, 20, true);
	cv.setUint16(6, 20, true);
	cv.setUint16(10, 8, true);
	cv.setUint32(16, crc, true);
	cv.setUint32(20, compressed.length, true);
	cv.setUint32(24, raw.length, true);
	cv.setUint16(28, NAME.length, true);
	central.set(NAME, 46);

	const end = new Uint8Array(22);
	const ev = new DataView(end.buffer);
	ev.setUint32(0, 0x06054b50, true);
	ev.setUint16(8, 1, true);
	ev.setUint16(10, 1, true);
	ev.setUint32(12, central.length, true);
	ev.setUint32(16, local.length + compressed.length, true);

	const out = new Uint8Array(local.length + compressed.length + central.length + end.length);
	out.set(local, 0);
	out.set(compressed, local.length);
	out.set(central, local.length + compressed.length);
	out.set(end, local.length + compressed.length + central.length);
	return out;
}

describe("extractVideoEntry", () => {
	it("extracts a deflated video", () => {
		const video = new Uint8Array(100_000).map((_, i) => i % 251);
		const zip = zipSync({ "content/videos/x.mp4": [video, { level: 6 }], "metadata.json": new Uint8Array(10) });
		expect(extractVideoEntry(zip)).toEqual(video);
	});

	it("extracts a stored (uncompressed) video", () => {
		const video = new Uint8Array(100_000).map((_, i) => i % 241);
		const zip = zipSync({ "content/videos/x.mp4": [video, { level: 0 }] });
		expect(extractVideoEntry(zip)).toEqual(video);
	});

	it("rejects a video whose header declares more than the limit", () => {
		const big = new Uint8Array(MAX_REVIEW_VIDEO_EXPANDED_BYTES + 1);
		expect(extractVideoEntry(zipWithLocalSize(big, big.length))).toBeNull();
	});

	it("rejects a bomb whose local header understates the size", () => {
		const big = new Uint8Array(MAX_REVIEW_VIDEO_EXPANDED_BYTES + 1024 * 1024);
		expect(extractVideoEntry(zipWithLocalSize(big, 0))).toBeNull();
	});
});
