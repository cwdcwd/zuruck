/**
 * Client configuration for the restic S3 backup system.
 *
 * Each client represents a machine (or group of machines) that will
 * back up to a dedicated prefix in the shared S3 bucket.
 *
 * To add a new client:
 *  1. Add an entry to the CLIENTS array below
 *  2. Run `cdk deploy` to create the IAM user, SSM parameter, and policies
 *  3. Follow the client-setup-guide.md to configure the client machine
 */
export interface ClientConfig {
  /**
   * Unique identifier for the client. Used as:
   *  - S3 prefix: s3://bucket/{name}/
   *  - IAM user name: restic-{name}
   *  - SSM parameter: /zuruck/restic/{name}/master-password
   */
  readonly name: string;

  /**
   * Human-readable description of the client (e.g., "Production web server").
   */
  readonly description: string;

  /**
   * Maximum number of hours without a backup before an alarm fires.
   * Defaults to 24 if not specified.
   */
  readonly freshnessThresholdHours?: number;
}

/**
 * Default freshness threshold (hours) — alarm fires if no backup
 * activity is detected within this window.
 */
export const DEFAULT_FRESHNESS_THRESHOLD_HOURS = 24;

/**
 * Canonical S3 prefix for a client. Defined once so IAM, monitoring, secrets,
 * docs, and tests can never drift.
 */
export const clientPrefix = (name: string): string => `${name}/`;

/**
 * Canonical SSM parameter name for a client's master restic password.
 */
export const clientMasterPasswordParameterName = (name: string): string =>
  `/zuruck/restic/${name}/master-password`;

/**
 * Allowed shape for `ClientConfig.name`. Rejects path traversal, casing
 * surprises, and anything that would break the IAM policy ARN templates.
 * (Security-review finding I3.)
 */
const CLIENT_NAME_PATTERN = /^[a-z][a-z0-9-]{1,32}$/;

export function validateClientName(name: string): void {
  if (!CLIENT_NAME_PATTERN.test(name)) {
    throw new Error(
      `Invalid client name '${name}': must match /^[a-z][a-z0-9-]{1,32}$/. ` +
        `Names are used in IAM ARNs, S3 prefixes, and SSM parameter paths.`,
    );
  }
}

/**
 * All backup clients. Add new clients here and redeploy.
 */
export const CLIENTS: ClientConfig[] = [
  {
    name: 'alpha',
    description: 'Alpha production server',
    freshnessThresholdHours: 24,
  },
  {
    name: 'bravo',
    description: 'Bravo staging server',
    freshnessThresholdHours: 48,
  },
];
