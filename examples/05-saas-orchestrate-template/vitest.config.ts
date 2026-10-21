import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Run in jsdom/node environment (not CF workers pool) so tests are fast
    // and don't need wrangler.  D1 is stubbed via tests/helpers.ts.
    environment: "node",
    globals: false,
    include: ["tests/**/*.test.ts"],
    // Enable Web Crypto API polyfill (needed for HMAC tests in Node < 19)
    setupFiles: [],
  },
  resolve: {
    // Allow .js extension imports from TypeScript source (bundler style)
    conditions: ["import", "default"],
  },
});
