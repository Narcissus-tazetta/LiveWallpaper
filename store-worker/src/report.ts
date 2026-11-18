import { MAX_REPORT_REASON_LENGTH, REPORT_THRESHOLD } from "./constants";
import { notifyReport } from "./email";
import type { Env } from "./env";
import { clientIP, errorResponse, isNonEmptyString, jsonResponse, readJSONObject } from "./http";
import { checkRateLimit } from "./rate-limit";

interface ReportedEntry {
	title: string;
	report_count: number;
	status: string;
}

export async function handleReport(request: Request, env: Env): Promise<Response> {
	if (!(await checkRateLimit(env, "report", request))) {
		return errorResponse("too many requests", 429);
	}

	const body = await readJSONObject(request);
	if (!body) {
		return errorResponse("invalid JSON body");
	}
	const { entryId, reason } = body;
	if (!isNonEmptyString(entryId, 64)) {
		return errorResponse("missing entryId");
	}
	if (
		reason !== undefined &&
		reason !== null &&
		(typeof reason !== "string" || reason.length > MAX_REPORT_REASON_LENGTH)
	) {
		return errorResponse(`reason must be a string of at most ${MAX_REPORT_REASON_LENGTH} characters`);
	}

	// Counting in the same transaction keeps a failed update retryable. changes()
	// refers to the preceding INSERT and is zero for a duplicate report.
	const [inserted, , selected] = await env.STORE_DB.batch<ReportedEntry>([
		env.STORE_DB.prepare(
			`INSERT INTO store_reports (entry_id, reason, reporter_ip, reported_at)
			 SELECT id, ?, ?, ? FROM store_entries WHERE id = ? AND status = 'published'
			 ON CONFLICT(entry_id, reporter_ip) DO NOTHING`,
		).bind(reason ?? null, clientIP(request), new Date().toISOString(), entryId),
		env.STORE_DB.prepare(
			`UPDATE store_entries
			 SET report_count = report_count + 1,
			     status = CASE WHEN report_count + 1 >= ? THEN 'pending' ELSE status END
			 WHERE id = ? AND changes() = 1`,
		).bind(REPORT_THRESHOLD, entryId),
		env.STORE_DB.prepare("SELECT title, report_count, status FROM store_entries WHERE id = ?").bind(entryId),
	]);
	const entry = selected.results[0];
	if (!entry || (inserted.meta.changes === 0 && entry.status !== "published")) {
		return errorResponse("entry not found", 404);
	}
	if (inserted.meta.changes === 1) {
		await notifyReport(env, entryId, entry.title, reason ?? null, entry.report_count, entry.status === "pending");
	}
	return jsonResponse({ ok: true, reportCount: entry.report_count });
}
