/**
 * Client configuration for the restic S3 backup system.
 *
 * Each client represents a machine (or group of machines) that will
 * back up to a dedicated prefix in the shared S3 bucket.
 *
 * To add a new client:
 *  1. Add an entry to BASE_CLIENTS below, or — for a non-guessable
 *     (suffixed) name — to the git-ignored clients.local.json
 *  2. Run `cdk deploy` to create the IAM user, SSM parameter, and policies
 *  3. Follow the client-setup-guide.md to configure the client machine
 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

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
 * Optional, git-ignored file of additional clients, merged into CLIENTS.
 *
 * This repo is public. Clients whose names carry a non-guessable suffix
 * (security-review S9 mitigation (a)) belong here, NOT in the array below —
 * committing a suffixed name publishes it and defeats the mitigation.
 * Shape: see clients.local.example.json. Override the path with
 * $ZURUCK_CLIENTS_FILE.
 */
export const LOCAL_CLIENTS_FILE =
  process.env.ZURUCK_CLIENTS_FILE || join(__dirname, 'clients.local.json');

/**
 * Load and validate the local clients file. A missing file yields no clients;
 * a present-but-malformed file throws, so a typo fails `cdk synth` loudly
 * instead of silently dropping machines from backup monitoring.
 */
export function loadLocalClients(path: string = LOCAL_CLIENTS_FILE): ClientConfig[] {
  if (!existsSync(path)) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, 'utf8'));
  } catch (err) {
    throw new Error(`${path} is not valid JSON: ${(err as Error).message}`);
  }
  if (!Array.isArray(parsed)) {
    throw new Error(`${path} must contain a JSON array of clients`);
  }
  return parsed.map((entry, i) => {
    if (typeof entry !== 'object' || entry === null) {
      throw new Error(`${path}[${i}] is not an object`);
    }
    const obj = entry as Record<string, unknown>;
    if (typeof obj.name !== 'string') {
      throw new Error(`${path}[${i}].name must be a string`);
    }
    validateClientName(obj.name);
    if (typeof obj.description !== 'string' || obj.description === '') {
      throw new Error(`${path}[${i}].description must be a non-empty string`);
    }
    if (
      obj.freshnessThresholdHours !== undefined &&
      (typeof obj.freshnessThresholdHours !== 'number' || obj.freshnessThresholdHours <= 0)
    ) {
      throw new Error(`${path}[${i}].freshnessThresholdHours must be a positive number`);
    }
    return {
      name: obj.name,
      description: obj.description,
      freshnessThresholdHours: obj.freshnessThresholdHours as number | undefined,
    };
  });
}

/** Merge base + local clients, rejecting duplicate names. */
export function mergeClients(base: ClientConfig[], local: ClientConfig[]): ClientConfig[] {
  const all = [...base, ...local];
  const seen = new Set<string>();
  for (const c of all) {
    if (seen.has(c.name)) throw new Error(`Duplicate client name '${c.name}'`);
    seen.add(c.name);
  }
  return all;
}

/**
 * Clients committed to this repo. Only add names here that are fine to
 * publish; suffixed (non-guessable) names go in clients.local.json.
 */
export const BASE_CLIENTS: ClientConfig[] = [
  {
    name: 'lazybaer02',
    description: 'work laptop',
    freshnessThresholdHours: 24,
  },
  {
    name: 'fenster02',
    description: 'windows desktop',
    freshnessThresholdHours: 48,
  },
];

/**
 * All backup clients: BASE_CLIENTS plus clients.local.json. Add a client to
 * one of them and redeploy.
 */
export const CLIENTS: ClientConfig[] = mergeClients(BASE_CLIENTS, loadLocalClients());
