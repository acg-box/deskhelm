#!/usr/bin/env python3
"""Run credential-free release workflow regression checks."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import warnings
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RELEASE_DIR = ROOT / "script/release"
CANONICAL_REPOSITORY = "acg-box/deskhelm"
ARCHIVE_NAME = "deskhelm-aarch64-apple-darwin.zip"
APPCAST_NAME = "appcast.xml"
CHECKSUM_NAME = f"{ARCHIVE_NAME}.sha256"
PUBLIC_KEY = base64.b64encode(bytes(range(32))).decode("ascii")
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
GITHUB_RELEASE_CONTEXT = (
	"GITHUB_ACTIONS",
	"GITHUB_REF",
	"GITHUB_REPOSITORY",
	"GITHUB_SHA",
)


def run(
	args: list[str | Path],
	*,
	cwd: Path | None = None,
	env: dict[str, str] | None = None,
	input_text: str | None = None,
	check: bool = True,
) -> subprocess.CompletedProcess[str]:
	command = [str(arg) for arg in args]
	effective_env = env
	if effective_env is None:
		effective_env = os.environ.copy()
		for key in GITHUB_RELEASE_CONTEXT:
			effective_env.pop(key, None)
	result = subprocess.run(
		command,
		cwd=cwd,
		env=effective_env,
		input=input_text,
		capture_output=True,
		text=True,
	)
	if check and result.returncode != 0:
		raise AssertionError(
			f"command failed ({result.returncode}): {' '.join(command)}\n"
			f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
		)
	return result


def expect_failure(
	args: list[str | Path],
	*,
	cwd: Path | None = None,
	env: dict[str, str] | None = None,
	input_text: str | None = None,
) -> None:
	result = run(args, cwd=cwd, env=env, input_text=input_text, check=False)
	if result.returncode == 0:
		raise AssertionError(f"command unexpectedly succeeded: {' '.join(map(str, args))}")


def write_executable(path: Path, contents: str) -> None:
	path.write_text(contents, encoding="utf-8")
	path.chmod(0o755)


def git(repo: Path, *args: str) -> str:
	return run(["git", *args], cwd=repo).stdout.strip()


def test_source_validator(tmp: Path) -> None:
	repo = tmp / "source"
	(repo / "apps/deskhelm/macos").mkdir(parents=True)
	(repo / ".node-version").write_text("24.18.0\n", encoding="utf-8")
	(repo / "Cargo.toml").write_text(
		"""\
[workspace]
members = ["apps/deskhelm"]

[workspace.package]
version = "1.2.3"
""",
		encoding="utf-8",
	)
	(repo / "Cargo.lock").write_text(
		"""\
version = 4

