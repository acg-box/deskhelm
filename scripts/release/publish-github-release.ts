#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  createReadStream,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';

import {
  compareStableVersions,
  formatStableVersion,
  isRecord,
  parseJson,
  parseStableTag,
  parseStableVersion,
  requireBoolean,
  requirePositiveInteger,
  requirePinnedNode,
  requireString,
  type StableVersion,
} from './release-contract.ts';

const canonicalRepository = 'acg-box/deskhelm';
const archiveName = 'deskhelm-aarch64-apple-darwin.zip';
const appcastName = 'appcast.xml';
const checksumName = `${archiveName}.sha256`;
const assetNames = [archiveName, appcastName, checksumName] as const;
const apiVersion = '2026-03-10';
const maxApiBodyBytes = 2 * 1024 * 1024;
const maxAssetBytes = 512 * 1024 * 1024;
const maxReleasePages = 20;
const maxAssetPages = 10;
const perPage = 100;
const requestTimeoutMilliseconds = 30_000;
const uploadTimeoutMilliseconds = 5 * 60_000;
const maxSafeAttempts = 4;
const maxRetryDelayMilliseconds = 30_000;
const lowercaseCommitPattern = /^[0-9a-f]{40}$/u;

interface ApiRequest {
  readonly method: 'GET' | 'POST' | 'PATCH' | 'DELETE';
  readonly path: string;
  readonly headers?: Readonly<Record<string, string>>;
  readonly body?: string;
  readonly bodyFile?: {
    readonly path: string;
    readonly size: number;
  };
  readonly origin?: 'api' | 'uploads';
  readonly timeoutMilliseconds?: number;
  readonly maxBytes: number;
}

export interface ApiResponse {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: Uint8Array;
}

export interface Transport {
  request(request: ApiRequest): Promise<ApiResponse>;
}

export interface ExecResult {
  readonly status: number;
  readonly stdout: string;
  readonly stderr: string;
  readonly timedOut: boolean;
}

export type Exec = (
  command: string,
  arguments_: readonly string[],
  options: {
    readonly timeoutMilliseconds: number;
    readonly environment?: NodeJS.ProcessEnv;
  },
) => ExecResult;

export type Sleep = (milliseconds: number) => Promise<void>;

export interface PublisherConfig {
  readonly repository: string;
  readonly releaseCommit: string;
  readonly tag: string;
  readonly versionText: string;
  readonly sparkleVersion: string;
  readonly inputDirectory: string;
  readonly artifactValidator: string;
  readonly sparklePublicKey: string;
  readonly githubToken?: string;
  readonly githubSha: string;
  readonly dryRun: boolean;
}

interface Release {
  readonly id: number;
  readonly tagName: string;
  readonly draft: boolean;
  readonly prerelease: boolean;
  readonly htmlUrl: string;
}

interface ReleaseAsset {
  readonly id: number;
  readonly name: string;
  readonly state: string;
  readonly size: number;
  readonly browserDownloadUrl: string;
  readonly digest: string | null;
}

interface ReleaseScan {
  readonly releases: readonly Release[];
  readonly sameTag?: Release;
  readonly highestStableVersion?: StableVersion;
}

class PublishError extends Error {}

class MutationUncertainError extends PublishError {}

function requireEnvironment(name: string): string {
  const value = process.env[name]?.trim();
  if (value === undefined || value.length === 0) {
    throw new PublishError(`Missing required environment variable: ${name}.`);
  }
  return value;
}

function optionalEnvironment(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value === undefined || value.length === 0 ? undefined : value;
}

function readPublicKey(path: string): string {
  let value: string;
  try {
    value = readFileSync(path, 'utf8').trim();
  } catch (error: unknown) {
    throw new PublishError(`Cannot read Sparkle public key file: ${path}`, { cause: error });
  }
  const decoded = Buffer.from(value, 'base64');
  if (
    value.length === 0 ||
    decoded.length !== 32 ||
    decoded.toString('base64').replace(/=+$/u, '') !== value.replace(/=+$/u, '')
  ) {
    throw new PublishError('Sparkle public key must be canonical base64 for 32 bytes.');
  }
  return value;
}

