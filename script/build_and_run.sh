#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SWIFT_ROOT="${REPO_ROOT}/apps/deskhelm/macos"
MODE="run"
CONFIGURATION="${DESKHELM_CONFIGURATION:-debug}"
SIGNING_IDENTITY="${DESKHELM_CODE_SIGN_IDENTITY:--}"
SPARKLE_APPCAST_URL="${DESKHELM_SPARKLE_APPCAST_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${DESKHELM_SPARKLE_PUBLIC_ED_KEY:-}"
APP_VERSION="${DESKHELM_APP_VERSION:-}"
if [[ -z "${APP_VERSION}" ]]; then
	APP_VERSION="$(
		/usr/bin/sed -n \
			'/^\[workspace\.package\]/,/^\[/s/^version[[:space:]]*=[[:space:]]*"\([^"]*\)"/\1/p' \
			"${REPO_ROOT}/Cargo.toml"
	)"
fi
BUILD_VERSION="${DESKHELM_BUILD_VERSION:-${APP_VERSION}}"
STAGE_ROOT="${DESKHELM_APP_STAGE_DIR:-${SWIFT_ROOT}/dist}"

if [[ -n "${DESKHELM_APP_STAGE_DIR:-}" ]]; then
	if [[ -z "${RUNNER_TEMP:-}" || ! -d "${RUNNER_TEMP}" ]]; then
		echo "DESKHELM_APP_STAGE_DIR requires an existing RUNNER_TEMP." >&2
		exit 2
	fi
	if ! /usr/bin/python3 - "${RUNNER_TEMP}" "${STAGE_ROOT}" <<'PY'
import os
import sys

runner_temp = os.path.realpath(sys.argv[1])
stage_root = os.path.realpath(sys.argv[2])
if stage_root == runner_temp or os.path.commonpath((runner_temp, stage_root)) != runner_temp:
    raise SystemExit(1)
PY
	then
		echo "DESKHELM_APP_STAGE_DIR must be a child of RUNNER_TEMP." >&2
		exit 2
	fi
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
	if [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
		export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
	else
		selected_developer_directory="$(/usr/bin/xcode-select --print-path)"
		if [[ ! -x "${selected_developer_directory}/usr/bin/xcodebuild" ]]; then
			echo "The active developer directory does not provide full Xcode." >&2
			exit 1
		fi
		export DEVELOPER_DIR="${selected_developer_directory}"
	fi
fi

DESKHELM_MACOS_MINIMUM_VERSION="14.0"
DESKHELM_MACOS_SDK_VERSION="$(
	/usr/bin/xcrun --sdk macosx --show-sdk-version
)"
# SwiftPM's swiftbuild backend can otherwise write the deployment target into
# both LC_BUILD_VERSION fields when it links the Rust static library. Preserve
# the selected SDK identity so macOS can apply current linked-on UI behavior.
SWIFT_PLATFORM_LINKER_ARGUMENTS=(
	-Xlinker -platform_version
	-Xlinker macos
	-Xlinker "${DESKHELM_MACOS_MINIMUM_VERSION}"
	-Xlinker "${DESKHELM_MACOS_SDK_VERSION}"
)

usage() {
	echo "Usage: $0 [--run|--build-only|--test|--verify|--verify-settings|--debug|--logs|--telemetry]"
}

if [[ $# -gt 1 ]]; then
	usage
	exit 2
fi

if [[ $# -eq 1 ]]; then
	case "$1" in
		--run) MODE="run" ;;
		--build-only) MODE="build-only" ;;
		--test) MODE="test" ;;
		--verify) MODE="verify" ;;
		--verify-settings) MODE="verify-settings" ;;
		--debug) MODE="debug" ;;
		--logs) MODE="logs" ;;
		--telemetry) MODE="telemetry" ;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			usage
			exit 2
			;;
	esac
fi

case "${CONFIGURATION}" in
	debug|release) ;;
	*)
		echo "DESKHELM_CONFIGURATION must be debug or release." >&2
		exit 2
		;;
esac

