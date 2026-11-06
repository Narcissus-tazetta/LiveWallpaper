import { REPORT_THRESHOLD } from "./constants";
import { notifyReport } from "./email";
import type { Env } from "./env";
import { clientIP, errorResponse, jsonResponse } from "./http";
import { checkRateLimit } from "./rate-limit";

interface ReportRequest {
	entryId?: string;
	reason?: string;
}

export async function handleReport(request: Request, env: Env): Promise<Response> {
	if (!(await checkRateLimit(env, "report", request))) {
		return errorResponse("too many requests", 429);
	}

	let body: ReportRequest;
	try {
		body = await request.json();
	} catch {
		return errorResponse("invalid JSON body");
	}
	const { entryId, reason } = body;
	if (!entryId) {
		return errorResponse("missing entryId");
	}

	const entry = await env.STORE_DB.prepare(
		"SELECT title, report_count FROM store_entries WHERE id = ? AND status = 'published'",
	)
		.bind(entryId)
		.first<{ title: string; report_count: number }>();
	if (!entry) {
		return errorResponse("entry not found", 404);
	}

	const reporterIP = clientIP(request);
	const insertResult = await env.STORE_DB.prepare(
		`INSERT INTO store_reports (entry_id, reason, reporter_ip, reported_at)
		 VALUES (?, ?, ?, ?) ON CONFLICT(entry_id, reporter_ip) DO NOTHING`,
	)
		.bind(entryId, reason ?? null, reporterIP, new Date().toISOString())
		.run();
	if (insertResult.meta.changes !== 1) {
		// 同じ通報者からの重複通報は黙って現在の件数を返す(多重投票で閾値を
		// 越えさせられないようにする)。
		return jsonResponse({ ok: true, reportCount: entry.report_count });
	}

	await env.STORE_DB.prepare(
		`UPDATE store_entries
		 SET report_count = report_count + 1,
		     status = CASE WHEN report_count + 1 >= ? THEN 'pending' ELSE status END
		 WHERE id = ? AND status IN ('published', 'pending')`,
	)
		.bind(REPORT_THRESHOLD, entryId)
		.run();
	const updated = await env.STORE_DB.prepare("SELECT report_count, status FROM store_entries WHERE id = ?")
		.bind(entryId)
		.first<{ report_count: number; status: string }>();
	const newCount = updated?.report_count ?? entry.report_count;
	const hidden = updated?.status === "pending";

	await notifyReport(env, entryId, entry.title, reason ?? null, newCount, hidden);

	return jsonResponse({ ok: true, reportCount: newCount });
}
