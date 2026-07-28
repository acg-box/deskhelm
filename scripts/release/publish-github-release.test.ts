import { strictEqual, deepStrictEqual, rejects } from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import {
  runPublisher,
  readBoundedBody,
  type ApiResponse,
  type Exec,
  type PublisherConfig,
  type Transport,
} from './publish-github-release.ts';
import { compareStableVersions, parseStableTag, parseStableVersion } from './release-contract.ts';

const repository = 'acg-box/deskhelm';
const archiveName = 'deskhelm-aarch64-apple-darwin.zip';
const appcastName = 'appcast.xml';
const checksumName = `${archiveName}.sha256`;
const assetNames = [archiveName, appcastName, checksumName] as const;
const commit = 'a'.repeat(40);

interface FakeRelease {
  id: number;
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  html_url: string;
}

interface FakeAsset {
  id: number;
  name: string;
  state: string;
  size: number;
  browser_download_url: string;
  digest: string | null;
  bytes: Uint8Array;
}

function jsonResponse(status: number, value: unknown, headers = {}): ApiResponse {
  return {
    status,
    headers,
    body: new TextEncoder().encode(JSON.stringify(value)),
  };
}

function digest(bytes: Uint8Array): string {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
}

class FakeGitHub implements Transport {
  readonly calls: string[] = [];
  readonly releases: FakeRelease[] = [];
  readonly assets = new Map<number, FakeAsset[]>();
  readonly uploadedBytes: Readonly<Record<string, Uint8Array>>;
  releaseListCalls = 0;
  safeFailures = 0;
  thrownSafeFailures = 0;
  uncertainCreate = false;
  uncertainDelete = false;
  uncertainUpload = false;
  uncertainPatch = false;
  injectRaceOnReleaseListCall?: number;
  mutateAssetOnReleaseListCall?: number;
  corruptAssetAfterPatch = false;

  constructor(uploadedBytes: Readonly<Record<string, Uint8Array>>) {
    this.uploadedBytes = uploadedBytes;
  }

  installUploadedAssets(releaseId: number, slug: string): void {
    this.assets.set(
      releaseId,
      assetNames.map((name, index) => {
        const bytes = this.uploadedBytes[name];
        if (bytes === undefined) {
          throw new Error(`missing fake bytes: ${name}`);
        }
        return {
          id: 1000 + index,
          name,
          state: 'uploaded',
          size: bytes.length,
          browser_download_url: `https://github.com/${repository}/releases/download/${slug}/${name}`,
          digest: digest(bytes),
          bytes,
        };
      }),
    );
  }