function parseConfig(arguments_: readonly string[]): PublisherConfig {
  if (arguments_.some((argument) => argument !== '--dry-run')) {
    throw new PublishError('Usage: publish-github-release.ts [--dry-run]');
  }
  const dryRun = arguments_.includes('--dry-run');
  const scriptRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const tag = requireEnvironment('DESKHELM_RELEASE_TAG');
  const versionText = requireEnvironment('DESKHELM_RELEASE_VERSION');
  const inputDirectory = resolve(
    optionalEnvironment('DESKHELM_RELEASE_INPUT_DIR') ?? join(scriptRoot, 'artifacts'),
  );
  const publicKeyPath = resolve(
    optionalEnvironment('DESKHELM_SPARKLE_PUBLIC_KEY_FILE') ??
      join(scriptRoot, 'script/release/sparkle-public-ed-key.txt'),
  );
  const githubToken = optionalEnvironment('GH_TOKEN');
  if (!dryRun && githubToken === undefined) {
    throw new PublishError('Missing required environment variable: GH_TOKEN.');
  }
  return {
    repository: requireEnvironment('GITHUB_REPOSITORY'),
    releaseCommit: requireEnvironment('DESKHELM_RELEASE_COMMIT'),
    tag,
    versionText,
    sparkleVersion: requireEnvironment('DESKHELM_SPARKLE_VERSION'),
    inputDirectory,
    artifactValidator: resolve(
      optionalEnvironment('DESKHELM_ARTIFACT_VALIDATOR_BIN') ??
        join(scriptRoot, 'script/release/validate-release-artifacts.py'),
    ),
    sparklePublicKey: readPublicKey(publicKeyPath),
    ...(githubToken === undefined ? {} : { githubToken }),
    githubSha: requireEnvironment('GITHUB_SHA'),
    dryRun,
  };
}

export async function readBoundedBody(response: Response, maxBytes: number): Promise<Uint8Array> {
  const declaredLength = response.headers.get('content-length');
  if (
    declaredLength !== null &&
    (!/^(0|[1-9][0-9]*)$/u.test(declaredLength) || BigInt(declaredLength) > BigInt(maxBytes))
  ) {
    throw new PublishError(`GitHub response exceeds the ${String(maxBytes)} byte limit.`);
  }
  if (response.body === null) {
    return new Uint8Array();
  }
  const chunks: Uint8Array[] = [];
  let length = 0;
  const reader = response.body.getReader();
  while (true) {
    // The stream must be consumed sequentially to enforce the cumulative byte limit.
    // oxlint-disable-next-line eslint/no-await-in-loop
    const result = await reader.read();
    if (result.done) {
      break;
    }
    const chunkValue: unknown = result.value;
    if (!(chunkValue instanceof Uint8Array)) {
      throw new PublishError('GitHub response stream returned a non-byte chunk.');
    }
    const chunk = chunkValue;
    length += chunk.length;
    if (length > maxBytes) {
      throw new PublishError(`GitHub response exceeds the ${String(maxBytes)} byte limit.`);
    }
    chunks.push(chunk);
  }
  const body = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.length;
  }
  return body;
}

export class FetchTransport implements Transport {
  readonly #token: string;

  constructor(token: string) {
    this.#token = token;
  }

  async request(request: ApiRequest): Promise<ApiResponse> {
    const body =
      request.bodyFile === undefined
        ? request.body
        : Readable.toWeb(createReadStream(request.bodyFile.path));
    const response = await fetch(
      `${request.origin === 'uploads' ? 'https://uploads.github.com' : 'https://api.github.com'}/${request.path}`,
      {
        method: request.method,
        headers: {
          Accept: 'application/vnd.github+json',
          Authorization: `Bearer ${this.#token}`,
          'User-Agent': 'DeskHelm-release-publisher',
          'X-GitHub-Api-Version': apiVersion,
          ...(request.body === undefined ? {} : { 'Content-Type': 'application/json' }),
          ...(request.bodyFile === undefined
            ? {}
            : {
                'Content-Length': String(request.bodyFile.size),
                'Content-Type': 'application/octet-stream',
              }),
          ...request.headers,
        },
        ...(body === undefined ? {} : { body }),
        ...(request.bodyFile === undefined ? {} : { duplex: 'half' }),
        signal: AbortSignal.timeout(request.timeoutMilliseconds ?? requestTimeoutMilliseconds),
      },
    );
    const headers: Record<string, string> = {};
    for (const [name, value] of response.headers) {
      headers[name.toLowerCase()] = value;
    }
    return {
      status: response.status,
      headers,
      body: await readBoundedBody(response, request.maxBytes),
    };
  }
}

