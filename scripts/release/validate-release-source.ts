#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { appendFileSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  isRecord,
  parseJson,
  parseStableTag,
  parseStableVersion,
  requirePinnedNode,
  requireString,
} from './release-contract.ts';

const canonicalRepository = 'acg-box/deskhelm';
const canonicalBaseRef = 'refs/remotes/origin/main';
const deskHelmPackages = new Set(['deskhelm']);
const fullCommitPattern = /^[0-9a-fA-F]{40}$/u;
const lowercaseCommitPattern = /^[0-9a-f]{40}$/u;
const sparkleDeclarationPattern =
  /\.package\(url:\s*"https:\/\/github\.com\/sparkle-project\/Sparkle",\s*exact:\s*"([^"]+)"\)/gu;

interface SourceArguments {
  readonly tag: string;
  readonly eventCommit: string;
  readonly repository: string;
  readonly baseRef: string;
  readonly repoRoot: string;
  readonly githubOutput?: string;
}

interface CommandResult {
  readonly status: number;
  readonly stdout: string;
  readonly stderr: string;
}

export type RunCommand = (
  command: string,
  arguments_: readonly string[],
  cwd: string,
) => CommandResult;

const runCommand: RunCommand = (command, arguments_, cwd) => {
  const result = spawnSync(command, arguments_, {
    cwd,
    encoding: 'utf8',
    shell: false,
    timeout: 30_000,
  });
  if (result.error !== undefined) {
    throw new Error(`Cannot start ${command}.`, { cause: result.error });
  }
  return {
    status: result.status ?? 1,
    stdout: result.stdout,
    stderr: result.stderr,
  };
};

function parseArguments(arguments_: readonly string[]): SourceArguments {
  const values = new Map<string, string>();
  for (let index = 0; index < arguments_.length; index += 2) {
    const option = arguments_[index];
    const value = arguments_[index + 1];
    if (option === undefined || value === undefined || !option.startsWith('--')) {
      throw new Error('Release source arguments must use --name value pairs.');
    }
    if (values.has(option)) {
      throw new Error(`Duplicate release source argument: ${option}`);
    }
    values.set(option, value);
  }
  const required = (name: string): string => {
    const value = values.get(name);
    if (value === undefined || value.length === 0) {
      throw new Error(`Missing required release source argument: ${name}`);
    }
    return value;
  };
  const known = new Set([
    '--tag',
    '--event-commit',
    '--repository',
    '--base-ref',
    '--repo-root',
    '--github-output',
  ]);
  for (const option of values.keys()) {
    if (!known.has(option)) {
      throw new Error(`Unknown release source argument: ${option}`);
    }
  }
  const scriptRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const githubOutput = values.get('--github-output');
  return {
    tag: required('--tag'),
    eventCommit: required('--event-commit'),
    repository: required('--repository'),
    baseRef: values.get('--base-ref') ?? canonicalBaseRef,
    repoRoot: resolve(values.get('--repo-root') ?? scriptRoot),
    ...(githubOutput === undefined ? {} : { githubOutput: resolve(githubOutput) }),
  };
}

function git(repoRoot: string, runner: RunCommand, ...arguments_: string[]): string {
  const result = runner('git', arguments_, repoRoot);
  if (result.status !== 0) {
    const detail = result.stderr.trim() || result.stdout.trim() || 'git command failed';
    throw new Error(`${detail}: git ${arguments_.join(' ')}`);
  }
  return result.stdout.trim();
}

function readText(repoRoot: string, relativePath: string): string {
  try {
    return readFileSync(resolve(repoRoot, relativePath), 'utf8');
  } catch (error: unknown) {
    throw new Error(`Cannot read ${relativePath}.`, { cause: error });
  }
}

