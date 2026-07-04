import { defineConfig } from '@playwright/test';

export default defineConfig({
  // Run tests in parallel on CI, but limit workers to prevent CPU throttling
  fullyParallel: true,
  workers: process.env.CI ? 2 : undefined, 
  retries: process.env.CI ? 2 : 0, 
  use: {
    trace: 'on-first-retry',
  },
  // Give CI longer default timeouts since it runs 2x-3x slower than local machines
  timeout: process.env.CI ? 180000 : 60000, 
  expect: {
    timeout: process.env.CI ? 20000 : 9000,
  },
});