const defaultExec: Exec = (command, arguments_, options) => {
  const result = spawnSync(command, arguments_, {
    encoding: 'utf8',
    env: options.environment,
    shell: false,
    timeout: options.timeoutMilliseconds,
  });
  return {
    status: result.status ?? 1,
    stdout: result.stdout,
    stderr: result.stderr,
    timedOut: result.error?.name === 'ETIMEDOUT',
  };
};

const defaultSleep: Sleep = async (milliseconds) => {
  await new Promise<void>((resolvePromise) => {
    setTimeout(resolvePromise, milliseconds);
  });
};

function retryDelay(response: ApiResponse, attempt: number): number {
  const retryAfter = response.headers['retry-after'];
  if (retryAfter !== undefined) {
    if (/^[0-9]+$/u.test(retryAfter)) {
      return Math.min(Number(retryAfter) * 1000, maxRetryDelayMilliseconds);
    }
    const date = Date.parse(retryAfter);
    if (!Number.isNaN(date)) {
      return Math.min(Math.max(date - Date.now(), 0), maxRetryDelayMilliseconds);
    }
  }
  return Math.min(2 ** attempt * 1000, maxRetryDelayMilliseconds);
}

function responseText(response: ApiResponse): string {
  return new TextDecoder('utf8', { fatal: true }).decode(response.body);
}

function isRetryableStatus(status: number): boolean {
  return status === 429 || status >= 500;
}

function validateRelease(value: unknown, source: string): Release {
  if (!isRecord(value)) {
    throw new PublishError(`${source} must be an object.`);
  }
  return {
    id: requirePositiveInteger(value, 'id', source),
    tagName: requireString(value, 'tag_name', source),
    draft: requireBoolean(value, 'draft', source),
    prerelease: requireBoolean(value, 'prerelease', source),
    htmlUrl: requireString(value, 'html_url', source),
  };
}

function validateAsset(value: unknown, source: string): ReleaseAsset {
  if (!isRecord(value)) {
    throw new PublishError(`${source} must be an object.`);
  }
  const size = value.size;
  if (typeof size !== 'number' || !Number.isSafeInteger(size) || size < 0) {
    throw new PublishError(`${source}.size must be a non-negative safe integer.`);
  }
  const digest = value.digest;
  if (digest !== null && typeof digest !== 'string') {
    throw new PublishError(`${source}.digest must be a string or null.`);
  }
  return {
    id: requirePositiveInteger(value, 'id', source),
    name: requireString(value, 'name', source),
    state: requireString(value, 'state', source),
    size,
    browserDownloadUrl: requireString(value, 'browser_download_url', source),
    digest,
  };
}

// GitHub retries, pagination, deletion, and byte downloads are intentionally sequential.
// oxlint-disable eslint/no-await-in-loop
export class Publisher {
  readonly #config: PublisherConfig;
  readonly #transport: Transport;
  readonly #exec: Exec;
  readonly #sleep: Sleep;
  readonly #artifacts: Readonly<Record<(typeof assetNames)[number], string>>;
  readonly #version: StableVersion;

  constructor(config: PublisherConfig, transport: Transport, exec: Exec, sleep: Sleep) {
    this.#config = config;
    this.#transport = transport;
    this.#exec = exec;
    this.#sleep = sleep;
    const version = parseStableVersion(config.versionText);
    const tagVersion = parseStableTag(config.tag);
    if (
      version === undefined ||
      tagVersion === undefined ||
      compareStableVersions(version, tagVersion) !== 0
    ) {
      throw new PublishError('Release tag and version must match stable SemVer vX.Y.Z and X.Y.Z.');
    }
    this.#version = version;
    if (config.repository !== canonicalRepository) {
      throw new PublishError(`GITHUB_REPOSITORY must be ${canonicalRepository}.`);
    }
    if (
      !lowercaseCommitPattern.test(config.releaseCommit) ||
      config.githubSha !== config.releaseCommit
    ) {
      throw new PublishError('GITHUB_SHA must match the full lowercase release commit.');
    }
    this.#artifacts = {
      [archiveName]: join(config.inputDirectory, archiveName),
      [appcastName]: join(config.inputDirectory, appcastName),
      [checksumName]: join(config.inputDirectory, checksumName),
    };
    for (const [name, path] of Object.entries(this.#artifacts)) {
      let size: number;
      try {
        size = statSync(path).size;
      } catch (error: unknown) {
        throw new PublishError(`Cannot inspect release artifact ${name}.`, { cause: error });
      }
      if (size <= 0 || size > maxAssetBytes) {
        throw new PublishError(
          `Release artifact ${name} must be 1-${String(maxAssetBytes)} bytes.`,
        );
      }
    }
  }