function namedTomlSection(document: string, name: string, source: string): string {
  const header = `[${name}]`;
  const lines = document.split(/\r?\n/u);
  const starts = lines.flatMap((line, index) => (line.trim() === header ? [index] : []));
  if (starts.length !== 1) {
    throw new Error(`${source} must contain exactly one ${header} section.`);
  }
  const start = starts[0];
  if (start === undefined) {
    throw new Error(`${source} does not contain ${header}.`);
  }
  const body: string[] = [];
  for (const line of lines.slice(start + 1)) {
    if (/^\s*\[/u.test(line)) {
      break;
    }
    body.push(line);
  }
  return body.join('\n');
}

function tomlBasicString(section: string, key: string, source: string): string {
  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
  const pattern = new RegExp(
    `^\\s*${escapedKey}\\s*=\\s*("(?:[^"\\\\]|\\\\.)*")\\s*(?:#.*)?$`,
    'gmu',
  );
  const matches = [...section.matchAll(pattern)];
  if (matches.length !== 1) {
    throw new Error(`${source} must contain exactly one string value for ${key}.`);
  }
  const encoded = matches[0]?.[1];
  if (encoded === undefined) {
    throw new Error(`${source}.${key} is missing.`);
  }
  const value = parseJson(encoded, `${source}.${key}`);
  if (typeof value !== 'string') {
    throw new Error(`${source}.${key} must be a string.`);
  }
  return value;
}

function validateVersions(
  repoRoot: string,
  tag: string,
): {
  readonly version: string;
  readonly sparkleVersion: string;
  readonly sparkleRevision: string;
} {
  const parsedTag = parseStableTag(tag);
  if (parsedTag === undefined) {
    throw new Error(`Release tag must be stable SemVer vX.Y.Z without leading zeroes: ${tag}`);
  }
  const version = tag.slice(1);

  const cargoText = readText(repoRoot, 'Cargo.toml');
  const cargoPackage = namedTomlSection(cargoText, 'workspace.package', 'Cargo.toml');
  const cargoVersion = tomlBasicString(cargoPackage, 'version', 'Cargo.toml');
  if (parseStableVersion(cargoVersion) === undefined) {
    throw new Error(`Cargo workspace version is not stable SemVer: ${cargoVersion}`);
  }
  if (cargoVersion !== version) {
    throw new Error(`Tag ${tag} does not match Cargo workspace version ${cargoVersion}.`);
  }

  const lockText = readText(repoRoot, 'Cargo.lock');
  const packageSections = lockText.split(/^\s*\[\[package\]\]\s*(?:#.*)?$/gmu).slice(1);
  const lockedVersions = new Map<string, string[]>(
    [...deskHelmPackages].map((packageName) => [packageName, []]),
  );
  for (const section of packageSections) {
    const nameMatches = [...section.matchAll(/^\s*name\s*=\s*("(?:[^"\\]|\\.)*")/gmu)];
    if (nameMatches.length !== 1) {
      continue;
    }
    const encodedName = nameMatches[0]?.[1];
    if (encodedName === undefined) {
      continue;
    }
    const packageName = parseJson(encodedName, 'Cargo.lock package name');
    if (typeof packageName !== 'string') {
      continue;
    }
    const versions = lockedVersions.get(packageName);
    if (versions !== undefined) {
      versions.push(tomlBasicString(section, 'version', `Cargo.lock ${packageName}`));
    }
  }
  for (const [packageName, versions] of lockedVersions) {
    if (versions.length !== 1 || versions[0] !== version) {
      throw new Error(
        `Cargo.lock ${packageName} versions ${JSON.stringify(versions)} do not match exactly ${version}.`,
      );
    }
  }

  const packageSwift = readText(repoRoot, 'apps/deskhelm/macos/Package.swift');
  const declaredVersions = [...packageSwift.matchAll(sparkleDeclarationPattern)].flatMap((match) =>
    match[1] === undefined ? [] : [match[1]],
  );
  if (declaredVersions.length !== 1) {
    throw new Error('Package.swift must declare exactly one exact official Sparkle dependency.');
  }
  const sparkleVersion = declaredVersions[0];
  if (sparkleVersion === undefined || parseStableVersion(sparkleVersion) === undefined) {
    throw new Error(`Package.swift Sparkle version is not stable SemVer: ${sparkleVersion ?? ''}`);
  }

  const resolvedValue = parseJson(
    readText(repoRoot, 'apps/deskhelm/macos/Package.resolved'),
    'Package.resolved',
  );
  if (!isRecord(resolvedValue) || !Array.isArray(resolvedValue.pins)) {
    throw new Error('Package.resolved must contain a pins array.');
  }
  const pins: unknown[] = [];
  for (const pin of resolvedValue.pins) {
    pins.push(pin);
  }
  const sparklePins = pins.filter((pin) => isRecord(pin) && pin.identity === 'sparkle');
  if (sparklePins.length !== 1) {
    throw new Error('Package.resolved must contain exactly one Sparkle pin.');
  }
  const pin = sparklePins[0];
  if (!isRecord(pin)) {
    throw new Error('Package.resolved Sparkle pin is invalid.');
  }
  if (requireString(pin, 'kind', 'Sparkle pin') !== 'remoteSourceControl') {
    throw new Error('Package.resolved Sparkle pin must use remoteSourceControl.');
  }
  if (
    requireString(pin, 'location', 'Sparkle pin') !== 'https://github.com/sparkle-project/Sparkle'
  ) {
    throw new Error('Package.resolved uses an unexpected Sparkle source.');
  }
  if (!isRecord(pin.state)) {
    throw new Error('Package.resolved Sparkle pin is missing state.');
  }
  if (requireString(pin.state, 'version', 'Sparkle pin state') !== sparkleVersion) {
    throw new Error('Package.swift and Package.resolved disagree on Sparkle version.');
  }
  const revision = requireString(pin.state, 'revision', 'Sparkle pin state');
  if (!lowercaseCommitPattern.test(revision)) {
    throw new Error('Package.resolved Sparkle pin must contain a full lowercase commit SHA.');
  }
  return { version, sparkleVersion, sparkleRevision: revision };
}

function validateGitSource(arguments_: SourceArguments, runner: RunCommand): string {
  if (!fullCommitPattern.test(arguments_.eventCommit)) {
    throw new Error(`GitHub event commit must be a full Git commit SHA: ${arguments_.eventCommit}`);
  }
  if (arguments_.baseRef !== canonicalBaseRef) {
    throw new Error(`Release base must be canonical origin/main: ${arguments_.baseRef}`);
  }
  if (git(arguments_.repoRoot, runner, 'cat-file', '-t', arguments_.eventCommit) !== 'commit') {
    throw new Error('GitHub event SHA must identify a commit directly.');
  }
  const tagRef = `refs/tags/${arguments_.tag}`;
  if (git(arguments_.repoRoot, runner, 'cat-file', '-t', tagRef) !== 'tag') {
    throw new Error(`Release tag must be annotated: ${arguments_.tag}`);
  }
  const tagHeaders = git(arguments_.repoRoot, runner, 'cat-file', '-p', tagRef).split('\n\n')[0];
  if (tagHeaders === undefined || !/^type commit$/mu.test(tagHeaders)) {
    throw new Error('Release annotated tag must point directly to a commit.');
  }
  if (
    !new RegExp(`^tag ${arguments_.tag.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')}$`, 'mu').test(
      tagHeaders,
    )
  ) {
    throw new Error('Release annotated tag object name must match its ref.');
  }
  const tagCommit = git(arguments_.repoRoot, runner, 'rev-parse', '--verify', `${tagRef}^{commit}`);
  const eventCommit = git(
    arguments_.repoRoot,
    runner,
    'rev-parse',
    '--verify',
    arguments_.eventCommit,
  );
  const headCommit = git(arguments_.repoRoot, runner, 'rev-parse', '--verify', 'HEAD^{commit}');
  git(arguments_.repoRoot, runner, 'rev-parse', '--verify', `${arguments_.baseRef}^{commit}`);
  if (tagCommit !== eventCommit) {
    throw new Error(`Tag commit ${tagCommit} does not match event commit ${eventCommit}.`);
  }
  if (tagCommit !== headCommit) {
    throw new Error(`Checked-out commit ${headCommit} does not match tag commit ${tagCommit}.`);
  }
  const ancestor = runner(
    'git',
    ['merge-base', '--is-ancestor', tagCommit, arguments_.baseRef],
    arguments_.repoRoot,
  );
  if (ancestor.status !== 0) {
    throw new Error(`Tag commit ${tagCommit} is not reachable from ${arguments_.baseRef}.`);
  }
  return tagCommit;
}

export function validateReleaseSource(
  arguments_: SourceArguments,
  runner: RunCommand = runCommand,
): {
  readonly version: string;
  readonly sparkleVersion: string;
  readonly sparkleRevision: string;
  readonly tagCommit: string;
} {
  if (arguments_.repository !== canonicalRepository) {
    throw new Error(
      `Release repository must be ${canonicalRepository}, got ${arguments_.repository}.`,
    );
  }
  const versions = validateVersions(arguments_.repoRoot, arguments_.tag);
  return {
    ...versions,
    tagCommit: validateGitSource(arguments_, runner),
  };
}

function validateWorkflowContext(arguments_: SourceArguments): void {
  if (process.env.GITHUB_ACTIONS !== 'true') {
    return;
  }
  if (
    process.env.GITHUB_REF !== `refs/tags/${arguments_.tag}` ||
    process.env.GITHUB_REPOSITORY !== arguments_.repository ||
    process.env.GITHUB_SHA !== arguments_.eventCommit
  ) {
    throw new Error('GitHub workflow context does not match the release source arguments.');
  }
}

function main(): void {
  const releaseArguments = parseArguments(process.argv.slice(2));
  requirePinnedNode(releaseArguments.repoRoot);
  validateWorkflowContext(releaseArguments);
  const result = validateReleaseSource(releaseArguments);
  const outputs = {
    canonical_repository: canonicalRepository,
    sparkle_revision: result.sparkleRevision,
    sparkle_version: result.sparkleVersion,
    tag_commit: result.tagCommit,
    version: result.version,
  };
  if (releaseArguments.githubOutput === undefined) {
    process.stdout.write(`${JSON.stringify(outputs)}\n`);
    return;
  }
  appendFileSync(
    releaseArguments.githubOutput,
    Object.entries(outputs)
      .map(([key, value]) => `${key}=${value}\n`)
      .join(''),
    'utf8',
  );
}

if (import.meta.main) {
  try {
    main();
  } catch (error: unknown) {
    console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