  async request(request: {
    readonly method: 'GET' | 'POST' | 'PATCH' | 'DELETE';
    readonly path: string;
    readonly headers?: Readonly<Record<string, string>>;
    readonly bodyFile?: {
      readonly path: string;
      readonly size: number;
    };
  }): Promise<ApiResponse> {
    this.calls.push(`${request.method} ${request.path}`);
    if (request.method === 'GET' && request.path.includes('/git/ref/tags/')) {
      if (this.thrownSafeFailures > 0) {
        this.thrownSafeFailures -= 1;
        throw new Error('fixture network failure');
      }
      if (this.safeFailures > 0) {
        this.safeFailures -= 1;
        return jsonResponse(429, { message: 'retry' }, { 'retry-after': '0' });
      }
      return jsonResponse(200, { object: { type: 'tag', sha: 'b'.repeat(40) } });
    }
    if (request.method === 'GET' && request.path.includes('/git/tags/')) {
      return jsonResponse(200, { tag: 'v2.0.0', object: { type: 'commit', sha: commit } });
    }
    if (request.method === 'GET' && request.path.includes('/compare/')) {
      return jsonResponse(200, { merge_base_commit: { sha: commit } });
    }
    if (request.method === 'GET' && request.path.includes('/releases?')) {
      this.releaseListCalls += 1;
      if (this.injectRaceOnReleaseListCall === this.releaseListCalls) {
        this.releases.push({
          id: 999,
          tag_name: 'v3.0.0',
          draft: false,
          prerelease: false,
          html_url: `https://github.com/${repository}/releases/tag/v3.0.0`,
        });
      }
      if (this.mutateAssetOnReleaseListCall === this.releaseListCalls) {
        const asset = [...this.assets.values()].flat()[0];
        if (asset === undefined) {
          throw new Error('fixture has no asset to mutate');
        }
        const mutated = new Uint8Array(asset.bytes);
        mutated[0] = (mutated[0] ?? 0) ^ 1;
        asset.bytes = mutated;
      }
      const page = Number(new URLSearchParams(request.path.split('?')[1]).get('page'));
      return jsonResponse(200, this.releases.slice((page - 1) * 100, page * 100));
    }
    const assetList = /\/releases\/([0-9]+)\/assets\?/u.exec(request.path);
    if (request.method === 'GET' && assetList !== null) {
      const releaseIdText = assetList[1];
      if (releaseIdText === undefined) {
        throw new Error('missing fake release id');
      }
      const releaseId = Number(releaseIdText);
      const page = Number(new URLSearchParams(request.path.split('?')[1]).get('page'));
      const assets = this.assets.get(releaseId) ?? [];
      return jsonResponse(
        200,
        assets.slice((page - 1) * 100, page * 100).map(({ bytes: _bytes, ...asset }) => asset),
      );
    }
    const assetDownload = /\/releases\/assets\/([0-9]+)$/u.exec(request.path);
    if (request.method === 'GET' && assetDownload !== null) {
      strictEqual(request.headers?.Accept, 'application/octet-stream');
      const assetIdText = assetDownload[1];
      if (assetIdText === undefined) {
        throw new Error('missing fake asset id');
      }
      const assetId = Number(assetIdText);
      const asset = [...this.assets.values()].flat().find((candidate) => candidate.id === assetId);
      if (asset === undefined) {
        return jsonResponse(404, { message: 'missing' });
      }
      return { status: 200, headers: {}, body: asset.bytes };
    }
    const assetUpload = /\/releases\/([0-9]+)\/assets\?/u.exec(request.path);
    if (request.method === 'POST' && assetUpload !== null) {
      const releaseIdText = assetUpload[1];
      const name = new URLSearchParams(request.path.split('?')[1]).get('name');
      if (releaseIdText === undefined || name === null || request.bodyFile === undefined) {
        throw new Error('invalid fake upload request');
      }
      const releaseId = Number(releaseIdText);
      const release = this.releases.find((candidate) => candidate.id === releaseId);
      if (release === undefined) {
        return jsonResponse(404, { message: 'missing release' });
      }
      const bytes = readFileSync(request.bodyFile.path);
      const asset: FakeAsset = {
        id: 1000 + (this.assets.get(releaseId)?.length ?? 0),
        name,
        state: 'uploaded',
        size: bytes.length,
        browser_download_url:
          `https://github.com/${repository}/releases/download/` +
          `${release.html_url.split('/').at(-1) ?? release.tag_name}/${name}`,
        digest: digest(bytes),
        bytes,
      };
      this.assets.set(releaseId, [...(this.assets.get(releaseId) ?? []), asset]);
      if (this.uncertainUpload) {
        this.uncertainUpload = false;
        throw new Error('fixture upload response lost');
      }
      const { bytes: _bytes, ...metadata } = asset;
      return jsonResponse(201, metadata);
    }
    if (request.method === 'POST' && request.path.endsWith('/releases')) {
      const release = {
        id: 123,
        tag_name: 'v2.0.0',
        draft: true,
        prerelease: false,
        html_url: `https://github.com/${repository}/releases/tag/untagged-fixture`,
      };
      this.releases.push(release);
      if (this.uncertainCreate) {
        this.uncertainCreate = false;
        throw new Error('fixture create response lost');
      }
      return jsonResponse(201, release);
    }
    if (request.method === 'DELETE' && assetDownload !== null) {
      const assetIdText = assetDownload[1];
      if (assetIdText === undefined) {
        throw new Error('missing fake asset id');
      }
      const assetId = Number(assetIdText);
      for (const [releaseId, assets] of this.assets) {
        this.assets.set(
          releaseId,
          assets.filter((asset) => asset.id !== assetId),
        );
      }
      if (this.uncertainDelete) {
        this.uncertainDelete = false;
        throw new Error('fixture delete response lost');
      }
      return { status: 204, headers: {}, body: new Uint8Array() };
    }
    const releasePatch = /\/releases\/([0-9]+)$/u.exec(request.path);
    if (request.method === 'PATCH' && releasePatch !== null) {
      const releaseIdText = releasePatch[1];
      if (releaseIdText === undefined) {
        throw new Error('missing fake release id');
      }
      const releaseId = Number(releaseIdText);
      const release = this.releases.find((candidate) => candidate.id === releaseId);
      if (release === undefined) {
        return jsonResponse(404, { message: 'missing' });
      }
      release.draft = false;
      release.html_url = `https://github.com/${repository}/releases/tag/${release.tag_name}`;
      for (const asset of this.assets.get(releaseId) ?? []) {
        asset.browser_download_url = `https://github.com/${repository}/releases/download/${release.tag_name}/${asset.name}`;
      }
      if (this.corruptAssetAfterPatch) {
        const asset = this.assets.get(releaseId)?.[0];
        if (asset === undefined) {
          throw new Error('fixture has no published asset to corrupt');
        }
        const corrupted = new Uint8Array(asset.bytes);
        corrupted[0] = (corrupted[0] ?? 0) ^ 1;
        asset.bytes = corrupted;
      }
      if (this.uncertainPatch) {
        this.uncertainPatch = false;
        throw new Error('fixture publish response lost');
      }
      return jsonResponse(200, release);
    }
    throw new Error(`unexpected fake GitHub call: ${request.method} ${request.path}`);
  }
}

