#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SWIFT_ROOT="${REPO_ROOT}/apps/deskhelm/macos"
MODE="run"
CONFIGURATION="${DESKHELM_CONFIGURATION:-debug}"
SIGNING_IDENTITY="${DESKHELM_CODE_SIGN_IDENTITY:--}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
	if [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
		export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
	else
		echo "Xcode beta is required at /Applications/Xcode-beta.app." >&2
		exit 1
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
	echo "Usage: $0 [--run|--build-only|--test|--verify|--verify-panel|--debug|--logs|--telemetry]"
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
		--verify-panel) MODE="verify-panel" ;;
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

stage_app_bundle() {
	local binary_directory
	local executable
	local app_directory="${SWIFT_ROOT}/dist/DeskHelm.app"
	local contents_directory="${app_directory}/Contents"
	local macos_directory="${contents_directory}/MacOS"
	local info_plist="${contents_directory}/Info.plist"

	binary_directory="$(swift_binary_directory)"
	executable="${binary_directory}/DeskHelmMac"

	if [[ ! -x "${executable}" ]]; then
		echo "SwiftPM did not produce ${executable}." >&2
		exit 1
	fi

	/bin/rm -rf "${app_directory}"
	/usr/bin/install -d "${macos_directory}"
	/usr/bin/ditto "${executable}" "${macos_directory}/DeskHelmMac"

	/usr/bin/plutil -create xml1 "${info_plist}"
	/usr/bin/plutil -insert CFBundleDevelopmentRegion -string "en" "${info_plist}"
	/usr/bin/plutil -insert CFBundleExecutable -string "DeskHelmMac" "${info_plist}"
	/usr/bin/plutil -insert CFBundleIdentifier -string "com.acgbox.deskhelm" "${info_plist}"
	/usr/bin/plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "${info_plist}"
	/usr/bin/plutil -insert CFBundleName -string "DeskHelm" "${info_plist}"
	/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "${info_plist}"
	/usr/bin/plutil -insert CFBundleShortVersionString -string "0.1.0" "${info_plist}"
	/usr/bin/plutil -insert CFBundleVersion -string "1" "${info_plist}"
	/usr/bin/plutil -insert LSMinimumSystemVersion \
		-string "${DESKHELM_MACOS_MINIMUM_VERSION}" \
		"${info_plist}"
	/usr/bin/plutil -insert LSUIElement -bool true "${info_plist}"
	/usr/bin/plutil -insert NSHighResolutionCapable -bool true "${info_plist}"
	/usr/bin/plutil -insert NSPrincipalClass -string "NSApplication" "${info_plist}"
	/usr/bin/codesign \
		--force \
		--sign "${SIGNING_IDENTITY}" \
		--identifier "com.acgbox.deskhelm" \
		--timestamp=none \
		"${app_directory}"
	/usr/bin/codesign --verify --deep --strict "${app_directory}"

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

	if [[ "${MODE}" == "verify-panel" ]]; then
		open_arguments+=(--args --verify-panel)
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

if [[ "${MODE}" == "build-only" ]]; then
	echo "Built DeskHelmMac with ${DEVELOPER_DIR}."
	exit 0
fi

APP_DIRECTORY="$(stage_app_bundle)"
launch_app "${APP_DIRECTORY}"

case "${MODE}" in
	run)
		echo "Launched ${APP_DIRECTORY} (PID ${APP_PID})."
		;;
	verify|verify-panel)
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
		EXPECTED_STATUS_ITEM_SUMMARY="button=true image=true visible=true window=true titleEmpty=true panel=true"
		if [[ "${STATUS_ITEM_READY_SUMMARY}" != "${EXPECTED_STATUS_ITEM_SUMMARY}" ]]; then
			echo "DeskHelm published an incomplete NSStatusItem readiness state: ${STATUS_ITEM_READY_SUMMARY}" >&2
			exit 1
		fi

		echo "Confirmed DeskHelm NSStatusItem readiness for PID ${APP_PID}: ${STATUS_ITEM_READY_SUMMARY}"

		if [[ "${MODE}" == "verify-panel" ]]; then
			PANEL_STATE_PID=""
			for attempt in {1..20}; do
				PANEL_STATE_PID="$(
					/usr/bin/defaults read com.acgbox.deskhelm PanelStatePID 2>/dev/null \
						|| true
				)"
				if [[ "${PANEL_STATE_PID}" == "${APP_PID}" ]]; then
					break
				fi
				sleep 0.25
			done

			if [[ "${PANEL_STATE_PID}" != "${APP_PID}" ]]; then
				echo "DeskHelm did not publish panel state for PID ${APP_PID}." >&2
				exit 1
			fi

			PANEL_STATE_SUMMARY="$(
				/usr/bin/defaults read com.acgbox.deskhelm PanelStateSummary
			)"
			if [[ ! "${PANEL_STATE_SUMMARY}" =~ ^phase=(shown|refreshed)\  ]] \
				|| [[ "${PANEL_STATE_SUMMARY}" != *" visible=true "* ]] \
				|| [[ "${PANEL_STATE_SUMMARY}" != *" key=true "* ]] \
				|| [[ "${PANEL_STATE_SUMMARY}" != *" nonactivating=true "* ]] \
				|| [[ "${PANEL_STATE_SUMMARY}" != *" keyOnlyIfNeeded=false "* ]] \
				|| [[ "${PANEL_STATE_SUMMARY}" != *" onScreen=true "* ]] \
				|| [[ ! "${PANEL_STATE_SUMMARY}" =~ windowNumber=([1-9][0-9]*) ]] \
				|| [[ ! "${PANEL_STATE_SUMMARY}" =~ width=([1-9][0-9]*) ]] \
				|| [[ ! "${PANEL_STATE_SUMMARY}" =~ height=([1-9][0-9]*)$ ]]; then
				echo "DeskHelm did not keep a visible key panel: ${PANEL_STATE_SUMMARY}" >&2
				exit 1
			fi

			echo "Confirmed DeskHelm panel readiness for PID ${APP_PID}: ${PANEL_STATE_SUMMARY}"
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
