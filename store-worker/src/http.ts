export function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json" },
	});
}

export function errorResponse(message: string, status = 400): Response {
	return jsonResponse({ error: message }, status);
}

export async function readJSONObject(request: Request): Promise<Record<string, unknown> | null> {
	let body: unknown;
	try {
		body = await request.json();
	} catch (error) {
		if (error instanceof SyntaxError) return null;
		throw error;
	}
	return body !== null && typeof body === "object" && !Array.isArray(body) ? (body as Record<string, unknown>) : null;
}

export function isNonEmptyString(value: unknown, maxLength: number): value is string {
	return typeof value === "string" && value.trim().length > 0 && value.length <= maxLength;
}

export function clientIP(request: Request): string {
	return request.headers.get("cf-connecting-ip") ?? "unknown";
}
