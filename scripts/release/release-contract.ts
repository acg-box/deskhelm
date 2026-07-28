import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const stableComponentPattern = '(0|[1-9][0-9]{0,127})';
const stableTagPattern = new RegExp(
  `^v${stableComponentPattern}\\.${stableComponentPattern}\\.${stableComponentPattern}$`,
);
const stableVersionPattern = new RegExp(
  `^${stableComponentPattern}\\.${stableComponentPattern}\\.${stableComponentPattern}$`,
);

export type StableVersion = readonly [major: bigint, minor: bigint, patch: bigint];

export function parseStableTag(tag: string): StableVersion | undefined {
  const match = stableTagPattern.exec(tag);
  if (match === null) {
    return undefined;
  }
  const major = match[1];
  const minor = match[2];
  const patch = match[3];
  if (major === undefined || minor === undefined || patch === undefined) {
    return undefined;
  }
  return [BigInt(major), BigInt(minor), BigInt(patch)];
}

export function parseStableVersion(version: string): StableVersion | undefined {
  const match = stableVersionPattern.exec(version);
  if (match === null) {
    return undefined;
  }
  const major = match[1];
  const minor = match[2];
  const patch = match[3];
  if (major === undefined || minor === undefined || patch === undefined) {
    return undefined;
  }
  return [BigInt(major), BigInt(minor), BigInt(patch)];
}

export function compareStableVersions(left: StableVersion, right: StableVersion): number {
  for (const index of [0, 1, 2] as const) {
    if (left[index] < right[index]) {
      return -1;
    }
    if (left[index] > right[index]) {
      return 1;
    }
  }
  return 0;
}

export function formatStableVersion(version: StableVersion): string {
  return version.map((component) => component.toString()).join('.');
}

export function parseJson(text: string, source: string): unknown {
  try {
    const value: unknown = JSON.parse(text);
    return value;
  } catch (error: unknown) {
    throw new Error(`${source} returned invalid JSON.`, { cause: error });
  }
}

export function requirePinnedNode(repositoryRoot: string): void {
  const expected = readFileSync(resolve(repositoryRoot, '.node-version'), 'utf8').trim();
  if (process.version !== `v${expected}`) {
    throw new Error(`Release tooling requires Node.js ${expected}, got ${process.version}.`);
  }
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function requireString(
  record: Record<string, unknown>,
  key: string,
  source: string,
): string {
  const value = record[key];
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`${source}.${key} must be a non-empty string.`);
  }
  return value;
}

export function requireBoolean(
  record: Record<string, unknown>,
  key: string,
  source: string,
): boolean {
  const value = record[key];
  if (typeof value !== 'boolean') {
    throw new Error(`${source}.${key} must be a boolean.`);
  }
  return value;
}

export function requirePositiveInteger(
  record: Record<string, unknown>,
  key: string,
  source: string,
): number {
  const value = record[key];
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${source}.${key} must be a positive safe integer.`);
  }
  return value;
}
