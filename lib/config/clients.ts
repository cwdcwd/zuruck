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
   *  - S3 prefix: s3://bucket/{prefix}/
   *  - IAM user name: restic-{prefix}
   *  - SSM parameter: /zuruck/restic/{prefix}/master-password
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
  // Add more clients as needed:
  // {
  //   name: 'charlie',
  //   description: 'Charlie database server',
  //   freshnessThresholdHours: 12,
  // },
];