async function fixture(): Promise<{
  readonly root: string;
  readonly config: PublisherConfig;
  readonly localBytes: Readonly<Record<string, Uint8Array>>;
  readonly cleanup: () => Promise<void>;
}> {
  const root = await mkdtemp(join(tmpdir(), 'deskhelm-publisher-test-'));
  const localBytes: Readonly<Record<string, Uint8Array>> = {
    [archiveName]: new TextEncoder().encode('local archive'),
    [appcastName]: new TextEncoder().encode('local appcast'),
    [checksumName]: new TextEncoder().encode('local checksum'),
  };
  await Promise.all(
    assetNames.map((name) => {
      const bytes = localBytes[name];
      if (bytes === undefined) {
        throw new Error(`missing local bytes: ${name}`);
      }
      return writeFile(join(root, name), bytes);
    }),
  );
  return {
    root,
    localBytes,
    config: {
      repository,
      releaseCommit: commit,
      tag: 'v2.0.0',
      versionText: '2.0.0',
      sparkleVersion: '2.9.4',
      inputDirectory: root,
      artifactValidator: join(root, 'validator'),
      sparklePublicKey: Buffer.from(new Uint8Array(32)).toString('base64'),
      githubToken: 'fixture-token',
      githubSha: commit,
      dryRun: false,
    },
    cleanup: () => rm(root, { recursive: true, force: true }),
  };
}

function execFor(github: FakeGitHub, releaseId = 123): Exec {
  return (_command, _arguments) => {
    void github;
    void releaseId;
    return { status: 0, stdout: '', stderr: '', timedOut: false };
  };
}

await test('stable SemVer parsing is strict and compares large bounded components', () => {
  const huge = parseStableTag(`v${'9'.repeat(128)}.0.0`);
  const small = parseStableVersion('999.999.999');
  strictEqual(huge === undefined, false);
  strictEqual(small === undefined, false);
  if (huge === undefined || small === undefined) {
    throw new Error('fixture versions did not parse');
  }
  strictEqual(compareStableVersions(huge, small), 1);
  strictEqual(parseStableTag('v01.2.3'), undefined);
  strictEqual(parseStableTag('v1.2.3-rc.1'), undefined);
  strictEqual(parseStableTag(`v${'9'.repeat(129)}.0.0`), undefined);
});

await test('public same-tag retry validates downloaded public bytes without a mutation', async () => {
  const data = await fixture();
  try {
    const remoteBytes: Readonly<Record<string, Uint8Array>> = {
      [archiveName]: new TextEncoder().encode('older nondeterministic public archive'),
      [appcastName]: new TextEncoder().encode('public appcast'),
      [checksumName]: new TextEncoder().encode('public checksum'),
    };
    const github = new FakeGitHub(remoteBytes);
    github.releases.push({
      id: 123,
      tag_name: 'v2.0.0',
      draft: false,
      prerelease: false,
      html_url: `https://github.com/${repository}/releases/tag/v2.0.0`,
    });
    github.installUploadedAssets(123, 'v2.0.0');
    let validatorSawRemoteArchive = false;
    const exec: Exec = (command, arguments_) => {
      if (command.endsWith('validator')) {
        const archiveIndex = arguments_.indexOf('--archive');
        const archivePath = arguments_[archiveIndex + 1];
        if (archivePath !== undefined) {
          validatorSawRemoteArchive =
            readFileSync(archivePath, 'utf8') === 'older nondeterministic public archive';
        }
      }
      return { status: 0, stdout: '', stderr: '', timedOut: false };
    };
    await runPublisher(data.config, { transport: github, exec, sleep: async () => {} });
    strictEqual(validatorSawRemoteArchive, true);
    strictEqual(
      github.calls.some((call) => call.startsWith('POST ')),
      false,
    );
    strictEqual(
      github.calls.some((call) => call.startsWith('DELETE ')),
      false,
    );
    strictEqual(
      github.calls.some((call) => call.startsWith('PATCH ')),
      false,
    );
  } finally {
    await data.cleanup();
  }
});

