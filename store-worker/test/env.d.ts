/// <reference types="vite/client" />
import type { Env } from "../src/index";

declare module "cloudflare:test" {
	interface ProvidedEnv extends Env {}
}
