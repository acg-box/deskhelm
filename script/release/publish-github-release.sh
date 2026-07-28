#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL_REPOSITORY="acg-box/deskhelm"
ARCHIVE_NAME="deskhelm-aarch64-apple-darwin.zip"
APPCAST_NAME="appcast.xml"
CHECKSUM_NAME="${ARCHIVE_NAME}.sha256"
API_VERSION="2026-03-10"
DEFAULT_SPARKLE_PUBLIC_KEY_FILE="$ROOT_DIR/script/release/sparkle-public-ed-key.txt"

required_values=(
	GH_TOKEN
	GITHUB_REPOSITORY
	GITHUB_SHA
	DESKHELM_RELEASE_COMMIT
	DESKHELM_RELEASE_TAG
	DESKHELM_RELEASE_VERSION
	DESKHELM_SPARKLE_VERSION
)
for required_value in "${required_values[@]}"; do
	if [[ -z "${!required_value:-}" ]]; then
		echo "error: missing required publish value: $required_value" >&2
		exit 1
	fi
done
if [[ "$GITHUB_REPOSITORY" != "$CANONICAL_REPOSITORY" ]]; then
	echo "error: releases may be published only for $CANONICAL_REPOSITORY" >&2
	exit 1
fi
if [[ "$DESKHELM_RELEASE_TAG" != "v$DESKHELM_RELEASE_VERSION" ]]; then
	echo "error: release tag and version do not match" >&2
	exit 1
fi
if [[ ! "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ \
	|| ! "$DESKHELM_RELEASE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
	echo "error: release commit values must be full lowercase Git object SHAs" >&2
	exit 1
fi
if [[ "$GITHUB_SHA" != "$DESKHELM_RELEASE_COMMIT" ]]; then
	echo "error: publish checkout does not match the validated tag commit" >&2
	exit 1
fi

gh_bin="${DESKHELM_GH_BIN:-$(command -v gh || true)}"
python_bin="${DESKHELM_PYTHON_BIN:-$(command -v python3 || true)}"
artifact_validator="${DESKHELM_ARTIFACT_VALIDATOR_BIN:-$ROOT_DIR/script/release/validate-release-artifacts.py}"
for executable in "$gh_bin" "$python_bin" "$artifact_validator"; do
	if [[ -z "$executable" || ! -x "$executable" ]]; then
		echo "error: required publish tool is not executable: ${executable:-missing}" >&2
		exit 1
	fi
done

sparkle_public_key_file="${DESKHELM_SPARKLE_PUBLIC_KEY_FILE:-$DEFAULT_SPARKLE_PUBLIC_KEY_FILE}"
if [[ ! -f "$sparkle_public_key_file" ]]; then
	echo "error: Sparkle public key file does not exist: $sparkle_public_key_file" >&2
	exit 1
fi
sparkle_public_key="$("$python_bin" - "$sparkle_public_key_file" <<'PY'
from pathlib import Path
import sys

value = Path(sys.argv[1]).read_text(encoding="utf-8").strip()
if not value:
	raise SystemExit("error: Sparkle public key file is empty")
print(value)
PY
)"
"$python_bin" - "$sparkle_public_key" <<'PY'
import base64
import binascii
import sys

try:
	public_key = base64.b64decode(sys.argv[1], validate=True)
except (ValueError, binascii.Error) as error:
	raise SystemExit(f"error: Sparkle public key file is not valid base64: {error}")
if len(public_key) != 32:
	raise SystemExit(
		"error: Sparkle public key file must decode to a 32-byte Ed25519 key"
	)
PY

input_dir="${DESKHELM_RELEASE_INPUT_DIR:-$ROOT_DIR/artifacts}"
archive_path="$input_dir/$ARCHIVE_NAME"
appcast_path="$input_dir/$APPCAST_NAME"
checksum_path="$input_dir/$CHECKSUM_NAME"
for asset in "$archive_path" "$appcast_path" "$checksum_path"; do
	if [[ ! -s "$asset" ]]; then
		echo "error: required release asset is missing or empty: $asset" >&2
		exit 1
	fi
done

work_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/deskhelm-publish.XXXXXX")"
release_json="$work_root/release.json"
assets_json="$work_root/assets.json"
view_json="$work_root/view.json"
tag_ref_json="$work_root/tag-ref.json"
tag_object_json="$work_root/tag-object.json"
main_compare_json="$work_root/main-compare.json"
remote_dir="$work_root/remote"
mkdir -p "$remote_dir"
cleanup() {
	if [[ "$work_root" == */deskhelm-publish.* && -d "$work_root" ]]; then
		rm -rf "$work_root" || true
	fi
}
trap cleanup EXIT

validate_remote_source() {
	"$gh_bin" api \
		-H "X-GitHub-Api-Version: $API_VERSION" \
		"repos/$GITHUB_REPOSITORY/git/ref/tags/$DESKHELM_RELEASE_TAG" \
		>"$tag_ref_json"
	local tag_object_sha
	tag_object_sha="$("$python_bin" - "$tag_ref_json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
	ref = json.load(handle)
target = ref.get("object")
if not isinstance(target, dict) or target.get("type") != "tag":
	raise SystemExit("error: remote release ref must point to an annotated tag object")
sha = target.get("sha")
if not isinstance(sha, str) or re.fullmatch(r"[0-9a-f]{40}", sha) is None:
	raise SystemExit("error: remote annotated tag object has an invalid SHA")
print(sha)
PY
)"
	"$gh_bin" api \
		-H "X-GitHub-Api-Version: $API_VERSION" \
		"repos/$GITHUB_REPOSITORY/git/tags/$tag_object_sha" \
		>"$tag_object_json"
	"$python_bin" - "$tag_object_json" "$DESKHELM_RELEASE_TAG" "$DESKHELM_RELEASE_COMMIT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
	tag = json.load(handle)
if tag.get("tag") != sys.argv[2]:
	raise SystemExit("error: remote annotated tag name changed after source validation")
target = tag.get("object")
if not isinstance(target, dict) or target.get("type") != "commit":
	raise SystemExit("error: remote annotated tag must point directly to a commit")
if target.get("sha") != sys.argv[3]:
	raise SystemExit("error: remote tag commit changed after source validation")
PY
	"$gh_bin" api \
		-H "X-GitHub-Api-Version: $API_VERSION" \
		"repos/$GITHUB_REPOSITORY/compare/$DESKHELM_RELEASE_COMMIT...main" \
		>"$main_compare_json"
	"$python_bin" - "$main_compare_json" "$DESKHELM_RELEASE_COMMIT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
	comparison = json.load(handle)
merge_base = comparison.get("merge_base_commit")
if not isinstance(merge_base, dict) or merge_base.get("sha") != sys.argv[2]:
	raise SystemExit("error: release commit is no longer reachable from canonical main")
PY
}