await test('draft repair deletes a starter placeholder with a null digest before upload', async () => {
  const data = await fixture();
  try {
    const github = new FakeGitHub(data.localBytes);
    github.safeFailures = 1;
    github.releases.push({
      id: 123,
      tag_name: 'v2.0.0',
      draft: true,
      prerelease: false,
      html_url: `https://github.com/${repository}/releases/tag/untagged-fixture`,
    });
    github.assets.set(123, [
      {
        id: 77,
        name: 'obsolete.txt',
        state: 'starter',
        size: 0,
        browser_download_url: `https://github.com/${repository}/releases/download/untagged-fixture/obsolete.txt`,
        digest: null,
        bytes: new Uint8Array(),
      },
    ]);
    const sleeps: number[] = [];
    await runPublisher(data.config, {
      transport: github,
      exec: execFor(github),
      sleep: async (milliseconds) => {
        sleeps.push(milliseconds);
      },
    });
    deepStrictEqual(
      github.assets
        .get(123)
        ?.map((asset) => asset.name)
        .toSorted(),
      assetNames.toSorted(),
    );
    strictEqual(github.calls.filter((call) => call.includes('/git/ref/tags/')).length, 3);
    const patchIndex = github.calls.findIndex((call) => call.startsWith('PATCH '));
    strictEqual(patchIndex > 0, true);
    strictEqual(
      github.calls
        .slice(0, patchIndex)
        .filter((call) => call.startsWith(`GET repos/${repository}/releases/assets/`)).length,
      6,
    );
    strictEqual(
      github.calls
        .slice(patchIndex + 1)
        .filter((call) => call.startsWith(`GET repos/${repository}/releases/assets/`)).length,
      3,
    );
    strictEqual(sleeps.length, 1);
  } finally {
    await data.cleanup();
  }
});

await test('safe reads retry transport failures and an ambiguous upload converges by readback', async () => {
  const data = await fixture();
  try {
    const github = new FakeGitHub(data.localBytes);
    github.thrownSafeFailures = 2;
    const sleeps: number[] = [];
    github.uncertainUpload = true;
    await runPublisher(data.config, {
      transport: github,
      exec: execFor(github),
      sleep: async (milliseconds) => {
        sleeps.push(milliseconds);
      },
    });
    strictEqual(sleeps.length >= 2, true);
    strictEqual(
      github.calls.some((call) => call.startsWith('PATCH ')),
      true,
    );
  } finally {
    await data.cleanup();
  }
});

await test('ambiguous create and final publish mutations converge without a blind retry', async () => {
  const data = await fixture();
  try {
    const github = new FakeGitHub(data.localBytes);
    github.uncertainCreate = true;
    github.uncertainPatch = true;
    await runPublisher(data.config, {
      transport: github,
      exec: execFor(github),
      sleep: async () => {},
    });
    strictEqual(
      github.calls.filter((call) => call === `POST repos/${repository}/releases`).length,
      1,
    );
    strictEqual(github.calls.filter((call) => call.startsWith('PATCH ')).length, 1);
    strictEqual(github.releases.find((release) => release.id === 123)?.draft, false);
  } finally {
    await data.cleanup();
  }
});

await test('an ambiguous asset delete converges through the paginated asset read', async () => {
  const data = await fixture();
  try {
    const github = new FakeGitHub(data.localBytes);
    github.uncertainDelete = true;
    github.releases.push({
      id: 123,
      tag_name: 'v2.0.0',
      draft: true,
      prerelease: false,
      html_url: `https://github.com/${repository}/releases/tag/untagged-fixture`,
    });
    const oldBytes = new TextEncoder().encode('old');
    github.assets.set(123, [
      {
        id: 77,
        name: 'old.bin',
        state: 'uploaded',
        size: oldBytes.length,
        browser_download_url: `https://github.com/${repository}/releases/download/untagged-fixture/old.bin`,
        digest: digest(oldBytes),
        bytes: oldBytes,
      },
    ]);
    await runPublisher(data.config, {
      transport: github,
      exec: execFor(github),
      sleep: async () => {},
    });
    strictEqual(github.calls.filter((call) => call.startsWith('DELETE ')).length, 1);
  } finally {
    await data.cleanup();
  }
});

