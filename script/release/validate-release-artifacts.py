#!/usr/bin/env python3
"""Validate DeskHelm release app, archive, appcast, checksum, and release metadata."""

from __future__ import annotations

import argparse
import base64
import binascii
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
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any


CANONICAL_REPOSITORY = "acg-box/deskhelm"
APP_NAME = "DeskHelm.app"
APP_EXECUTABLE = "DeskHelmMac"
APP_BUNDLE_ID = "com.acgbox.deskhelm"
ARCHIVE_NAME = "deskhelm-aarch64-apple-darwin.zip"
APPCAST_NAME = "appcast.xml"
CHECKSUM_NAME = f"{ARCHIVE_NAME}.sha256"
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MAX_APPCAST_BYTES = 256 * 1024
MAX_PLIST_BYTES = 1024 * 1024
MAX_ZIP_ENTRIES = 10_000
MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024
MAX_ZIP_PATH_BYTES = 1024
MAX_ZIP_METADATA_BYTES = 4 * 1024 * 1024
MAX_ZIP_SYMLINK_TARGET_BYTES = 256
SEMVER_COMPONENT = r"(?:0|[1-9][0-9]*)"
STABLE_VERSION_RE = re.compile(
	rf"^{SEMVER_COMPONENT}\.{SEMVER_COMPONENT}\.{SEMVER_COMPONENT}$"
)


class ValidationError(RuntimeError):
	"""A release artifact contract failed."""


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--version", required=True)
	parser.add_argument("--sparkle-version", required=True)
	parser.add_argument("--sparkle-public-key", required=True)
	parser.add_argument("--tag", required=True)
	parser.add_argument("--repository", required=True)
	parser.add_argument("--app", type=Path)
	parser.add_argument("--archive", type=Path)
	parser.add_argument("--appcast", type=Path)
	parser.add_argument("--checksum", type=Path)
	parser.add_argument("--release-json", type=Path)
	parser.add_argument("--assets-json", type=Path)
	parser.add_argument("--release-state", choices=("draft", "published"))
	parser.add_argument("--verify-appcast-signature", action="store_true")
	return parser.parse_args()


def fail(message: str) -> None:
	raise ValidationError(message)


def read_bounded_file(path: Path, *, max_bytes: int, source: str) -> bytes:
	try:
		with path.open("rb") as handle:
			data = handle.read(max_bytes + 1)
	except OSError as error:
		fail(f"cannot read {source}: {error}")
	if len(data) > max_bytes:
		fail(f"{source} exceeds the {max_bytes}-byte limit")
	return data


def reject_xml_declarations(data: bytes, *, source: str) -> None:
	upper = data.upper()
	if b"<!DOCTYPE" in upper or b"<!ENTITY" in upper:
		fail(f"{source} must not contain DOCTYPE or ENTITY declarations")


def read_plist_bytes(data: bytes, source: str) -> dict[str, Any]:
	if len(data) > MAX_PLIST_BYTES:
		fail(f"plist at {source} exceeds the {MAX_PLIST_BYTES}-byte limit")
	reject_xml_declarations(data, source=f"plist at {source}")
	try:
		plist = plistlib.loads(data)
	except plistlib.InvalidFileException as error:
		fail(f"invalid plist at {source}: {error}")
	if not isinstance(plist, dict):
		fail(f"plist at {source} is not a dictionary")
	return plist


def read_plist_file(path: Path) -> dict[str, Any]:
	return read_plist_bytes(
		read_bounded_file(path, max_bytes=MAX_PLIST_BYTES, source=str(path)),
		str(path),
	)


def decode_public_key(value: object, *, source: str) -> bytes:
	if not isinstance(value, str) or not value:
		fail(f"{source} must be a non-empty base64 string")
	try:
		decoded = base64.b64decode(value, validate=True)
	except (ValueError, binascii.Error) as error:
		fail(f"{source} is not valid base64: {error}")
	if len(decoded) != 32:
		fail(f"{source} must decode to a 32-byte Ed25519 public key")
	return decoded