  async #safeRequest(
    path: string,
    maxBytes = maxApiBodyBytes,
    headers: Readonly<Record<string, string>> = {},
  ): Promise<ApiResponse> {
    for (let attempt = 0; attempt < maxSafeAttempts; attempt += 1) {
      let response: ApiResponse;
      try {
        response = await this.#transport.request({
          method: 'GET',
          path,
          headers,
          maxBytes,
        });
      } catch (error: unknown) {
        if (attempt === maxSafeAttempts - 1) {
          throw new PublishError(`GitHub GET ${path} exhausted its retry bound.`, {
            cause: error,
          });
        }
        await this.#sleep(Math.min(2 ** attempt * 1000, maxRetryDelayMilliseconds));
        continue;
      }
      if (!isRetryableStatus(response.status) || attempt === maxSafeAttempts - 1) {
        return response;
      }
      await this.#sleep(retryDelay(response, attempt));
    }
    throw new PublishError('Safe GitHub request exhausted its retry bound.');
  }

  async #jsonGet(path: string): Promise<unknown> {
    const response = await this.#safeRequest(path);
    if (response.status !== 200) {
      throw new PublishError(`GitHub GET ${path} failed with HTTP ${String(response.status)}.`);
    }
    return parseJson(responseText(response), `GitHub GET ${path}`);
  }

  async #mutation(
    method: 'POST' | 'PATCH' | 'DELETE',
    path: string,
    body?: Readonly<Record<string, unknown>>,
  ): Promise<ApiResponse> {
    let response: ApiResponse;
    try {
      response = await this.#transport.request({
        method,
        path,
        maxBytes: maxApiBodyBytes,
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
    } catch (error: unknown) {
      throw new MutationUncertainError(`${method} ${path} had an unknown result.`, {
        cause: error,
      });
    }
    if (isRetryableStatus(response.status)) {
      throw new MutationUncertainError(
        `${method} ${path} had an unknown HTTP ${String(response.status)} result.`,
      );
    }
    if (
      (response.status < 200 || response.status >= 300) &&
      !(method === 'DELETE' && response.status === 404)
    ) {
      throw new PublishError(`${method} ${path} failed with HTTP ${String(response.status)}.`);
    }
    return response;
  }

  #runValidator(artifactRoot: string, release?: Release, assets?: readonly ReleaseAsset[]): void {
    const temporaryRoot =
      release === undefined ? undefined : mkdtempSync(join(tmpdir(), 'deskhelm-release-metadata-'));
    try {
      const validatorArguments = [
        '--archive',
        join(artifactRoot, archiveName),
        '--appcast',
        join(artifactRoot, appcastName),
        '--checksum',
        join(artifactRoot, checksumName),
        '--repository',
        this.#config.repository,
        '--sparkle-public-key',
        this.#config.sparklePublicKey,
        '--sparkle-version',
        this.#config.sparkleVersion,
        '--tag',
        this.#config.tag,
        '--version',
        this.#config.versionText,
        '--verify-appcast-signature',
      ];
      if (release !== undefined && assets !== undefined && temporaryRoot !== undefined) {
        const releasePath = join(temporaryRoot, 'release.json');
        const assetsPath = join(temporaryRoot, 'assets.json');
        writeFileSync(
          releasePath,
          JSON.stringify({
            id: release.id,
            tag_name: release.tagName,
            draft: release.draft,
            prerelease: release.prerelease,
            html_url: release.htmlUrl,
          }),
          'utf8',
        );
        writeFileSync(
          assetsPath,
          JSON.stringify(
            assets.map((asset) => ({
              id: asset.id,
              name: asset.name,
              state: asset.state,
              size: asset.size,
              browser_download_url: asset.browserDownloadUrl,
              digest: asset.digest,
            })),
          ),
          'utf8',
        );
        validatorArguments.push(
          '--release-json',
          releasePath,
          '--assets-json',
          assetsPath,
          '--release-state',
          release.draft ? 'draft' : 'published',
        );
      }
      const result = this.#exec(this.#config.artifactValidator, validatorArguments, {
        timeoutMilliseconds: uploadTimeoutMilliseconds,
      });
      if (result.status !== 0) {
        const detail = result.stderr.trim() || result.stdout.trim() || 'validator failed';
        throw new PublishError(`Release artifact validation failed: ${detail}`);
      }
    } finally {
      if (temporaryRoot !== undefined) {
        rmSync(temporaryRoot, { recursive: true, force: true });
      }
    }
  }

  async #scanReleases(): Promise<ReleaseScan> {
    const releases: Release[] = [];
    let sameTag: Release | undefined;
    let highestStableVersion: StableVersion | undefined;
    for (let page = 1; page <= maxReleasePages; page += 1) {
      const value = await this.#jsonGet(
        `repos/${this.#config.repository}/releases?per_page=${String(perPage)}&page=${String(page)}`,
      );
      if (!Array.isArray(value)) {
        throw new PublishError('GitHub releases response must be an array.');
      }
      for (const [index, item] of value.entries()) {
        const release = validateRelease(item, `releases[${String(index)}]`);
        releases.push(release);
        if (release.tagName === this.#config.tag) {
          if (sameTag !== undefined) {
            throw new PublishError(`GitHub has duplicate releases for ${this.#config.tag}.`);
          }
          sameTag = release;
        }
        if (!release.draft && !release.prerelease) {
          const stableVersion = parseStableTag(release.tagName);
          if (
            stableVersion !== undefined &&
            (highestStableVersion === undefined ||
              compareStableVersions(stableVersion, highestStableVersion) > 0)
          ) {
            highestStableVersion = stableVersion;
          }
        }
      }
      if (value.length < perPage) {
        return {
          releases,
          ...(sameTag === undefined ? {} : { sameTag }),
          ...(highestStableVersion === undefined ? {} : { highestStableVersion }),
        };
      }
    }
    throw new PublishError(
      `GitHub release pagination exceeded ${String(maxReleasePages * perPage)} records.`,
    );
  }

  #validateNextVersion(scan: ReleaseScan): void {
    if (
      scan.highestStableVersion !== undefined &&
      compareStableVersions(this.#version, scan.highestStableVersion) <= 0
    ) {
      throw new PublishError(
        `Release version ${this.#config.versionText} must be higher than v${formatStableVersion(scan.highestStableVersion)}.`,
      );
    }
  }

  async #validateRemoteSource(): Promise<void> {
    const encodedTag = encodeURIComponent(this.#config.tag);
    const refValue = await this.#jsonGet(
      `repos/${this.#config.repository}/git/ref/tags/${encodedTag}`,
    );
    if (!isRecord(refValue) || !isRecord(refValue.object)) {
      throw new PublishError('Remote release ref metadata is invalid.');
    }
    if (refValue.object.type !== 'tag') {
      throw new PublishError('Remote release ref must point to an annotated tag object.');
    }
    const tagObjectSha = requireString(refValue.object, 'sha', 'remote tag ref object');
    if (!lowercaseCommitPattern.test(tagObjectSha)) {
      throw new PublishError('Remote annotated tag object SHA is invalid.');
    }
    const tagValue = await this.#jsonGet(
      `repos/${this.#config.repository}/git/tags/${tagObjectSha}`,
    );
    if (!isRecord(tagValue) || !isRecord(tagValue.object)) {
      throw new PublishError('Remote annotated tag metadata is invalid.');
    }
    if (
      tagValue.tag !== this.#config.tag ||
      tagValue.object.type !== 'commit' ||
      tagValue.object.sha !== this.#config.releaseCommit
    ) {
      throw new PublishError('Remote annotated tag changed after source validation.');
    }
    const compareValue = await this.#jsonGet(
      `repos/${this.#config.repository}/compare/${this.#config.releaseCommit}...main`,
    );
    if (
      !isRecord(compareValue) ||
      !isRecord(compareValue.merge_base_commit) ||
      compareValue.merge_base_commit.sha !== this.#config.releaseCommit
    ) {
      throw new PublishError('Release commit is no longer reachable from canonical main.');
    }
  }

  #validateSameTagRelease(release: Release, draft: boolean): void {
    if (release.tagName !== this.#config.tag || release.draft !== draft || release.prerelease) {
      throw new PublishError('Same-tag GitHub release metadata is invalid.');
    }
  }

  async #createDraft(): Promise<Release> {
    try {
      const response = await this.#mutation('POST', `repos/${this.#config.repository}/releases`, {
        tag_name: this.#config.tag,
        target_commitish: this.#config.releaseCommit,
        name: `DeskHelm ${this.#config.tag}`,
        draft: true,
        prerelease: false,
        generate_release_notes: true,
      });
      return validateRelease(
        parseJson(responseText(response), 'GitHub create release'),
        'created release',
      );
    } catch (error: unknown) {
      const release = (await this.#scanReleases()).sameTag;
      if (release === undefined) {
        throw error;
      }
      this.#validateSameTagRelease(release, true);
      return release;
    }
  }

  async #fetchAssets(releaseId: number): Promise<readonly ReleaseAsset[]> {
    const assets: ReleaseAsset[] = [];
    const ids = new Set<number>();
    const names = new Set<string>();
    for (let page = 1; page <= maxAssetPages; page += 1) {
      const value = await this.#jsonGet(
        `repos/${this.#config.repository}/releases/${String(releaseId)}/assets?per_page=${String(perPage)}&page=${String(page)}`,
      );
      if (!Array.isArray(value)) {
        throw new PublishError('GitHub release assets response must be an array.');
      }
      for (const [index, item] of value.entries()) {
        const asset = validateAsset(item, `assets[${String(index)}]`);
        if (ids.has(asset.id) || names.has(asset.name)) {
          throw new PublishError(`Duplicate GitHub release asset: ${asset.name}.`);
        }
        ids.add(asset.id);
        names.add(asset.name);
        assets.push(asset);
      }
      if (value.length < perPage) {
        return assets;
      }
    }
    throw new PublishError(
      `GitHub asset pagination exceeded ${String(maxAssetPages * perPage)} records.`,
    );
  }

  async #deleteAsset(releaseId: number, asset: ReleaseAsset): Promise<void> {
    try {
      await this.#mutation(
        'DELETE',
        `repos/${this.#config.repository}/releases/assets/${String(asset.id)}`,
      );
    } catch (error: unknown) {
      if (!(error instanceof MutationUncertainError)) {
        throw error;
      }
      const remaining = await this.#fetchAssets(releaseId);
      if (remaining.some((candidate) => candidate.id === asset.id)) {
        throw error;
      }
    }
  }

  async #waitForUploadedAsset(releaseId: number, name: string, size: number): Promise<boolean> {
    for (let attempt = 0; attempt < maxSafeAttempts; attempt += 1) {
      const converged = (await this.#fetchAssets(releaseId)).some(
        (asset) => asset.name === name && asset.size === size && asset.state === 'uploaded',
      );
      if (converged) {
        return true;
      }
      if (attempt < maxSafeAttempts - 1) {
        await this.#sleep(Math.min(2 ** attempt * 1000, maxRetryDelayMilliseconds));
      }
    }
    return false;
  }

  async #repairDraftAssets(release: Release): Promise<void> {
    for (const asset of await this.#fetchAssets(release.id)) {
      await this.#deleteAsset(release.id, asset);
    }
    for (const name of assetNames) {
      const path = this.#artifacts[name];
      const size = statSync(path).size;
      try {
        const response = await this.#transport.request({
          method: 'POST',
          origin: 'uploads',
          path:
            `repos/${this.#config.repository}/releases/${String(release.id)}/assets?` +
            `name=${encodeURIComponent(name)}`,
          bodyFile: { path, size },
          maxBytes: maxApiBodyBytes,
          timeoutMilliseconds: uploadTimeoutMilliseconds,
        });
        if (response.status !== 201) {
          if (isRetryableStatus(response.status)) {
            throw new MutationUncertainError(
              `GitHub asset upload had an unknown HTTP ${String(response.status)} result.`,
            );
          }
          throw new PublishError(
            `GitHub asset upload failed with HTTP ${String(response.status)}.`,
          );
        }
      } catch (error: unknown) {
        if (error instanceof PublishError && !(error instanceof MutationUncertainError)) {
          throw error;
        }
        if (!(error instanceof MutationUncertainError)) {
          const converged = await this.#waitForUploadedAsset(release.id, name, size);
          if (!converged) {
            throw new MutationUncertainError(
              `GitHub asset upload for ${name} had an unknown result and did not converge.`,
              { cause: error },
            );
          }
        } else {
          const converged = await this.#waitForUploadedAsset(release.id, name, size);
          if (!converged) {
            throw error;
          }
        }
      }
    }
    await this.#waitForDraftAssets(release);
  }

  #validateExactAssets(release: Release, assets: readonly ReleaseAsset[]): void {
    if (
      assets.length !== assetNames.length ||
      assetNames.some((name) => !assets.some((asset) => asset.name === name))
    ) {
      throw new PublishError('Release must contain exactly the canonical artifact triplet.');
    }
    const releaseUrlPrefix = `https://github.com/${this.#config.repository}/releases/tag/`;
    if (!release.htmlUrl.startsWith(releaseUrlPrefix)) {
      throw new PublishError('Release URL is not canonical.');
    }
    const releaseSlug = release.htmlUrl.slice(releaseUrlPrefix.length);
    if (
      releaseSlug !== this.#config.tag &&
      (release.draft ? !/^untagged-[A-Za-z0-9][A-Za-z0-9._-]*$/u.test(releaseSlug) : true)
    ) {
      throw new PublishError('Release URL does not use the canonical tag or safe draft slug.');
    }
    for (const asset of assets) {
      if (asset.state !== 'uploaded' || asset.size <= 0 || asset.size > maxAssetBytes) {
        throw new PublishError(`Release asset is not safely downloadable: ${asset.name}.`);
      }
      const expectedUrl = `https://github.com/${this.#config.repository}/releases/download/${releaseSlug}/${asset.name}`;
      if (asset.browserDownloadUrl !== expectedUrl) {
        throw new PublishError(`Release asset URL is not canonical: ${asset.name}.`);
      }
      if (typeof asset.digest !== 'string' || !/^sha256:[0-9a-f]{64}$/u.test(asset.digest)) {
        throw new PublishError(`Release asset digest is missing or invalid: ${asset.name}.`);
      }
    }
  }

  #validateAssetDigests(assets: readonly ReleaseAsset[], root: string): void {
    for (const asset of assets) {
      const digest = createHash('sha256')
        .update(readFileSync(join(root, asset.name)))
        .digest('hex');
      if (asset.digest !== `sha256:${digest}`) {
        throw new PublishError(
          `Release asset digest does not match downloaded bytes: ${asset.name}.`,
        );
      }
    }
  }

  async #downloadAssets(
    release: Release,
    assets: readonly ReleaseAsset[],
  ): Promise<{ readonly root: string; readonly cleanup: () => void }> {
    this.#validateExactAssets(release, assets);
    const root = mkdtempSync(join(tmpdir(), 'deskhelm-release-download-'));
    try {
      for (const name of assetNames) {
        const asset = assets.find((candidate) => candidate.name === name);
        if (asset === undefined) {
          throw new PublishError(`Release asset is missing: ${name}.`);
        }
        const response = await this.#safeRequest(
          `repos/${this.#config.repository}/releases/assets/${String(asset.id)}`,
          Math.min(asset.size + 1, maxAssetBytes),
          { Accept: 'application/octet-stream' },
        );
        if (response.status !== 200 || response.body.length !== asset.size) {
          throw new PublishError(`Downloaded release asset has invalid bytes: ${name}.`);
        }
        writeFileSync(join(root, name), response.body);
      }
      return {
        root,
        cleanup: () => rmSync(root, { recursive: true, force: true }),
      };
    } catch (error: unknown) {
      rmSync(root, { recursive: true, force: true });
      throw error;
    }
  }

  async #validateDraftBytes(release: Release): Promise<void> {
    this.#validateSameTagRelease(release, true);
    const assets = await this.#fetchAssets(release.id);
    const download = await this.#downloadAssets(release, assets);
    try {
      for (const name of assetNames) {
        const local = readFileSync(this.#artifacts[name]);
        const remote = readFileSync(join(download.root, name));
        if (!local.equals(remote)) {
          throw new PublishError(`Downloaded draft bytes do not match local artifact: ${name}.`);
        }
      }
      this.#validateAssetDigests(assets, download.root);
      this.#runValidator(download.root, release, assets);
    } finally {
      download.cleanup();
    }
  }

  async #validateDraftRemoteAssets(release: Release): Promise<void> {
    const scan = await this.#scanReleases();
    const refreshed = scan.sameTag;
    if (refreshed === undefined || refreshed.id !== release.id) {
      throw new PublishError('Draft release disappeared or changed identity after upload.');
    }
    await this.#validateDraftBytes(refreshed);
  }

  async #waitForDraftAssets(release: Release): Promise<void> {
    let lastError: unknown;
    for (let attempt = 0; attempt < maxSafeAttempts; attempt += 1) {
      try {
        await this.#validateDraftRemoteAssets(release);
        return;
      } catch (error: unknown) {
        lastError = error;
        if (attempt < maxSafeAttempts - 1) {
          await this.#sleep(Math.min(2 ** attempt * 1000, maxRetryDelayMilliseconds));
        }
      }
    }
    throw new PublishError('Uploaded draft assets did not converge within the retry bound.', {
      cause: lastError,
    });
  }

  async #validatePublicRelease(release: Release): Promise<void> {
    this.#validateSameTagRelease(release, false);
    const assets = await this.#fetchAssets(release.id);
    const download = await this.#downloadAssets(release, assets);
    try {
      this.#validateAssetDigests(assets, download.root);
      this.#runValidator(download.root, release, assets);
    } finally {
      download.cleanup();
    }
  }

  async #publishDraft(release: Release): Promise<void> {
    let uncertainError: MutationUncertainError | undefined;
    try {
      await this.#mutation(
        'PATCH',
        `repos/${this.#config.repository}/releases/${String(release.id)}`,
        {
          draft: false,
          make_latest: 'true',
        },
      );
    } catch (error: unknown) {
      if (!(error instanceof MutationUncertainError)) {
        throw error;
      }
      uncertainError = error;
    }
    const refreshed = (await this.#scanReleases()).sameTag;
    if (refreshed === undefined || refreshed.id !== release.id || refreshed.draft) {
      if (uncertainError !== undefined) {
        throw uncertainError;
      }
      throw new PublishError('Published release disappeared or remained private after PATCH.');
    }
    await this.#validatePublicRelease(refreshed);
  }

  async publish(): Promise<void> {
    this.#runValidator(this.#config.inputDirectory);
    if (this.#config.dryRun) {
      console.log(
        `Dry run passed local validation for ${this.#config.tag}; no GitHub request or mutation was made.`,
      );
      return;
    }

    await this.#validateRemoteSource();
    const initialScan = await this.#scanReleases();
    if (initialScan.sameTag !== undefined && !initialScan.sameTag.draft) {
      await this.#validatePublicRelease(initialScan.sameTag);
      console.log(`Existing public release ${this.#config.tag} and its bytes passed validation.`);
      return;
    }
    this.#validateNextVersion(initialScan);

    const created = initialScan.sameTag === undefined;
    const draft = initialScan.sameTag ?? (await this.#createDraft());
    this.#validateSameTagRelease(draft, true);
    await this.#repairDraftAssets(draft);

    // These source and version reads are intentionally adjacent to the final mutation.
    await this.#validateRemoteSource();
    const finalScan = await this.#scanReleases();
    if (finalScan.sameTag === undefined || finalScan.sameTag.id !== draft.id) {
      throw new PublishError('Draft release changed identity before publication.');
    }
    this.#validateSameTagRelease(finalScan.sameTag, true);
    this.#validateNextVersion(finalScan);

    // Re-read and validate the exact draft bytes after every other publication check.
    await this.#validateDraftBytes(finalScan.sameTag);

    // Publication is the final mutation. Its result and public bytes converge through safe GETs.
    await this.#publishDraft(finalScan.sameTag);
    console.log(
      `${created ? 'Created' : 'Repaired'} and published ${this.#config.tag} as the latest stable release.`,
    );
  }
}
// oxlint-enable eslint/no-await-in-loop

export async function runPublisher(
  config: PublisherConfig,
  dependencies: {
    readonly transport: Transport;
    readonly exec?: Exec;
    readonly sleep?: Sleep;
  },
): Promise<void> {
  await new Publisher(
    config,
    dependencies.transport,
    dependencies.exec ?? defaultExec,
    dependencies.sleep ?? defaultSleep,
  ).publish();
}

async function main(): Promise<void> {
  const config = parseConfig(process.argv.slice(2));
  requirePinnedNode(resolve(dirname(fileURLToPath(import.meta.url)), '../..'));
  const transport =
    config.githubToken === undefined
      ? {
          request(): Promise<ApiResponse> {
            throw new PublishError('Dry-run mode must not make GitHub requests.');
          },
        }
      : new FetchTransport(config.githubToken);
  await runPublisher(config, { transport });
}

if (import.meta.main) {
  try {
    await main();
  } catch (error: unknown) {
    console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
