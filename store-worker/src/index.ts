import {
	handleAdminDecision,
	handleAdminDelete,
	handleAdminEmailStatus,
	handleAdminReports,
	handleAdminRequests,
	handleAdminResendReview,
} from "./admin";
import { handleCatalog, handleDownload, handleEntry, handleEntryStatus, handleThumbnail } from "./catalog";
import type { Env } from "./env";
import { errorResponse } from "./http";
import { handleReport } from "./report";
import {
	handleAdminReviewDecide,
	handleAdminReviewDownload,
	handleAdminReviewPage,
	handleAdminReviewThumbnail,
	handleAdminReviewVideo,
} from "./review";
import { handleScheduled } from "./scheduled";
import { handleSharePage } from "./share-page";
import { handleSubmit, handleUploadUrl } from "./upload";
import { handleWithdraw } from "./withdraw";

export type { Env } from "./env";

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);
		const { pathname } = url;
		const method = request.method;

		if (method === "POST" && pathname === "/upload-url") {
			return handleUploadUrl(request, env);
		}
		if (method === "POST" && pathname === "/submit") {
			return handleSubmit(request, env, ctx);
		}
		if (method === "GET" && pathname === "/catalog") {
			return handleCatalog(request, env);
		}
		const downloadMatch = pathname.match(/^\/download\/([\w-]+)$/);
		if (method === "GET" && downloadMatch) {
			return handleDownload(request, env, downloadMatch[1]);
		}
		const thumbnailMatch = pathname.match(/^\/thumbnail\/([\w-]+)$/);
		if (method === "GET" && thumbnailMatch) {
			return handleThumbnail(request, env, thumbnailMatch[1]);
		}
		const entryMatch = pathname.match(/^\/entries\/([\w-]+)$/);
		if (method === "GET" && entryMatch) {
			return handleEntry(request, env, entryMatch[1]);
		}
		const sharePageMatch = pathname.match(/^\/w\/([\w-]+)$/);
		if (method === "GET" && sharePageMatch) {
			return handleSharePage(request, env, sharePageMatch[1]);
		}
		const entryStatusMatch = pathname.match(/^\/entries\/([\w-]+)\/status$/);
		if (method === "GET" && entryStatusMatch) {
			return handleEntryStatus(request, env, entryStatusMatch[1]);
		}
		const withdrawMatch = pathname.match(/^\/entries\/([\w-]+)\/withdraw$/);
		if (method === "DELETE" && withdrawMatch) {
			return handleWithdraw(request, env, withdrawMatch[1]);
		}
		if (method === "POST" && pathname === "/report") {
			return handleReport(request, env);
		}
		const adminDeleteMatch = pathname.match(/^\/admin\/entries\/([\w-]+)$/);
		if (method === "DELETE" && adminDeleteMatch) {
			return handleAdminDelete(request, env, adminDeleteMatch[1]);
		}
		if (method === "GET" && pathname === "/admin/reports") {
			return handleAdminReports(request, env);
		}
		const emailStatusMatch = pathname.match(/^\/admin\/email-status\/([\w-]+)$/);
		if (method === "GET" && emailStatusMatch) {
			return handleAdminEmailStatus(request, env, emailStatusMatch[1]);
		}
		if (method === "GET" && pathname === "/admin/requests") {
			return handleAdminRequests(request, env);
		}
		const adminApproveMatch = pathname.match(/^\/admin\/entries\/([\w-]+)\/approve$/);
		if (method === "POST" && adminApproveMatch) {
			return handleAdminDecision(request, env, adminApproveMatch[1], "approve");
		}
		const adminRejectMatch = pathname.match(/^\/admin\/entries\/([\w-]+)\/reject$/);
		if (method === "POST" && adminRejectMatch) {
			return handleAdminDecision(request, env, adminRejectMatch[1], "reject");
		}
		const adminResendReviewMatch = pathname.match(/^\/admin\/entries\/([\w-]+)\/resend-review$/);
		if (method === "POST" && adminResendReviewMatch) {
			return handleAdminResendReview(request, env, ctx, adminResendReviewMatch[1]);
		}
		const reviewDecideMatch = pathname.match(/^\/admin\/review\/([\w-]+)\/decide$/);
		if (method === "POST" && reviewDecideMatch) {
			return handleAdminReviewDecide(request, env, reviewDecideMatch[1]);
		}
		const reviewThumbnailMatch = pathname.match(/^\/admin\/review\/([\w-]+)\/thumbnail$/);
		if (method === "GET" && reviewThumbnailMatch) {
			return handleAdminReviewThumbnail(request, env, reviewThumbnailMatch[1]);
		}
		const reviewVideoMatch = pathname.match(/^\/admin\/review\/([\w-]+)\/video$/);
		if (method === "GET" && reviewVideoMatch) {
			return handleAdminReviewVideo(request, env, reviewVideoMatch[1]);
		}
		const reviewDownloadMatch = pathname.match(/^\/admin\/review\/([\w-]+)\/download$/);
		if (method === "GET" && reviewDownloadMatch) {
			return handleAdminReviewDownload(request, env, reviewDownloadMatch[1]);
		}
		const reviewPageMatch = pathname.match(/^\/admin\/review\/([\w-]+)$/);
		if (method === "GET" && reviewPageMatch) {
			return handleAdminReviewPage(request, env, reviewPageMatch[1]);
		}

		return errorResponse("not found", 404);
	},

	async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
		await handleScheduled(env);
	},
} satisfies ExportedHandler<Env>;