def validate_public_key(value: object, *, expected_public_key: str) -> None:
	decode_public_key(value, source="SUPublicEDKey")
	if value != expected_public_key:
		fail("SUPublicEDKey does not match the required DeskHelm update key")


def validate_main_plist(
	plist: dict[str, Any],
	*,
	version: str,
	repository: str,
	sparkle_public_key: str,
) -> None:
	expected_feed = f"https://github.com/{repository}/releases/latest/download/{APPCAST_NAME}"
	expected_values = {
		"CFBundleName": "DeskHelm",
		"CFBundleDisplayName": "DeskHelm",
		"CFBundleIdentifier": APP_BUNDLE_ID,
		"CFBundleShortVersionString": version,
		"CFBundleVersion": version,
		"LSMinimumSystemVersion": "14.0",
		"LSUIElement": True,
		"NSHighResolutionCapable": True,
		"NSPrincipalClass": "NSApplication",
		"SUFeedURL": expected_feed,
		"SUEnableAutomaticChecks": True,
		"SUAllowsAutomaticUpdates": True,
		"SUScheduledCheckInterval": 86400,
	}
	for key, expected in expected_values.items():
		actual = plist.get(key)
		if actual != expected:
			fail(f"{key} must be {expected!r}, got {actual!r}")
	validate_public_key(
		plist.get("SUPublicEDKey"),
		expected_public_key=sparkle_public_key,
	)


def validate_sparkle_plist(plist: dict[str, Any], *, sparkle_version: str) -> None:
	if plist.get("CFBundleIdentifier") != "org.sparkle-project.Sparkle":
		fail("embedded framework is not org.sparkle-project.Sparkle")
	actual_version = plist.get("CFBundleShortVersionString")
	if actual_version != sparkle_version:
		fail(
			f"embedded Sparkle version {actual_version!r} does not match {sparkle_version}"
		)


def validate_app(
	path: Path,
	*,
	version: str,
	sparkle_version: str,
	repository: str,
	sparkle_public_key: str,
) -> None:
	if path.name != APP_NAME or not path.is_dir():
		fail(f"app bundle must be an existing {APP_NAME}: {path}")
	main_executable = path / "Contents/MacOS" / APP_EXECUTABLE
	if not main_executable.is_file():
		fail(f"main executable is missing: {main_executable}")
	main_plist = read_plist_file(path / "Contents/Info.plist")
	validate_main_plist(
		main_plist,
		version=version,
		repository=repository,
		sparkle_public_key=sparkle_public_key,
	)

	framework = path / "Contents/Frameworks/Sparkle.framework"
	versions_root = framework / "Versions"
	current_link = framework / "Versions/Current"
	if not current_link.is_symlink():
		fail("Sparkle Versions/Current must be a symbolic link")
	current_target = current_link.readlink()
	if (
		current_target.is_absolute()
		or len(current_target.parts) != 1
		or current_target.name in ("", ".", "..", "Current")
		or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", current_target.name) is None
	):
		fail("Sparkle Versions/Current must name one direct Versions child")
	version_root = versions_root / current_target
	try:
		resolved_versions = versions_root.resolve(strict=True)
		resolved_version = version_root.resolve(strict=True)
	except OSError as error:
		fail(f"Sparkle Versions/Current target cannot be resolved: {error}")
	if resolved_version.parent != resolved_versions:
		fail("Sparkle Versions/Current must resolve to one direct Versions child")
	if version_root.is_symlink() or not version_root.is_dir():
		fail("Sparkle Versions/Current target must be one real directory")
	actual_version_entries = {entry.name for entry in versions_root.iterdir()}
	expected_version_entries = {"Current", current_target.name}
	if actual_version_entries != expected_version_entries:
		fail("Sparkle Versions must contain only Current and its selected version")
	for relative_path in (
		"Sparkle",
		"Autoupdate",
		"Updater.app",
		"XPCServices/Installer.xpc",
		"XPCServices/Downloader.xpc",
	):
		if not (version_root / relative_path).exists():
			fail(f"embedded Sparkle code is missing: {relative_path}")
	expected_nested_bundles = {
		version_root / "Updater.app",
		version_root / "XPCServices/Installer.xpc",
		version_root / "XPCServices/Downloader.xpc",
	}
	actual_nested_bundles = {
		nested
		for suffix in ("*.app", "*.xpc")
		for nested in version_root.rglob(suffix)
		if nested.is_dir()
	}
	if actual_nested_bundles != expected_nested_bundles:
		fail("embedded Sparkle nested code graph is not the exact known graph")
	framework_plist = read_plist_file(version_root / "Resources/Info.plist")
	validate_sparkle_plist(framework_plist, sparkle_version=sparkle_version)