[[package]]
name = "deskhelm"
version = "1.2.3"
""",
		encoding="utf-8",
	)
	(repo / "apps/deskhelm/macos/Package.swift").write_text(
		'.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")\n',
		encoding="utf-8",
	)
	resolved_path = repo / "apps/deskhelm/macos/Package.resolved"
	resolved = {
		"pins": [
			{
				"identity": "sparkle",
				"kind": "remoteSourceControl",
				"location": "https://github.com/sparkle-project/Sparkle",
				"state": {"revision": "b" * 40, "version": "2.9.4"},
			}
		]
	}
	resolved_path.write_text(json.dumps(resolved), encoding="utf-8")

	git(repo, "init", "-b", "main")
	git(repo, "config", "user.name", "Release Self Check")
	git(repo, "config", "user.email", "release-self-check@example.invalid")
	git(repo, "config", "core.hooksPath", str(repo / ".git/hooks"))
	git(repo, "add", ".")
	git(repo, "commit", "-m", "base")
	base_commit = git(repo, "rev-parse", "HEAD")
	git(repo, "update-ref", "refs/remotes/origin/main", base_commit)
	git(repo, "commit", "--allow-empty", "-m", "tagged feature")
	tag_commit = git(repo, "rev-parse", "HEAD")
	git(repo, "tag", "-a", "v1.2.3", "-m", "v1.2.3")
	tag_object = git(repo, "rev-parse", "refs/tags/v1.2.3")
	node = os.environ.get("DESKHELM_NODE_BIN") or shutil.which("node")
	if node is None:
		raise AssertionError("Node.js is required for the release source self-check")
	validator = ROOT / "scripts/release/validate-release-source.ts"
	base_args = [
		node,
		validator,
		"--repo-root",
		repo,
		"--tag",
		"v1.2.3",
		"--event-commit",
		tag_commit,
		"--repository",
		CANONICAL_REPOSITORY,
	]
	expect_failure(base_args)
	git(repo, "update-ref", "refs/remotes/origin/main", tag_commit)
	result = run(base_args)
	metadata = json.loads(result.stdout)
	assert metadata["version"] == "1.2.3"
	assert metadata["sparkle_version"] == "2.9.4"
	assert metadata["sparkle_revision"] == "b" * 40
	assert metadata["tag_commit"] == tag_commit
	workflow_env = os.environ.copy()
	workflow_env.update(
		{
			"GITHUB_ACTIONS": "true",
			"GITHUB_REF": "refs/tags/v1.2.3",
			"GITHUB_REPOSITORY": CANONICAL_REPOSITORY,
			"GITHUB_SHA": tag_commit,
		}
	)
	run(base_args, env=workflow_env)
	mismatched_workflow_env = dict(workflow_env)
	mismatched_workflow_env["GITHUB_REF"] = "refs/tags/v9.9.9"
	expect_failure(base_args, env=mismatched_workflow_env)

	wrong_repository_args = list(base_args)
	wrong_repository_args[-1] = "other/deskhelm"
	expect_failure(wrong_repository_args)
	wrong_event_args = list(base_args)
	wrong_event_args[wrong_event_args.index("--event-commit") + 1] = base_commit
	expect_failure(wrong_event_args)
	tag_object_event_args = list(base_args)
	tag_object_event_args[tag_object_event_args.index("--event-commit") + 1] = tag_object
	expect_failure(tag_object_event_args)
	wrong_base_args = [*base_args, "--base-ref", "refs/remotes/origin/release"]
	expect_failure(wrong_base_args)
	leading_zero_args = list(base_args)
	leading_zero_args[leading_zero_args.index("--tag") + 1] = "v01.2.3"
	expect_failure(leading_zero_args)

	bad_resolved = json.loads(json.dumps(resolved))
	bad_resolved["pins"][0]["state"]["version"] = "2.9.3"
	resolved_path.write_text(json.dumps(bad_resolved), encoding="utf-8")
	expect_failure(base_args)
	resolved_path.write_text(json.dumps(resolved), encoding="utf-8")
	bad_kind = json.loads(json.dumps(resolved))
	bad_kind["pins"][0]["kind"] = "localSourceControl"
	resolved_path.write_text(json.dumps(bad_kind), encoding="utf-8")
	expect_failure(base_args)
	resolved_path.write_text(json.dumps(resolved), encoding="utf-8")

	git(repo, "tag", "-d", "v1.2.3")
	git(repo, "tag", "v1.2.3")
	lightweight_args = list(base_args)
	expect_failure(lightweight_args)

	git(repo, "tag", "-d", "v1.2.3")
	git(repo, "tag", "-a", "nested-target", "-m", "nested-target")
	git(repo, "tag", "-a", "v1.2.3", "-m", "v1.2.3", "nested-target")
	nested_args = list(base_args)
	expect_failure(nested_args)


def create_signing_fixture(
	root: Path,
	*,
	version: str = "B",
	current_target: str | None = None,
	unknown_graph: bool = False,
) -> Path:
	app = root / "DeskHelm.app"
	version_root = app / f"Contents/Frameworks/Sparkle.framework/Versions/{version}"
	(version_root / "XPCServices/Installer.xpc").mkdir(parents=True)
	(version_root / "XPCServices/Downloader.xpc").mkdir(parents=True)
	(version_root / "Updater.app").mkdir(parents=True)
	autoupdate = version_root / "Autoupdate"
	autoupdate.write_bytes(b"mach-o")
	autoupdate.chmod(0o755)
	(version_root / "Sparkle").write_bytes(b"mach-o")
	if unknown_graph:
		(version_root / "XPCServices/Unknown.xpc").mkdir()
	(app / "Contents/Frameworks/Sparkle.framework/Versions/Current").symlink_to(
		current_target or version
	)
	return app


def test_signer(tmp: Path) -> None:
	fixture_root = tmp / "signing"
	fixture_root.mkdir()
	app = create_signing_fixture(fixture_root)
	keychain = fixture_root / "release.keychain-db"
	keychain.touch()
	log_path = fixture_root / "codesign.jsonl"
	fake_codesign = fixture_root / "codesign"
	write_executable(
		fake_codesign,
		"""#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