if [[ ! "${APP_VERSION}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
	echo "DESKHELM_APP_VERSION must be a stable semantic version." >&2
	exit 2
fi
if [[ ! "${BUILD_VERSION}" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}$ ]]; then
	echo "DESKHELM_BUILD_VERSION must contain one to three integer components." >&2
	exit 2
fi

if [[ -n "${SPARKLE_APPCAST_URL}" || -n "${SPARKLE_PUBLIC_ED_KEY}" ]] \
	&& [[ -z "${SPARKLE_APPCAST_URL}" || -z "${SPARKLE_PUBLIC_ED_KEY}" ]]; then
	echo "DESKHELM_SPARKLE_APPCAST_URL and DESKHELM_SPARKLE_PUBLIC_ED_KEY must be set together." >&2
	exit 2
fi

RUST_LIBRARY_DIRECTORY="${REPO_ROOT}/target/${CONFIGURATION}"
export DESKHELM_RUST_LIB_DIR="${RUST_LIBRARY_DIRECTORY}"

build_rust_core() {
	local cargo_arguments=(build --locked -p deskhelm --lib)

	if [[ "${CONFIGURATION}" == "release" ]]; then
		cargo_arguments+=(--release)
	fi

	(
		cd "${REPO_ROOT}"
		cargo "${cargo_arguments[@]}"
	)
}

build_swift_app() {
	swift build \
		--package-path "${SWIFT_ROOT}" \
		--configuration "${CONFIGURATION}" \
		"${SWIFT_PLATFORM_LINKER_ARGUMENTS[@]}"
}

swift_binary_directory() {
	swift build \
		--package-path "${SWIFT_ROOT}" \
		--configuration "${CONFIGURATION}" \
		"${SWIFT_PLATFORM_LINKER_ARGUMENTS[@]}" \
		--show-bin-path
}

verify_linked_sdk() {
	local executable
	local linked_sdk_version

	executable="$(swift_binary_directory)/DeskHelmMac"
	linked_sdk_version="$(
		/usr/bin/xcrun vtool -show-build "${executable}" \
			| /usr/bin/awk '$1 == "sdk" { print $2; exit }'
	)"

	if [[ "${linked_sdk_version}" != "${DESKHELM_MACOS_SDK_VERSION}" ]]; then
		echo \
			"DeskHelmMac linked as SDK ${linked_sdk_version:-unknown}; expected ${DESKHELM_MACOS_SDK_VERSION}." \
			>&2
		exit 1
	fi
}

staged_rpaths() {
	/usr/bin/otool -l "$1" \
		| /usr/bin/awk '
			$1 == "cmd" && $2 == "LC_RPATH" {
				in_rpath = 1
				next
			}
			in_rpath && $1 == "path" {
				print $2
				in_rpath = 0
			}
		'
}