def zip_read(
	archive: zipfile.ZipFile,
	member: str,
	*,
	max_bytes: int,
) -> bytes:
	try:
		info = archive.getinfo(member)
	except KeyError:
		fail(f"release archive is missing {member}")
	if info.file_size > max_bytes:
		fail(f"archived {member} exceeds the {max_bytes}-byte limit")
	try:
		data = archive.read(info)
	except (OSError, RuntimeError, zipfile.BadZipFile) as error:
		fail(f"cannot read archived {member}: {error}")
	if len(data) > max_bytes:
		fail(f"archived {member} exceeds the {max_bytes}-byte limit")
	return data
	return b""


def zip_require_member(archive: zipfile.ZipFile, member: str) -> None:
	try:
		archive.getinfo(member)
	except KeyError:
		fail(f"release archive is missing {member}")


def validate_zip_directory(archive: zipfile.ZipFile) -> None:
	infos = archive.infolist()
	if len(infos) > MAX_ZIP_ENTRIES:
		fail(f"release archive exceeds the {MAX_ZIP_ENTRIES}-entry limit")
	names = [info.filename for info in infos]
	if len(set(names)) != len(names):
		fail("release archive contains duplicate member names")
	total_uncompressed = 0
	total_metadata = len(archive.comment)
	for info in infos:
		filename_bytes = info.filename.encode("utf-8")
		if len(filename_bytes) > MAX_ZIP_PATH_BYTES:
			fail(f"release archive member path exceeds {MAX_ZIP_PATH_BYTES} bytes")
		path = PurePosixPath(info.filename)
		if (
			not info.filename
			or path.is_absolute()
			or any(part in ("", ".", "..") for part in path.parts)
		):
			fail(f"release archive contains an unsafe member path: {info.filename!r}")
		if info.flag_bits & 0x1:
			fail(f"release archive member must not be encrypted: {info.filename}")
		total_uncompressed += info.file_size
		if total_uncompressed > MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES:
			fail(
				"release archive exceeds the "
				f"{MAX_ZIP_TOTAL_UNCOMPRESSED_BYTES}-byte uncompressed limit"
			)
		total_metadata += len(filename_bytes) + len(info.extra) + len(info.comment)
		if total_metadata > MAX_ZIP_METADATA_BYTES:
			fail(f"release archive metadata exceeds the {MAX_ZIP_METADATA_BYTES}-byte limit")