validate_remote_source

release_state="draft"
if "$gh_bin" release view "$DESKHELM_RELEASE_TAG" \
	--repo "$GITHUB_REPOSITORY" \
	--json databaseId,isDraft,isPrerelease,tagName \
	>"$view_json" 2>/dev/null; then
	:
else
	"$gh_bin" release create "$DESKHELM_RELEASE_TAG" \
		--repo "$GITHUB_REPOSITORY" \
		--draft \
		--generate-notes \
		--verify-tag \
		--target "$DESKHELM_RELEASE_COMMIT" \
		--title "DeskHelm $DESKHELM_RELEASE_TAG"
	"$gh_bin" release view "$DESKHELM_RELEASE_TAG" \
		--repo "$GITHUB_REPOSITORY" \
		--json databaseId,isDraft,isPrerelease,tagName \
		>"$view_json"
fi

release_view="$("$python_bin" - "$view_json" "$DESKHELM_RELEASE_TAG" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
	release = json.load(handle)
if release.get("tagName") != sys.argv[2]:
	raise SystemExit("error: existing release tag does not match")
if release.get("isPrerelease") is not False:
	raise SystemExit("error: stable release must not be a prerelease")
release_id = release.get("databaseId")
if not isinstance(release_id, int) or release_id <= 0:
	raise SystemExit("error: release view is missing a valid database id")
if release.get("isDraft") is True:
	release_state = "draft"
elif release.get("isDraft") is False:
	release_state = "published"
else:
	raise SystemExit("error: existing release has an invalid draft state")
print(f"{release_state}\t{release_id}")
PY
)"
release_state="${release_view%%$'\t'*}"
release_id="${release_view#*$'\t'}"

if [[ "$release_state" == "draft" ]]; then
	# Upload only the three validated release assets. The release remains a draft.
	"$gh_bin" release upload "$DESKHELM_RELEASE_TAG" \
		"$archive_path" \
		"$appcast_path" \
		"$checksum_path" \
		--repo "$GITHUB_REPOSITORY" \
		--clobber
fi

"$gh_bin" api \
	-H "X-GitHub-Api-Version: $API_VERSION" \
	"repos/$GITHUB_REPOSITORY/releases/$release_id" \
	>"$release_json"
"$gh_bin" api \
	-H "X-GitHub-Api-Version: $API_VERSION" \
	"repos/$GITHUB_REPOSITORY/releases/$release_id/assets?per_page=100" \
	>"$assets_json"

validate_artifacts() {
	local artifact_root="$1"
	"$artifact_validator" \
		--archive "$artifact_root/$ARCHIVE_NAME" \
		--appcast "$artifact_root/$APPCAST_NAME" \
		--assets-json "$assets_json" \
		--checksum "$artifact_root/$CHECKSUM_NAME" \
		--release-json "$release_json" \
		--release-state "$release_state" \
		--repository "$GITHUB_REPOSITORY" \
		--sparkle-public-key "$sparkle_public_key" \
		--sparkle-version "$DESKHELM_SPARKLE_VERSION" \
		--tag "$DESKHELM_RELEASE_TAG" \
		--version "$DESKHELM_RELEASE_VERSION" \
		--verify-appcast-signature
}

if [[ "$release_state" == "draft" ]]; then
	validate_artifacts "$input_dir"
fi

for asset_name in "$ARCHIVE_NAME" "$APPCAST_NAME" "$CHECKSUM_NAME"; do
	"$gh_bin" release download "$DESKHELM_RELEASE_TAG" \
		--repo "$GITHUB_REPOSITORY" \
		--dir "$remote_dir" \
		--pattern "$asset_name"
	if [[ "$release_state" == "draft" ]] \
		&& ! cmp -s "$input_dir/$asset_name" "$remote_dir/$asset_name"; then
		echo "error: downloaded draft bytes do not match local artifact: $asset_name" >&2
		exit 1
	fi
done

if [[ "$release_state" == "published" ]]; then
	# A retry rebuild can produce different ZIP metadata. Validate the immutable public bytes
	# directly instead of comparing them with the new local package.
	validate_artifacts "$remote_dir"
fi

validate_remote_source

if [[ "$release_state" == "published" ]]; then
	echo "Existing public release and all downloaded bytes passed validation."
	exit 0
fi

echo "Draft release and all uploaded bytes passed validation; publishing $DESKHELM_RELEASE_TAG."
# Keep this as the final fallible operation. Any earlier failure leaves the release private.
"$gh_bin" api \
	-H "X-GitHub-Api-Version: $API_VERSION" \
	--method PATCH \
	-F draft=false \
	-f make_latest=legacy \
	--silent \
	"repos/$GITHUB_REPOSITORY/releases/$release_id"
