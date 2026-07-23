import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
	test: {
		poolOptions: {
			workers: {
				wrangler: { configPath: "./wrangler.toml" },
				// wrangler.toml declares RESEND_API_KEY/ADMIN_KEY as secrets (not present
				// there), so we inject dummy values here for the test environment only.
				miniflare: {
					bindings: {
						ADMIN_KEY: "test-admin-key",
						RESEND_API_KEY: "test-resend-key",
					},
				},
			},
		},
	},
});