def zip_current_version(archive: zipfile.ZipFile) -> str:
	member = f"{APP_NAME}/Contents/Frameworks/Sparkle.framework/Versions/Current"
	try:
		info = archive.getinfo(member)
	except KeyError:
		fail("release archive is missing Sparkle Versions/Current")
	mode = info.external_attr >> 16
	if not stat.S_ISLNK(mode):
		fail("archived Sparkle Versions/Current must be a symbolic link")
	if info.file_size > MAX_ZIP_SYMLINK_TARGET_BYTES:
		fail("archived Sparkle Versions/Current target exceeds the size limit")
	try:
		target = zip_read(
			archive,
			member,
			max_bytes=MAX_ZIP_SYMLINK_TARGET_BYTES,
		).decode("utf-8")
	except (KeyError, UnicodeDecodeError) as error:
		fail(f"archived Sparkle Versions/Current target is invalid: {error}")
	target_path = PurePosixPath(target)
	if (
		target_path.is_absolute()
		or len(target_path.parts) != 1
		or target_path.name in ("", ".", "..", "Current")
		or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", target_path.name) is None
	):
		fail("archived Sparkle Versions/Current must name one direct Versions child")
	prefix = (
		f"{APP_NAME}/Contents/Frameworks/Sparkle.framework/Versions/"
		f"{target_path.name}/"
	)
	if not any(name.startswith(prefix) for name in archive.namelist()):
		fail("archived Sparkle Versions/Current target does not exist")
	versions_prefix = f"{APP_NAME}/Contents/Frameworks/Sparkle.framework/Versions/"
	actual_version_entries = {
		remainder.split("/", maxsplit=1)[0]
		for name in archive.namelist()
		if name.startswith(versions_prefix)
		for remainder in (name.removeprefix(versions_prefix),)
		if remainder
	}
	if actual_version_entries != {"Current", target_path.name}:
		fail("archived Sparkle Versions must contain only Current and its selected version")
	return target_path.name


def validate_zip_nested_code_graph(
	archive: zipfile.ZipFile,
	*,
	current_version: str,
) -> None:
	prefix = (
		f"{APP_NAME}/Contents/Frameworks/Sparkle.framework/Versions/"
		f"{current_version}/"
	)
	expected = {
		f"{prefix}Updater.app",
		f"{prefix}XPCServices/Installer.xpc",
		f"{prefix}XPCServices/Downloader.xpc",
	}
	actual: set[str] = set()
	for name in archive.namelist():
		if not name.startswith(prefix):
			continue
		parts = PurePosixPath(name).parts
		for index, part in enumerate(parts):
			if part.endswith((".app", ".xpc")):
				candidate = "/".join(parts[: index + 1])
				if candidate.startswith(prefix):
					actual.add(candidate)
	if actual != expected:
		fail("archived Sparkle nested code graph is not the exact known graph")


def validate_archive_bundle(
	path: Path,
	*,
	version: str,
	sparkle_version: str,
	repository: str,
	sparkle_public_key: str,
) -> None:
	if path.name != ARCHIVE_NAME or not path.is_file():
		fail(f"release archive must be an existing {ARCHIVE_NAME}: {path}")
	try:
		with zipfile.ZipFile(path) as archive:
			validate_zip_directory(archive)
			names = set(archive.namelist())
			archive_roots = {
				name.split("/", maxsplit=1)[0]
				for name in names
				if name and not name.startswith("__MACOSX/")
			}
			if archive_roots != {APP_NAME}:
				fail(
					f"release archive root must be only {APP_NAME}: {sorted(archive_roots)}"
				)
			main_plist = read_plist_bytes(
				zip_read(
					archive,
					f"{APP_NAME}/Contents/Info.plist",
					max_bytes=MAX_PLIST_BYTES,
				),
				f"{path}:{APP_NAME}/Contents/Info.plist",
			)
			validate_main_plist(
				main_plist,
				version=version,
				repository=repository,
				sparkle_public_key=sparkle_public_key,
			)
			zip_require_member(archive, f"{APP_NAME}/Contents/MacOS/{APP_EXECUTABLE}")
			current_version = zip_current_version(archive)
			validate_zip_nested_code_graph(
				archive,
				current_version=current_version,
			)
			for relative_path in (
				"Sparkle",
				"Autoupdate",
				"Updater.app/Contents/Info.plist",
				"XPCServices/Installer.xpc/Contents/Info.plist",
				"XPCServices/Downloader.xpc/Contents/Info.plist",
			):
				zip_require_member(
					archive,
					f"{APP_NAME}/Contents/Frameworks/Sparkle.framework/Versions/"
					f"{current_version}/"
					f"{relative_path}",
				)
			framework_plist = read_plist_bytes(
				zip_read(
					archive,
					f"{APP_NAME}/Contents/Frameworks/Sparkle.framework/Versions/"
					f"{current_version}/"
					"Resources/Info.plist",
					max_bytes=MAX_PLIST_BYTES,
				),
				f"{path}:Sparkle.framework/Versions/{current_version}/Resources/Info.plist",
			)
			validate_sparkle_plist(framework_plist, sparkle_version=sparkle_version)
	except zipfile.BadZipFile as error:
		fail(f"invalid release ZIP: {error}")