await test('draft repair paginates and deletes every old asset before upload', async () => {
  const data = await fixture();
  try {
    const github = new FakeGitHub(data.localBytes);
    github.releases.push({
      id: 123,
      tag_name: 'v2.0.0',
      draft: true,
      prerelease: false,
      html_url: `https://github.com/${repository}/releases/tag/untagged-fixture`,
    });
    github.assets.set(
      123,
      Array.from({ length: 101 }, (_, index) => {
        const bytes = new TextEncoder().encode(`old-${String(index)}`);
        return {
          id: 2000 + index,
          name: `old-${String(index)}.bin`,
          state: 'uploaded',
          size: bytes.length,
          browser_download_url: `https://github.com/${repository}/releases/download/untagged-fixture/old-${String(index)}.bin`,
          digest: digest(bytes),
          bytes,
        };
      }),
    );
    await runPublisher(data.config, {
      transport: github,
      exec: execFor(github),
      sleep: async () => {},
    });
    strictEqual(github.calls.filter((call) => call.startsWith('DELETE ')).length, 101);
    deepStrictEqual(
      github.assets
        .get(123)
        ?.map((asset) => asset.name)
        .toSorted(),
      assetNames.toSorted(),
    );
  } finally {
    await data.cleanup();
  }
});

await test('a higher stable release appearing at the final recheck leaves the draft private', async () => {
  const data = await fixture();
  try {
    const github = new FakeGitHub(data.localBytes);
    github.injectRaceOnReleaseListCall = 3;
    await rejects(
      runPublisher(data.config, {
        transport: github,
        exec: execFor(github),
        sleep: async () => {},
      }),
      /must be higher than v3\.0\.0/u,
    );
    strictEqual(
      github.calls.some((call) => call.startsWith('PATCH ')),
      false,
    );
    strictEqual(github.releases.find((release) => release.id === 123)?.draft, true);
  } finally {
    await data.cleanup();
  }
});

await test('a late draft asset mutation after final source checks prevents PATCH', async () => {
  const data = await fixture();
  try {
    const github = new FakeGitHub(data.localBytes);
    github.mutateAssetOnReleaseListCall = 3;
    await rejects(
      runPublisher(data.config, {
        transport: github,
        exec: execFor(github),
        sleep: async () => {},
      }),
      /Downloaded draft bytes do not match local artifact/u,
    );
    strictEqual(
      github.calls.some((call) => call.startsWith('PATCH ')),
      false,
    );
    strictEqual(github.releases.find((release) => release.id === 123)?.draft, true);
  } finally {
    await data.cleanup();
  }
});

await test('a successful PATCH is followed by public byte validation', async () => {
  const data = await fixture();
  try {
    const github = new FakeGitHub(data.localBytes);
    github.corruptAssetAfterPatch = true;
    await rejects(
      runPublisher(data.config, {
        transport: github,
        exec: execFor(github),
        sleep: async () => {},
      }),
      /digest does not match downloaded bytes/u,
    );
    const patchIndex = github.calls.findIndex((call) => call.startsWith('PATCH '));
    strictEqual(patchIndex > 0, true);
    strictEqual(
      github.calls
        .slice(patchIndex + 1)
        .some((call) => call.startsWith(`GET repos/${repository}/releases/assets/`)),
      true,
    );
    strictEqual(github.releases.find((release) => release.id === 123)?.draft, false);
  } finally {
    await data.cleanup();
  }
});

await test('release pagination fails closed at the configured bound', async () => {
  const data = await fixture();
  try {
    const github = new FakeGitHub(data.localBytes);
    for (let index = 0; index < 2000; index += 1) {
      github.releases.push({
        id: index + 1,
        tag_name: `build-${String(index)}`,
        draft: false,
        prerelease: false,
        html_url: `https://github.com/${repository}/releases/tag/build-${String(index)}`,
      });
    }
    await rejects(
      runPublisher(data.config, {
        transport: github,
        exec: execFor(github),
        sleep: async () => {},
      }),
      /pagination exceeded 2000 records/u,
    );
    strictEqual(
      github.calls.some((call) => call.startsWith('POST ')),
      false,
    );
  } finally {
    await data.cleanup();
  }
});

await test('credential-free dry run validates local artifacts without transport access', async () => {
  const data = await fixture();
  try {
    const github = new FakeGitHub(data.localBytes);
    const { githubToken: _githubToken, ...configWithoutToken } = data.config;
    await runPublisher(
      { ...configWithoutToken, dryRun: true },
      {
        transport: github,
        exec: execFor(github),
        sleep: async () => {},
      },
    );
    deepStrictEqual(github.calls, []);
  } finally {
    await data.cleanup();
  }
});

await test('HTTP response bodies fail before exceeding their configured bound', async () => {
  await rejects(
    readBoundedBody(
      new Response(new Uint8Array(5), {
        headers: { 'content-length': '5' },
      }),
      4,
    ),
    /exceeds the 4 byte limit/u,
  );
});