sanitize_staged_rpaths() {
	local executable="$1"
	local rpath

	while IFS= read -r rpath; do
		case "${rpath}" in
			"${SWIFT_ROOT}"/.build/* | \
				/Applications/*.app/Contents/Developer/* | \
				/Library/Developer/CommandLineTools/* | \
				/var/run/com.apple.security.cryptexd/*)
				/usr/bin/install_name_tool -delete_rpath "${rpath}" "${executable}"
				;;
		esac
	done < <(staged_rpaths "${executable}")
}

stage_app_bundle() {
	local binary_directory
	local executable
	local app_directory="${STAGE_ROOT}/DeskHelm.app"
	local contents_directory="${app_directory}/Contents"
	local macos_directory="${contents_directory}/MacOS"
	local frameworks_directory="${contents_directory}/Frameworks"
	local info_plist="${contents_directory}/Info.plist"
	local sparkle_framework

	binary_directory="$(swift_binary_directory)"
	executable="${binary_directory}/DeskHelmMac"

	if [[ ! -x "${executable}" ]]; then
		echo "SwiftPM did not produce ${executable}." >&2
		exit 1
	fi

	/usr/bin/install -d "${STAGE_ROOT}"
	/bin/rm -rf "${app_directory}"
	/usr/bin/install -d "${macos_directory}" "${frameworks_directory}"
	/usr/bin/ditto "${executable}" "${macos_directory}/DeskHelmMac"

	sparkle_framework="${binary_directory}/Sparkle.framework"
	if [[ ! -d "${sparkle_framework}" ]]; then
		echo "SwiftPM did not place Sparkle.framework in ${binary_directory}." >&2
		exit 1
	fi
	/usr/bin/python3 - "${SWIFT_ROOT}/Package.resolved" "${sparkle_framework}" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

resolved_path = Path(sys.argv[1])
framework = Path(sys.argv[2])
resolved = json.loads(resolved_path.read_text(encoding="utf-8"))
versions = [
    pin.get("state", {}).get("version")
    for pin in resolved.get("pins", [])
    if pin.get("identity") == "sparkle"
]
if versions != ["2.9.4"]:
    raise SystemExit("Package.resolved must contain the exact Sparkle 2.9.4 pin")
with (framework / "Versions/Current/Resources/Info.plist").open("rb") as handle:
    actual = plistlib.load(handle).get("CFBundleShortVersionString")
if actual != versions[0]:
    raise SystemExit(
        f"selected Sparkle.framework version {actual!r} does not match lock {versions[0]}"
    )
PY
	/usr/bin/ditto \
		"${sparkle_framework}" \
		"${frameworks_directory}/Sparkle.framework"

	sanitize_staged_rpaths "${macos_directory}/DeskHelmMac"
	if ! /usr/bin/otool -l "${macos_directory}/DeskHelmMac" \
		| /usr/bin/grep -q '@executable_path/../Frameworks'; then
		/usr/bin/install_name_tool \
			-add_rpath '@executable_path/../Frameworks' \
			"${macos_directory}/DeskHelmMac"
	fi

	/usr/bin/plutil -create xml1 "${info_plist}"
	/usr/bin/plutil -insert CFBundleDevelopmentRegion -string "en" "${info_plist}"
	/usr/bin/plutil -insert CFBundleDisplayName -string "DeskHelm" "${info_plist}"
	/usr/bin/plutil -insert CFBundleExecutable -string "DeskHelmMac" "${info_plist}"
	/usr/bin/plutil -insert CFBundleIdentifier -string "com.acgbox.deskhelm" "${info_plist}"
	/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "${info_plist}"
	/usr/bin/plutil -insert CFBundleName -string "DeskHelm" "${info_plist}"
	/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "${info_plist}"
	/usr/bin/plutil -insert CFBundleShortVersionString -string "${APP_VERSION}" "${info_plist}"
	/usr/bin/plutil -insert CFBundleVersion -string "${BUILD_VERSION}" "${info_plist}"
	/usr/bin/plutil -insert LSMinimumSystemVersion \
		-string "${DESKHELM_MACOS_MINIMUM_VERSION}" \
		"${info_plist}"
	/usr/bin/plutil -insert LSUIElement -bool true "${info_plist}"
	/usr/bin/plutil -insert NSHighResolutionCapable -bool true "${info_plist}"
	/usr/bin/plutil -insert NSPrincipalClass -string "NSApplication" "${info_plist}"

	if [[ -n "${SPARKLE_APPCAST_URL}" ]]; then
		/usr/bin/plutil -insert SUFeedURL \
			-string "${SPARKLE_APPCAST_URL}" \
			"${info_plist}"
		/usr/bin/plutil -insert SUPublicEDKey \
			-string "${SPARKLE_PUBLIC_ED_KEY}" \
			"${info_plist}"
		/usr/bin/plutil -insert SUEnableAutomaticChecks -bool true "${info_plist}"
		/usr/bin/plutil -insert SUAllowsAutomaticUpdates -bool true "${info_plist}"
		/usr/bin/plutil -insert SUScheduledCheckInterval -integer 86400 "${info_plist}"
	fi

	"${SCRIPT_DIR}/release/sign-macos-app.sh" \
		--app "${app_directory}" \
		--identity "${SIGNING_IDENTITY}" \
		--mode development
	/usr/bin/codesign --verify --deep --strict "${app_directory}"
	/usr/bin/otool -L "${macos_directory}/DeskHelmMac" \
		| /usr/bin/grep -q 'Sparkle.framework'

	echo "${app_directory}"
}

APP_PID=""

launch_app() {
	local app_directory="$1"
	local current_pid
	local attempt
	local open_arguments=(-n "${app_directory}")

	if /usr/bin/pgrep -x DeskHelmMac >/dev/null; then
		/usr/bin/pkill -TERM -x DeskHelmMac

		for attempt in {1..20}; do
			if ! /usr/bin/pgrep -x DeskHelmMac >/dev/null; then
				break
			fi
			sleep 0.25
		done

		if /usr/bin/pgrep -x DeskHelmMac >/dev/null; then
			echo "An existing DeskHelmMac process did not stop." >&2
			exit 1
		fi
	fi

	if [[ "${MODE}" == "verify-settings" ]]; then
		open_arguments+=(--args --verify-settings)
	fi

	/usr/bin/open "${open_arguments[@]}"

	for attempt in {1..40}; do
		current_pid="$(/usr/bin/pgrep -nx DeskHelmMac || true)"
		if [[ -n "${current_pid}" ]]; then
			APP_PID="${current_pid}"
			return
		fi
		sleep 0.25
	done

	echo "DeskHelm.app did not start within 10 seconds." >&2
	exit 1
}

build_rust_core

if [[ "${MODE}" == "test" ]]; then
	swift test \
		--package-path "${SWIFT_ROOT}" \
		--configuration "${CONFIGURATION}" \
		"${SWIFT_PLATFORM_LINKER_ARGUMENTS[@]}"
	exit 0
fi

build_swift_app
verify_linked_sdk

APP_DIRECTORY="$(stage_app_bundle)"

if [[ "${MODE}" == "build-only" ]]; then
	echo "Built and staged ${APP_DIRECTORY} with ${DEVELOPER_DIR}."
	exit 0
fi

launch_app "${APP_DIRECTORY}"

case "${MODE}" in
	run)
		echo "Launched ${APP_DIRECTORY} (PID ${APP_PID})."
		;;
	verify|verify-settings)
		sleep 1
		if ! /bin/kill -0 "${APP_PID}" 2>/dev/null; then
			echo "DeskHelm menu-bar process exited during verification." >&2
			exit 1
		fi

		STATUS_ITEM_READY_PID=""
		for attempt in {1..20}; do
			STATUS_ITEM_READY_PID="$(
				/usr/bin/defaults read com.acgbox.deskhelm StatusItemReadyPID 2>/dev/null \
					|| true
			)"
			if [[ "${STATUS_ITEM_READY_PID}" == "${APP_PID}" ]]; then
				break
			fi
			sleep 0.25
		done

		if [[ "${STATUS_ITEM_READY_PID}" != "${APP_PID}" ]]; then
			echo "DeskHelm did not publish a ready NSStatusItem for PID ${APP_PID}." >&2
			exit 1
		fi

		STATUS_ITEM_READY_SUMMARY="$(
			/usr/bin/defaults read com.acgbox.deskhelm StatusItemReadySummary
		)"
		EXPECTED_STATUS_ITEM_SUMMARY="button=true image=true visible=true window=true titleEmpty=true menu=true panel=false"
		if [[ "${STATUS_ITEM_READY_SUMMARY}" != "${EXPECTED_STATUS_ITEM_SUMMARY}" ]]; then
			echo "DeskHelm published an incomplete NSStatusItem readiness state: ${STATUS_ITEM_READY_SUMMARY}" >&2
			exit 1
		fi

		echo "Confirmed DeskHelm NSStatusItem readiness for PID ${APP_PID}: ${STATUS_ITEM_READY_SUMMARY}"

		if [[ "${MODE}" == "verify-settings" ]]; then
			SETTINGS_STATE_PID=""
			SETTINGS_STATE_SUMMARY=""
			for attempt in {1..40}; do
				SETTINGS_STATE_PID="$(
					/usr/bin/defaults read com.acgbox.deskhelm SettingsWindowStatePID 2>/dev/null \
						|| true
				)"
				SETTINGS_STATE_SUMMARY="$(
					/usr/bin/defaults read com.acgbox.deskhelm SettingsWindowStateSummary 2>/dev/null \
						|| true
				)"
				if [[ "${SETTINGS_STATE_PID}" == "${APP_PID}" ]] \
					&& [[ "${SETTINGS_STATE_SUMMARY}" == *" visible=true "* ]] \
					&& [[ "${SETTINGS_STATE_SUMMARY}" == *" key=true "* ]] \
					&& [[ "${SETTINGS_STATE_SUMMARY}" == *" main=true "* ]]; then
					break
				fi
				sleep 0.25
			done

			if [[ "${SETTINGS_STATE_PID}" != "${APP_PID}" ]]; then
				echo "DeskHelm did not publish Settings state for PID ${APP_PID}." >&2
				exit 1
			fi

			if [[ ! "${SETTINGS_STATE_SUMMARY}" =~ ^phase=(shown|focused|key)\  ]] \
				|| [[ "${SETTINGS_STATE_SUMMARY}" != *" visible=true "* ]] \
				|| [[ "${SETTINGS_STATE_SUMMARY}" != *" key=true "* ]] \
				|| [[ "${SETTINGS_STATE_SUMMARY}" != *" main=true "* ]] \
				|| [[ "${SETTINGS_STATE_SUMMARY}" != *" onScreen=true "* ]] \
				|| [[ "${SETTINGS_STATE_SUMMARY}" != *" toolbar=icons pane="* ]] \
				|| [[ ! "${SETTINGS_STATE_SUMMARY}" =~ windowNumber=([1-9][0-9]*) ]] \
				|| [[ ! "${SETTINGS_STATE_SUMMARY}" =~ width=([1-9][0-9]*) ]] \
				|| [[ ! "${SETTINGS_STATE_SUMMARY}" =~ height=([1-9][0-9]*)$ ]]; then
				echo "DeskHelm did not keep a visible key Settings window: ${SETTINGS_STATE_SUMMARY}" >&2
				exit 1
			fi

			echo "Confirmed DeskHelm Settings readiness for PID ${APP_PID}: ${SETTINGS_STATE_SUMMARY}"
		fi
		;;
	debug)
		exec /usr/bin/lldb -p "${APP_PID}"
		;;
	logs)
		exec /usr/bin/log stream \
			--style compact \
			--level debug \
			--predicate 'process == "DeskHelmMac"'
		;;
	telemetry)
		TRACE_PATH="${SWIFT_ROOT}/dist/DeskHelm-$(date +%Y%m%d-%H%M%S).trace"
		exec /usr/bin/xcrun xctrace record \
			--template "Time Profiler" \
			--attach "${APP_PID}" \
			--output "${TRACE_PATH}"
		;;
esac
