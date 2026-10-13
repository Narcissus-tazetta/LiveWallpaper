import { AwsClient } from "aws4fetch";
import worker, { type Env } from "../../src/index";

interface UploadSlot {
	objectKey: string;
	signedURL: string;
	sizeBytes: number;
	contentType: string;
}
const slots = new Map<string, UploadSlot>();
let uploads = 0;

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);
		if (request.method === "PUT" && url.pathname.startsWith("/__test/upload/")) {
			const slot = slots.get(url.pathname);
			if (!slot) return new Response("Unknown upload slot", { status: 404 });
			const bytes = await request.arrayBuffer();
			if (bytes.byteLength !== slot.sizeBytes || request.headers.get("content-length") !== String(slot.sizeBytes)
				|| request.headers.get("content-type") !== slot.contentType) {
				return new Response("Upload size or content type mismatch", { status: 400 });
			}
			// Recompute against the original R2 host: the loopback address only replaces
			// transport, while the production Worker still generates the signed request.
			const original = new URL(slot.signedURL);
			if (!original.searchParams.get("X-Amz-SignedHeaders")?.split(";").includes("content-length")) {
				return new Response("Upload size is not signed", { status: 403 });
			}
			const expected = original.searchParams.get("X-Amz-Signature");
			const datetime = original.searchParams.get("X-Amz-Date")!;
			original.searchParams.delete("X-Amz-Signature");
			const signer = new AwsClient({ accessKeyId: env.R2_ACCESS_KEY_ID, secretAccessKey: env.R2_SECRET_ACCESS_KEY, service: "s3", region: "auto" });
			const signed = await signer.sign(new Request(original, { method: "PUT", headers: { "content-length": String(bytes.byteLength) } }), {
				aws: { signQuery: true, allHeaders: true, datetime },
			});
			if (new URL(signed.url).searchParams.get("X-Amz-Signature") !== expected) {
				return new Response("Invalid upload signature", { status: 403 });
			}
			await env.STORE_BUCKET.put(slot.objectKey, bytes, { httpMetadata: { contentType: slot.contentType } });
			slots.delete(url.pathname);
			uploads++;
			return new Response(null, { status: 200 });
		}
		if (request.method === "GET" && url.pathname === "/__test/stats") {
			return Response.json({ uploads, pendingUploads: slots.size });
		}
		if (request.method === "POST" && url.pathname === "/upload-url") {
			const body = await request.clone().json() as { sizeBytes: number; contentType: string };
			const response = await worker.fetch(request, env, ctx);
			if (!response.ok) return response;
			const slot = await response.json() as { objectKey: string; uploadURL: string };
			const path = `/__test/upload/${crypto.randomUUID()}`;
			slots.set(path, {
				objectKey: slot.objectKey, signedURL: slot.uploadURL,
				sizeBytes: body.sizeBytes, contentType: body.contentType,
			});
			return Response.json({ ...slot, uploadURL: new URL(path, url.origin).href });
		}
		return worker.fetch(request, env, ctx);
	},
} satisfies ExportedHandler<Env>;
