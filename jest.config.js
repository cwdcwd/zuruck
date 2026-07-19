module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  testMatch: ['**/*.test.ts'],
  // Resolve TypeScript sources before any stale compiled .js sitting next to
  // them (tsc emits alongside sources here). Without this, `require`/`import`
  // of '../lib/...' picks up an out-of-date .js and tests silently run against
  // old code. (Review finding — build artifacts shadowing sources.)
  moduleFileExtensions: ['ts', 'tsx', 'js', 'mjs', 'json', 'node'],
  transform: {
    '^.+\\.tsx?$': 'ts-jest'
  },
  setupFilesAfterEnv: ['aws-cdk-lib/testhelpers/jest-autoclean'],
};