with Path(os.environ["CODESIGN_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(args) + "\\n")
if "-dv" in args:
    team = (
        "OTHERTEAM1"
        if os.environ.get("FAKE_CODESIGN_DETAILS") == "wrong_team"
        else "RD3D4LH465"
    )
    lines = [
        "Executable=fake",
        "Identifier=fake",
        "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+0 location=embedded",
        f"Authority=Apple Development: DeskHelm Release ({team})",
        f"TeamIdentifier={team}",
    ]
    if os.environ.get("FAKE_CODESIGN_DETAILS") == "unexpected_timestamp":
        lines.append("Timestamp=Jul 26, 2026 at 1:00:00 PM")
    print("\\n".join(lines), file=sys.stderr)
elif "--entitlements" in args and "-d" in args:
    print("<plist><dict></dict></plist>")
""",
	)
	env = os.environ.copy()
	env.update({"CODESIGN_LOG": str(log_path), "DESKHELM_CODESIGN_BIN": str(fake_codesign)})
	identity = "Apple Development: DeskHelm Release (RD3D4LH465)"
	run(
		[
			RELEASE_DIR / "sign-macos-app.sh",
			"--app",
			app,
			"--identity",
			identity,
			"--keychain",
			keychain,
			"--mode",
			"release",
		],
		env=env,
	)
	calls = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
	sign_calls = [call for call in calls if "--force" in call]
	expected_suffixes = [
		"Versions/B/XPCServices/Installer.xpc",
		"Versions/B/XPCServices/Downloader.xpc",
		"Versions/B/Autoupdate",
		"Versions/B/Updater.app",
		"Sparkle.framework",
		"DeskHelm.app",
	]
	assert len(sign_calls) == len(expected_suffixes)
	for call, suffix in zip(sign_calls, expected_suffixes):
		assert call[-1].endswith(suffix), (call, suffix)
		assert "--deep" not in call
		assert call.index("--sign") < call.index("--options")
		assert call[call.index("--options") + 1] == "runtime"
		assert "--timestamp=none" in call
	assert "--preserve-metadata=entitlements" not in sign_calls[0]
	assert "--preserve-metadata=entitlements" in sign_calls[1]
	assert all("--preserve-metadata=entitlements" not in call for call in sign_calls[2:])
	assert any("--deep" in call and "--verify" in call for call in calls)

	invalid_env = dict(env)
	invalid_env["FAKE_CODESIGN_DETAILS"] = "unexpected_timestamp"
	expect_failure(
		[
			RELEASE_DIR / "sign-macos-app.sh",
			"--app",
			app,
			"--identity",
			identity,
			"--keychain",
			keychain,
			"--mode",
			"release",
		],
		env=invalid_env,
	)

	wrong_team_env = dict(env)
	wrong_team_env["FAKE_CODESIGN_DETAILS"] = "wrong_team"
	expect_failure(
		[
			RELEASE_DIR / "sign-macos-app.sh",
			"--app",
			app,
			"--identity",
			identity,
			"--keychain",
			keychain,
			"--mode",
			"release",
		],
		env=wrong_team_env,
	)

	for version in ("A", "B"):
		dynamic_root = fixture_root / f"dynamic-{version}"
		dynamic_root.mkdir()
		dynamic_app = create_signing_fixture(dynamic_root, version=version)
		run(
			[
				RELEASE_DIR / "sign-macos-app.sh",
				"--app",
				dynamic_app,
				"--identity",
				identity,
				"--keychain",
				keychain,
				"--mode",
				"release",
			],
			env=env,
		)

	escape_root = fixture_root / "escape"
	escape_root.mkdir()
	escape_app = create_signing_fixture(
		escape_root,
		current_target="../B",
	)
	expect_failure(
		[
			RELEASE_DIR / "sign-macos-app.sh",
			"--app",
			escape_app,
			"--identity",
			identity,
			"--keychain",
			keychain,
			"--mode",
			"release",
		],
		env=env,
	)

	unknown_root = fixture_root / "unknown"
	unknown_root.mkdir()
	unknown_app = create_signing_fixture(unknown_root, unknown_graph=True)
	expect_failure(
		[
			RELEASE_DIR / "sign-macos-app.sh",
			"--app",
			unknown_app,
			"--identity",
			identity,
			"--keychain",
			keychain,
			"--mode",
			"release",
		],
		env=env,
	)
	extra_version_root = fixture_root / "extra-version"
	extra_version_root.mkdir()
	extra_version_app = create_signing_fixture(extra_version_root)
	(
		extra_version_app
		/ "Contents/Frameworks/Sparkle.framework/Versions/A/Unexpected"
	).mkdir(parents=True)
	expect_failure(
		[
			RELEASE_DIR / "sign-macos-app.sh",
			"--app",
			extra_version_app,
			"--identity",
			identity,
			"--keychain",
			keychain,
			"--mode",
			"release",
		],
		env=env,
	)


def test_appcast(tmp: Path) -> None:
	fixture_root = tmp / "appcast"
	fixture_root.mkdir()
	archive = fixture_root / ARCHIVE_NAME
	archive.write_bytes(b"final-zip-bytes")
	appcast = fixture_root / APPCAST_NAME
	log_path = fixture_root / "sign-update.jsonl"
	sign_update = fixture_root / "sign_update"
	write_executable(
		sign_update,
		"""#!/usr/bin/env python3
import base64
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
with Path(os.environ["SIGN_UPDATE_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(args) + "\\n")
sys.stdin.read()
if "--verify" not in args:
    print(base64.b64encode(bytes(64)).decode("ascii"))
""",
	)
	env = os.environ.copy()
	env.update(
		{
			"DESKHELM_SPARKLE_PRIVATE_ED_KEY": "fixture-private-key",
			"SIGN_UPDATE_LOG": str(log_path),
			"SPARKLE_SIGN_UPDATE": str(sign_update),
		}
	)
	run(
		[
			RELEASE_DIR / "sparkle-appcast.sh",
			"--archive",
			archive,
			"--appcast",
			appcast,
			"--version",
			"1.2.3",
			"--tag",
			"v1.2.3",
		],
		env=env,
	)
	root = ET.parse(appcast).getroot()
	item = root.find("./channel/item")
	assert item is not None
	assert item.findtext(f"{{{SPARKLE_NAMESPACE}}}minimumSystemVersion") == "14.0.0"
	enclosure = item.find("enclosure")
	assert enclosure is not None
	assert enclosure.get("length") == str(archive.stat().st_size)
	assert enclosure.get("url") == (
		f"https://github.com/{CANONICAL_REPOSITORY}/releases/download/v1.2.3/{ARCHIVE_NAME}"
	)
	calls = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
	assert len(calls) == 2
	assert "-p" in calls[0]
	assert "--verify" in calls[1]

	wrong_env = dict(env)
	wrong_env.pop("DESKHELM_SPARKLE_PRIVATE_ED_KEY")
	wrong_env["SPARKLE_PRIVATE_ED_KEY"] = "forbidden-generic-key"
	expect_failure(
		[
			RELEASE_DIR / "sparkle-appcast.sh",
			"--archive",
			archive,
			"--appcast",
			appcast,
			"--version",
			"1.2.3",
			"--tag",
			"v1.2.3",
		],
		env=wrong_env,
	)
	both_env = dict(env)
	both_env["SPARKLE_PRIVATE_ED_KEY"] = "forbidden-generic-key"
	expect_failure(
		[
			RELEASE_DIR / "sparkle-appcast.sh",
			"--archive",
			archive,
			"--appcast",
			appcast,
			"--version",
			"1.2.3",
			"--tag",
			"v1.2.3",
		],
		env=both_env,
	)


def test_sparkle_key_verifier(tmp: Path) -> None:
	if sys.platform != "darwin":
		return
	swift = shutil.which("swift")
	if swift is None:
		raise AssertionError("swift is required for the macOS Sparkle key self-check")
	generator = tmp / "generate-sparkle-key.swift"
	generator.write_text(
		"""\
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
let legacySecret = Data(repeating: 0x5a, count: 64) + key.publicKey.rawRepresentation
print(legacySecret.base64EncodedString())
""",
		encoding="utf-8",
	)
	generated = run([swift, generator]).stdout.splitlines()
	assert len(generated) == 3
	private_key, public_key, legacy_private_key = generated
	verifier = RELEASE_DIR / "verify-sparkle-key.swift"
	run([verifier, public_key], input_text=f"{private_key}\n")
	run([verifier, public_key], input_text=f"{legacy_private_key}\n")
	wrong_public_key = base64.b64encode(bytes(32)).decode("ascii")
	expect_failure([verifier, wrong_public_key], input_text=f"{private_key}\n")
	expect_failure([verifier, wrong_public_key], input_text=f"{legacy_private_key}\n")
	invalid_length_key = base64.b64encode(bytes(64)).decode("ascii")
	expect_failure([verifier, public_key], input_text=f"{invalid_length_key}\n")
	expect_failure([verifier, "not-base64"], input_text=f"{private_key}\n")


def write_artifact_fixture(
	root: Path,
	*,
	current_version: str = "B",
	current_target: str | None = None,
	unknown_graph: bool = False,
	extra_version: bool = False,
	duplicate_member: bool = False,
	oversized_symlink_target: bool = False,
) -> tuple[Path, Path, Path, Path, Path]:
	archive = root / ARCHIVE_NAME
	appcast = root / APPCAST_NAME
	checksum = root / CHECKSUM_NAME
	main_plist = plistlib.dumps(
		{
			"CFBundleName": "DeskHelm",
			"CFBundleDisplayName": "DeskHelm",
			"CFBundleIdentifier": "com.acgbox.deskhelm",
			"CFBundleShortVersionString": "1.2.3",
			"CFBundleVersion": "1.2.3",
			"LSMinimumSystemVersion": "14.0",
			"LSUIElement": True,
			"NSHighResolutionCapable": True,
			"NSPrincipalClass": "NSApplication",
			"SUFeedURL": (
				f"https://github.com/{CANONICAL_REPOSITORY}/releases/latest/download/{APPCAST_NAME}"
			),
			"SUEnableAutomaticChecks": True,
			"SUAllowsAutomaticUpdates": True,
			"SUScheduledCheckInterval": 86400,
			"SUPublicEDKey": PUBLIC_KEY,
		},
		fmt=plistlib.FMT_BINARY,
	)
	framework_plist = plistlib.dumps(
		{
			"CFBundleIdentifier": "org.sparkle-project.Sparkle",
			"CFBundleShortVersionString": "2.9.4",
		},
		fmt=plistlib.FMT_BINARY,
	)
	with zipfile.ZipFile(archive, "w") as bundle:
		current_info = zipfile.ZipInfo(
			"DeskHelm.app/Contents/Frameworks/Sparkle.framework/Versions/Current"
		)
		current_info.create_system = 3
		current_info.external_attr = (stat.S_IFLNK | 0o777) << 16
		current_link_target = current_target or current_version
		if oversized_symlink_target:
			current_link_target = "B" * 257
		bundle.writestr(current_info, current_link_target)
		bundle.writestr("DeskHelm.app/Contents/Info.plist", main_plist)
		if duplicate_member:
			with warnings.catch_warnings():
				warnings.simplefilter("ignore", UserWarning)
				bundle.writestr("DeskHelm.app/Contents/Info.plist", main_plist)
		bundle.writestr("DeskHelm.app/Contents/MacOS/DeskHelmMac", b"mach-o")
		for relative_path in (
			"Sparkle",
			"Autoupdate",
			"Updater.app/Contents/Info.plist",
			"XPCServices/Installer.xpc/Contents/Info.plist",
			"XPCServices/Downloader.xpc/Contents/Info.plist",
		):
			bundle.writestr(
				"DeskHelm.app/Contents/Frameworks/Sparkle.framework/Versions/"
				+ current_version
				+ "/"
				+ relative_path,
				b"fixture",
			)
		if unknown_graph:
			bundle.writestr(
				"DeskHelm.app/Contents/Frameworks/Sparkle.framework/Versions/"
				+ current_version
				+ "/XPCServices/Unknown.xpc/Contents/Info.plist",
				b"fixture",
			)
		if extra_version:
			bundle.writestr(
				"DeskHelm.app/Contents/Frameworks/Sparkle.framework/Versions/"
				"A/Unexpected",
				b"fixture",
			)
		bundle.writestr(
			"DeskHelm.app/Contents/Frameworks/Sparkle.framework/Versions/"
			+ current_version
			+ "/Resources/Info.plist",
			framework_plist,
		)

	signature = base64.b64encode(bytes(64)).decode("ascii")
	rss = ET.Element("rss", {"version": "2.0"})
	channel = ET.SubElement(rss, "channel")
	item = ET.SubElement(channel, "item")
	release_url = f"https://github.com/{CANONICAL_REPOSITORY}/releases/tag/v1.2.3"
	ET.SubElement(item, "link").text = release_url
	ET.SubElement(item, f"{{{SPARKLE_NAMESPACE}}}version").text = "1.2.3"
	ET.SubElement(item, f"{{{SPARKLE_NAMESPACE}}}shortVersionString").text = "1.2.3"
	ET.SubElement(item, f"{{{SPARKLE_NAMESPACE}}}minimumSystemVersion").text = "14.0.0"
	ET.SubElement(item, f"{{{SPARKLE_NAMESPACE}}}hardwareRequirements").text = "arm64"
	ET.SubElement(item, f"{{{SPARKLE_NAMESPACE}}}releaseNotesLink").text = release_url
	ET.SubElement(
		item,
		"enclosure",
		{
			"url": (
				f"https://github.com/{CANONICAL_REPOSITORY}/releases/download/"
				f"v1.2.3/{ARCHIVE_NAME}"
			),
			f"{{{SPARKLE_NAMESPACE}}}edSignature": signature,
			"length": str(archive.stat().st_size),
			"type": "application/octet-stream",
		},
	)
	ET.ElementTree(rss).write(appcast, encoding="utf-8", xml_declaration=True)
	archive_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
	checksum.write_text(f"{archive_digest}  {ARCHIVE_NAME}\n", encoding="utf-8")

	local_assets = {path.name: path for path in (archive, appcast, checksum)}
	release_json = root / "release.json"
	assets_json = root / "assets.json"
	draft_slug = "untagged-fixture-123"
	release_json.write_text(
		json.dumps(
			{
				"id": 123,
				"tag_name": "v1.2.3",
				"draft": True,
				"prerelease": False,
				"html_url": (
					f"https://github.com/{CANONICAL_REPOSITORY}/releases/tag/{draft_slug}"
				),
			}
		),
		encoding="utf-8",
	)
	assets_json.write_text(
		json.dumps(
			[
				{
					"name": name,
					"state": "uploaded",
					"size": path.stat().st_size,
					"browser_download_url": (
						f"https://github.com/{CANONICAL_REPOSITORY}/releases/download/"
						f"{draft_slug}/{name}"
					),
					"digest": f"sha256:{hashlib.sha256(path.read_bytes()).hexdigest()}",
				}
				for name, path in local_assets.items()
			]
		),
		encoding="utf-8",
	)
	return archive, appcast, checksum, release_json, assets_json


def test_artifact_validator(tmp: Path) -> None:
	fixture_root = tmp / "artifacts"
	fixture_root.mkdir()
	archive, appcast, checksum, release_json, assets_json = write_artifact_fixture(fixture_root)
	validator = RELEASE_DIR / "validate-release-artifacts.py"
	args = [
		validator,
		"--archive",
		archive,
		"--appcast",
		appcast,
		"--checksum",
		checksum,
		"--release-json",
		release_json,
		"--assets-json",
		assets_json,
		"--version",
		"1.2.3",
		"--sparkle-version",
		"2.9.4",
		"--sparkle-public-key",
		PUBLIC_KEY,
		"--tag",
		"v1.2.3",
		"--repository",
		CANONICAL_REPOSITORY,
		"--release-state",
		"draft",
	]
	run(args)
	for name, fixture_options, should_pass in (
		("current-a", {"current_version": "A"}, True),
		(
			"current-escape",
			{"current_version": "B", "current_target": "../B"},
			False,
		),
		("unknown-graph", {"unknown_graph": True}, False),
		("extra-version", {"extra_version": True}, False),
		("duplicate-member", {"duplicate_member": True}, False),
		(
			"oversized-symlink-target",
			{"oversized_symlink_target": True},
			False,
		),
	):
		variant_root = fixture_root / name
		variant_root.mkdir()
		variant = write_artifact_fixture(variant_root, **fixture_options)
		variant_args = list(args)
		for option, path in zip(
			("--archive", "--appcast", "--checksum", "--release-json", "--assets-json"),
			variant,
		):
			variant_args[variant_args.index(option) + 1] = path
		if should_pass:
			run(variant_args)
		else:
			expect_failure(variant_args)
	doctype_root = fixture_root / "doctype-appcast"
	doctype_root.mkdir()
	doctype_variant = write_artifact_fixture(doctype_root)
	doctype_appcast = doctype_variant[1]
	doctype_appcast.write_bytes(
		doctype_appcast.read_bytes().replace(
			b"?>",
			b"?>\n<!DOCTYPE rss []>",
			1,
		)
	)
	doctype_args = list(args)
	for option, path in zip(
		("--archive", "--appcast", "--checksum", "--release-json", "--assets-json"),
		doctype_variant,
	):
		doctype_args[doctype_args.index(option) + 1] = path
	expect_failure(doctype_args)
	wrong_key_args = list(args)
	wrong_key_args[wrong_key_args.index("--sparkle-public-key") + 1] = (
		base64.b64encode(bytes(reversed(range(32)))).decode("ascii")
	)
	expect_failure(wrong_key_args)
	malformed_key_args = list(args)
	malformed_key_args[malformed_key_args.index("--sparkle-public-key") + 1] = "not-base64"
	expect_failure(malformed_key_args)
	published_release = json.loads(release_json.read_text(encoding="utf-8"))
	published_release["draft"] = False
	published_release["html_url"] = (
		f"https://github.com/{CANONICAL_REPOSITORY}/releases/tag/v1.2.3"
	)
	release_json.write_text(json.dumps(published_release), encoding="utf-8")
	published_assets = json.loads(assets_json.read_text(encoding="utf-8"))
	for asset in published_assets:
		asset["browser_download_url"] = (
			f"https://github.com/{CANONICAL_REPOSITORY}/releases/download/"
			f"v1.2.3/{asset['name']}"
		)
	assets_json.write_text(json.dumps(published_assets), encoding="utf-8")
	published_args = ["published" if value == "draft" else value for value in args]
	run(published_args)
	original_checksum = checksum.read_text(encoding="utf-8")
	checksum.write_text(f"{'0' * 64}  {ARCHIVE_NAME}\n", encoding="utf-8")
	expect_failure(published_args)
	checksum.write_text(original_checksum, encoding="utf-8")


def test_publisher(tmp: Path) -> None:
	node = os.environ.get("DESKHELM_NODE_BIN") or shutil.which("node")
	if node is None:
		raise AssertionError("Node.js is required for the publisher self-check")
	run(
		[
			node,
			"--test",
			ROOT / "scripts/release/publish-github-release.test.ts",
		]
	)


def test_package_orchestrator(tmp: Path) -> None:
	fixture_root = tmp / "package"
	tools = fixture_root / "tools"
	runner_temp = fixture_root / "runner-temp"
	output = fixture_root / "output"
	tools.mkdir(parents=True)
	runner_temp.mkdir()
	log_path = fixture_root / "tools.jsonl"

	def tool(name: str, body: str) -> Path:
		path = tools / name
		write_executable(path, body)
		return path

	fake_uname = tool("uname", "#!/bin/sh\nprintf 'arm64\\n'\n")
	fake_security = tool(
		"security",
		"""#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["RELEASE_TOOL_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(["security", *args]) + "\\n")
if args and args[0] == "create-keychain":
    Path(args[-1]).touch()
elif args and args[0] == "find-identity":
    print('  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: DeskHelm Release (RD3D4LH465)"')
    if os.environ.get("FAKE_SECURITY_MULTIPLE") == "1":
        print('  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Unexpected (OTHERTEAM1)"')
""",
	)
	fake_build = tool(
		"build",
		f"""#!/usr/bin/env python3
import os
import plistlib
from pathlib import Path
secret_names = (
    "APPLE_SIGNING_IDENTITY",
    "APPLE_CERTIFICATE_P12_BASE64",
    "APPLE_CERTIFICATE_PASSWORD",
    "DESKHELM_SPARKLE_PRIVATE_ED_KEY",
)
leaked = [name for name in secret_names if name in os.environ]
if leaked:
    raise SystemExit(f"release credentials leaked to build: {{leaked}}")
app = Path(os.environ["DESKHELM_APP_STAGE_DIR"]) / "DeskHelm.app"
work_root = app.parents[1]
if (work_root / "apple-development.p12").exists():
    raise SystemExit("release credentials were materialized before the build completed")
(app / "Contents/MacOS").mkdir(parents=True)
(app / "Contents/MacOS/DeskHelmMac").write_bytes(b"mach-o")
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({{"SUPublicEDKey": "{PUBLIC_KEY}"}}))
""",
	)
	fake_key_verifier = tool("key-verifier", "#!/bin/sh\ncat >/dev/null\n")
	fake_sign = tool(
		"sign",
		"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with Path(os.environ["RELEASE_TOOL_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(["sign", *sys.argv[1:]]) + "\\n")
""",
	)
	fake_validator = tool("validator", "#!/bin/sh\nexit 0\n")
	fake_codesign = tool(
		"codesign",
		"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with Path(os.environ["RELEASE_TOOL_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(["codesign", *sys.argv[1:]]) + "\\n")
""",
	)
	fake_ditto = tool(
		"ditto",
		"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["RELEASE_TOOL_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(["ditto", *args]) + "\\n")
Path(args[-1]).write_bytes(b"zip-bytes")
""",
	)
	fake_appcast = tool(
		"appcast",
		"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["RELEASE_TOOL_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(["appcast", *args]) + "\\n")
Path(args[args.index("--appcast") + 1]).write_text("<rss/>", encoding="utf-8")
""",
	)
	public_key_file = fixture_root / "sparkle-public-ed-key.txt"
	public_key_file.write_text(f"{PUBLIC_KEY}\n", encoding="utf-8")

	env = os.environ.copy()
	for key in ("SPARKLE_PRIVATE_ED_KEY", "SPARKLE_PUBLIC_ED_KEY"):
		env.pop(key, None)
	env.update(
		{
			"APPLE_SIGNING_IDENTITY": (
				"Apple Development: DeskHelm Release (RD3D4LH465)"
			),
			"APPLE_CERTIFICATE_P12_BASE64": base64.b64encode(b"cert").decode(),
			"APPLE_CERTIFICATE_PASSWORD": "fixture-password",
			"ImageOS": "macos26",
			"RELEASE_TOOL_LOG": str(log_path),
			"DESKHELM_APPCAST_BIN": str(fake_appcast),
			"DESKHELM_ARTIFACT_VALIDATOR_BIN": str(fake_validator),
			"DESKHELM_BUILD_AND_RUN_BIN": str(fake_build),
			"DESKHELM_CODESIGN_BIN": str(fake_codesign),
			"DESKHELM_DITTO_BIN": str(fake_ditto),
			"DESKHELM_PYTHON_BIN": sys.executable,
			"DESKHELM_RELEASE_OUTPUT_DIR": str(output),
			"DESKHELM_RELEASE_TAG": "v1.2.3",
			"DESKHELM_RELEASE_VERSION": "1.2.3",
			"DESKHELM_SECURITY_BIN": str(fake_security),
			"DESKHELM_SIGN_APP_BIN": str(fake_sign),
			"DESKHELM_SPARKLE_PRIVATE_ED_KEY": "fixture-private-key",
			"DESKHELM_SPARKLE_PUBLIC_KEY_FILE": str(public_key_file),
			"DESKHELM_SPARKLE_VERSION": "2.9.4",
			"DESKHELM_UNAME_BIN": str(fake_uname),
			"DESKHELM_VERIFY_SPARKLE_KEY_BIN": str(fake_key_verifier),
			"RUNNER_ARCH": "ARM64",
			"RUNNER_TEMP": str(runner_temp),
		}
	)
	package_script = RELEASE_DIR / "package-macos.sh"
	run([package_script], env=env)
	assert (output / ARCHIVE_NAME).is_file()
	assert (output / APPCAST_NAME).is_file()
	assert (output / CHECKSUM_NAME).is_file()
	calls = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()]
	tool_names = [call[0] for call in calls]
	final_zip_index = max(index for index, call in enumerate(calls) if call[0] == "ditto")
	appcast_index = tool_names.index("appcast")
	assert tool_names.index("sign") < final_zip_index < appcast_index

	missing_credential_env = dict(env)
	missing_credential_env.pop("APPLE_SIGNING_IDENTITY")
	log_before_missing_credential = log_path.read_text(encoding="utf-8")
	expect_failure([package_script], env=missing_credential_env)
	assert log_path.read_text(encoding="utf-8") == log_before_missing_credential

	multiple_identity_env = dict(env)
	multiple_identity_env["FAKE_SECURITY_MULTIPLE"] = "1"
	expect_failure([package_script], env=multiple_identity_env)


def test_static_contracts() -> None:
	for script in (
		ROOT / "script/build_and_run.sh",
		RELEASE_DIR / "package-macos.sh",
		RELEASE_DIR / "sign-macos-app.sh",
		RELEASE_DIR / "sparkle-appcast.sh",
	):
		run(["bash", "-n", script])
	for script in (
		RELEASE_DIR / "self-check.py",
		RELEASE_DIR / "validate-release-artifacts.py",
	):
		compile(script.read_text(encoding="utf-8"), str(script), "exec")

	release_workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
	language_workflow = (ROOT / ".github/workflows/language.yml").read_text(encoding="utf-8")
	build_script = (ROOT / "script/build_and_run.sh").read_text(encoding="utf-8")
	publisher_script = (ROOT / "scripts/release/publish-github-release.ts").read_text(
		encoding="utf-8"
	)
	assert "/usr/bin/xcode-select --print-path" in build_script
	assert "Xcode beta is required" not in build_script
	assert "/usr/bin/plutil -create binary1" in build_script
	assert "/usr/bin/plutil -convert binary1" in build_script
	assert "workflow_dispatch" not in release_workflow
	assert "Release Preparation" not in release_workflow
	assert "Release Prep" not in release_workflow
	assert "Release Dry Run" not in release_workflow
	assert "permissions:\n  contents: read" in release_workflow
	assert "concurrency:\n  group: release\n  cancel-in-progress: false" in release_workflow
	assert release_workflow.count("contents: write") == 1
	assert release_workflow.count("name: release") == 1
	assert "runs-on: macos-26" in release_workflow
	assert release_workflow.count("node-version-file: .node-version") == 3
	assert "needs: validate-release" in release_workflow
	assert "needs: [validate-release, build-macos]" in release_workflow
	assert "DESKHELM_SPARKLE_PRIVATE_ED_KEY" in release_workflow
	assert "DESKHELM_SPARKLE_PUBLIC_ED_KEY" not in release_workflow
	assert "APPLE_CERTIFICATE_P12_BASE64" in release_workflow
	assert "APPLE_CERTIFICATE_PASSWORD" in release_workflow
	assert "APPLE_SIGNING_IDENTITY" in release_workflow
	assert "APPLE_NOTARY_" not in release_workflow
	assert "APPLE_DEVELOPER_ID_" not in release_workflow
	assert re.search(r"^\s+SPARKLE_PRIVATE_ED_KEY:", release_workflow, re.MULTILINE) is None
	assert re.search(r"^\s+SPARKLE_PUBLIC_ED_KEY:", release_workflow, re.MULTILINE) is None
	assert "EXPECTED_APPLE_TEAM_ID=\"RD3D4LH465\"" in (
		RELEASE_DIR / "package-macos.sh"
	).read_text(encoding="utf-8")
	assert "EXPECTED_APPLE_TEAM_ID=\"RD3D4LH465\"" in (
		RELEASE_DIR / "sign-macos-app.sh"
	).read_text(encoding="utf-8")
	assert "--verify-appcast-signature" in publisher_script
	assert "make_latest: 'true'" in publisher_script
	assert "releases/tags/" not in publisher_script
	assert "https://uploads.github.com" in publisher_script
	assert "release upload" not in publisher_script
	assert "DESKHELM_GH_BIN" not in publisher_script
	for match in re.finditer(r"^\s*uses:\s*[^\s]+@([^\s]+)", release_workflow, re.MULTILINE):
		assert re.fullmatch(r"[0-9a-f]{40}", match.group(1)), match.group(0)
	for required in (
		"rust-check:",
		"toml-check:",
		"typescript-check:",
		"pull_request:",
		"merge_group:",
	):
		assert required in language_workflow
	assert "swift-check:" not in language_workflow
	assert "runs-on: macos-" not in language_workflow
	assert 'cd "$RUNNER_TEMP"' in language_workflow
	assert (
		"npm install --global --ignore-scripts --no-audit --no-fund npm@11.16.0"
		in language_workflow
	)
	assert 'test "$(npm --version)" = "11.16.0"' in language_workflow
	assert 'cd "$workspace"\n          npm ci --ignore-scripts' in language_workflow

	tracked_paths = run(
		["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
		cwd=ROOT,
	).stdout.split("\0")
	tracked_text = "\n".join(
		(ROOT / relative_path).read_text(encoding="utf-8", errors="ignore")
		for relative_path in tracked_paths
		if relative_path
		and (ROOT / relative_path).exists()
		and (ROOT / relative_path).stat().st_size < 2_000_000
	)
	assert ("acg" + "xv/deskhelm") not in tracked_text


def main() -> int:
	with tempfile.TemporaryDirectory(prefix="deskhelm-release-self-check-") as temp_dir:
		tmp = Path(temp_dir)
		test_source_validator(tmp)
		test_signer(tmp)
		test_appcast(tmp)
		test_sparkle_key_verifier(tmp)
		test_artifact_validator(tmp)
		test_publisher(tmp)
		test_package_orchestrator(tmp)
	test_static_contracts()
	print("release self-check passed")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