def one_element(parent: ET.Element, path: str) -> ET.Element:
	elements = parent.findall(path)
	if len(elements) != 1:
		fail(f"appcast must contain exactly one {path}, found {len(elements)}")
	return elements[0]


def verify_appcast_signature(
	archive: Path,
	signature: bytes,
	*,
	sparkle_public_key: str,
) -> None:
	openssl_name = os.environ.get("DESKHELM_OPENSSL_BIN", "openssl")
	openssl_bin = shutil.which(openssl_name)
	if openssl_bin is None:
		fail(f"OpenSSL is required for appcast signature verification: {openssl_name}")
	public_key = decode_public_key(
		sparkle_public_key,
		source="--sparkle-public-key",
	)
	# SubjectPublicKeyInfo prefix for a raw RFC 8410 Ed25519 public key.
	public_key_der = bytes.fromhex("302a300506032b6570032100") + public_key
	with tempfile.TemporaryDirectory(prefix="deskhelm-appcast-signature-") as temp_dir:
		public_key_path = Path(temp_dir) / "public.der"
		signature_path = Path(temp_dir) / "signature.bin"
		public_key_path.write_bytes(public_key_der)
		signature_path.write_bytes(signature)
		result = subprocess.run(
			[
				openssl_bin,
				"pkeyutl",
				"-verify",
				"-pubin",
				"-inkey",
				str(public_key_path),
				"-keyform",
				"DER",
				"-rawin",
				"-in",
				str(archive),
				"-sigfile",
				str(signature_path),
			],
			capture_output=True,
			text=True,
		)
	if result.returncode != 0:
		detail = result.stderr.strip() or result.stdout.strip() or "signature mismatch"
		fail(f"appcast Ed25519 signature verification failed: {detail}")


def validate_appcast(
	path: Path,
	*,
	archive: Path,
	version: str,
	tag: str,
	repository: str,
	verify_signature: bool,
	sparkle_public_key: str,
) -> None:
	if path.name != APPCAST_NAME or not path.is_file():
		fail(f"appcast must be an existing {APPCAST_NAME}: {path}")
	data = read_bounded_file(path, max_bytes=MAX_APPCAST_BYTES, source=str(path))
	reject_xml_declarations(data, source="appcast")
	try:
		root = ET.fromstring(data)
	except ET.ParseError as error:
		fail(f"invalid appcast XML: {error}")
	if root.tag != "rss" or root.get("version") != "2.0":
		fail("appcast root must be RSS 2.0")
	item = one_element(root, "./channel/item")
	expected_release_url = f"https://github.com/{repository}/releases/tag/{tag}"
	expected_values = {
		"link": expected_release_url,
		f"{{{SPARKLE_NAMESPACE}}}version": version,
		f"{{{SPARKLE_NAMESPACE}}}shortVersionString": version,
		f"{{{SPARKLE_NAMESPACE}}}minimumSystemVersion": "14.0.0",
		f"{{{SPARKLE_NAMESPACE}}}hardwareRequirements": "arm64",
		f"{{{SPARKLE_NAMESPACE}}}releaseNotesLink": expected_release_url,
	}
	for element_name, expected in expected_values.items():
		element = one_element(item, element_name)
		if element.text != expected:
			fail(f"appcast {element_name} must be {expected!r}, got {element.text!r}")

	enclosure = one_element(item, "enclosure")
	expected_archive_url = (
		f"https://github.com/{repository}/releases/download/{tag}/{ARCHIVE_NAME}"
	)
	if enclosure.get("url") != expected_archive_url:
		fail(f"appcast enclosure URL must be {expected_archive_url}")
	if enclosure.get("type") != "application/octet-stream":
		fail("appcast enclosure type must be application/octet-stream")
	actual_length = archive.stat().st_size
	if enclosure.get("length") != str(actual_length):
		fail(
			f"appcast enclosure length must be {actual_length}, "
			f"got {enclosure.get('length')!r}"
		)
	signature = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
	if not signature:
		fail("appcast enclosure is missing sparkle:edSignature")
	try:
		decoded_signature = base64.b64decode(signature, validate=True)
	except (ValueError, binascii.Error) as error:
		fail(f"appcast EdDSA signature is not valid base64: {error}")
	if len(decoded_signature) != 64:
		fail("appcast Ed25519 signature must decode to 64 bytes")
	if verify_signature:
		verify_appcast_signature(
			archive,
			decoded_signature,
			sparkle_public_key=sparkle_public_key,
		)


def sha256(path: Path) -> str:
	digest = hashlib.sha256()
	try:
		with path.open("rb") as handle:
			for chunk in iter(lambda: handle.read(1 << 20), b""):
				digest.update(chunk)
	except OSError as error:
		fail(f"cannot hash {path}: {error}")
	return digest.hexdigest()


def validate_checksum(path: Path, *, archive: Path) -> None:
	if path.name != CHECKSUM_NAME or not path.is_file():
		fail(f"checksum must be an existing {CHECKSUM_NAME}: {path}")
	try:
		lines = [line for line in path.read_text(encoding="utf-8").splitlines() if line]
	except OSError as error:
		fail(f"cannot read checksum: {error}")
	if len(lines) != 1:
		fail("checksum file must contain exactly one non-empty line")
	match = re.fullmatch(rf"([0-9a-f]{{64}})  {re.escape(ARCHIVE_NAME)}", lines[0])
	if match is None:
		fail("checksum file must use lowercase SHA-256 and the canonical archive name")
	expected_digest = sha256(archive)
	if match.group(1) != expected_digest:
		fail("checksum does not match the final release archive")


def read_json(path: Path) -> Any:
	try:
		return json.loads(path.read_text(encoding="utf-8"))
	except (OSError, json.JSONDecodeError) as error:
		fail(f"cannot read JSON from {path}: {error}")
	return None


def validate_release_metadata(
	release_path: Path,
	assets_path: Path,
	*,
	tag: str,
	repository: str,
	release_state: str,
	local_assets: dict[str, Path],
) -> None:
	release = read_json(release_path)
	if not isinstance(release, dict):
		fail("release API response must be an object")
	if release.get("tag_name") != tag:
		fail("release tag does not match the workflow tag")
	expected_draft = release_state == "draft"
	if release.get("draft") is not expected_draft:
		fail(f"release must be {release_state} during validation")
	if release.get("prerelease") is not False:
		fail("stable DeskHelm releases must not be prereleases")
	release_url_prefix = f"https://github.com/{repository}/releases/tag/"
	release_url = release.get("html_url")
	if not isinstance(release_url, str) or not release_url.startswith(
		release_url_prefix
	):
		fail(f"release URL must use the canonical {repository} repository")
	release_slug = release_url.removeprefix(release_url_prefix)
	if release_state == "published":
		if release_slug != tag:
			fail(f"published release URL must use the canonical tag {tag}")
	elif release_slug != tag and re.fullmatch(
		r"untagged-[A-Za-z0-9][A-Za-z0-9._-]*", release_slug
	) is None:
		fail("draft release URL must use the tag or a safe GitHub untagged slug")

	assets = read_json(assets_path)
	if not isinstance(assets, list):
		fail("release assets API response must be an array")
	if len(assets) != len(local_assets):
		fail(
			"release assets do not match the exact expected count: "
			f"{len(assets)}"
		)
	assets_by_name = {
		asset.get("name"): asset
		for asset in assets
		if isinstance(asset, dict) and isinstance(asset.get("name"), str)
	}
	if set(assets_by_name) != set(local_assets):
		fail(
			"release assets do not match the exact expected set: "
			f"{sorted(assets_by_name)}"
		)
	for name, local_path in local_assets.items():
		asset = assets_by_name[name]
		if asset.get("state") != "uploaded":
			fail(f"release asset is not uploaded: {name}")
		if asset.get("size") != local_path.stat().st_size:
			fail(f"release asset size does not match local bytes: {name}")
		expected_url = (
			f"https://github.com/{repository}/releases/download/{release_slug}/{name}"
		)
		if asset.get("browser_download_url") != expected_url:
			fail(f"release asset URL must be {expected_url}")
		digest = asset.get("digest")
		if digest is not None and digest != f"sha256:{sha256(local_path)}":
			fail(f"release asset digest does not match local bytes: {name}")


def main() -> int:
	args = parse_args()
	if args.repository != CANONICAL_REPOSITORY:
		fail(
			f"release repository must be {CANONICAL_REPOSITORY}, got {args.repository}"
		)
	if STABLE_VERSION_RE.fullmatch(args.version) is None:
		fail(f"release version is not stable SemVer: {args.version}")
	if STABLE_VERSION_RE.fullmatch(args.sparkle_version) is None:
		fail(f"Sparkle version is not stable SemVer: {args.sparkle_version}")
	if args.tag != f"v{args.version}":
		fail(f"release tag {args.tag} does not match version {args.version}")
	decode_public_key(args.sparkle_public_key, source="--sparkle-public-key")

	if args.app is not None:
		validate_app(
			args.app,
			version=args.version,
			sparkle_version=args.sparkle_version,
			repository=args.repository,
			sparkle_public_key=args.sparkle_public_key,
		)

	artifact_paths = (args.archive, args.appcast, args.checksum)
	if any(path is not None for path in artifact_paths):
		if any(path is None for path in artifact_paths):
			fail("--archive, --appcast, and --checksum must be supplied together")
		archive, appcast, checksum = artifact_paths
		assert archive is not None and appcast is not None and checksum is not None
		validate_archive_bundle(
			archive,
			version=args.version,
			sparkle_version=args.sparkle_version,
			repository=args.repository,
			sparkle_public_key=args.sparkle_public_key,
		)
		validate_appcast(
			appcast,
			archive=archive,
			version=args.version,
			tag=args.tag,
			repository=args.repository,
			verify_signature=args.verify_appcast_signature,
			sparkle_public_key=args.sparkle_public_key,
		)
		validate_checksum(checksum, archive=archive)
	else:
		archive = appcast = checksum = None

	metadata_paths = (args.release_json, args.assets_json)
	if any(path is not None for path in metadata_paths):
		if any(path is None for path in metadata_paths):
			fail("--release-json and --assets-json must be supplied together")
		if archive is None or appcast is None or checksum is None:
			fail("release metadata validation requires all local release artifacts")
		if args.release_state is None:
			fail("release metadata validation requires --release-state")
		assert args.release_json is not None and args.assets_json is not None
		validate_release_metadata(
			args.release_json,
			args.assets_json,
			tag=args.tag,
			repository=args.repository,
			release_state=args.release_state,
			local_assets={
				ARCHIVE_NAME: archive,
				APPCAST_NAME: appcast,
				CHECKSUM_NAME: checksum,
			},
		)
	elif args.release_state is not None:
		fail("--release-state requires --release-json and --assets-json")

	if args.app is None and archive is None:
		fail("at least one of --app or --archive is required")
	return 0


if __name__ == "__main__":
	try:
		raise SystemExit(main())
	except ValidationError as error:
		print(f"error: {error}", file=sys.stderr)
		raise SystemExit(1) from error
