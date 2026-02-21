#!/bin/sh

set -eu

script_dir="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "${script_dir}/.." && pwd)"
env_file="${repo_root}/.env"

if [ ! -f "${env_file}" ]; then
    printf "error: missing .env file at %s\n" "${env_file}" >&2
    printf "hint: copy .env.example to .env and edit values\n" >&2
    exit 1
fi

set -a
. "${env_file}"
set +a

required_setting() {
    key="$1"
    value="$2"

    if [ -z "${value}" ] || [ "${value}" = "__REQUIRED__" ]; then
        printf "error: %s is required in .env\n" "${key}" >&2
        exit 1
    fi
}

required_setting "GLKVM_APP_NAME" "${GLKVM_APP_NAME:-}"
required_setting "GLKVM_HOST_URL" "${GLKVM_HOST_URL:-}"
required_setting "GLKVM_APP_ICON" "${GLKVM_APP_ICON:-}"
required_setting "GLKVM_BUNDLE_ID" "${GLKVM_BUNDLE_ID:-}"

case "${GLKVM_APP_ICON}" in
    https://*)
        ;;
    /*)
        ;;
    *)
        GLKVM_APP_ICON="${repo_root}/${GLKVM_APP_ICON}"
        ;;
esac

if [ "$#" -eq 0 ]; then
    set -- build
fi

exec xcodebuild \
    -project "${repo_root}/minimal-glkvm-client.xcodeproj" \
    -scheme "minimal-glkvm-client" \
    -configuration "${CONFIGURATION:-Debug}" \
    -destination "${DESTINATION:-platform=macOS}" \
    "GLKVM_APP_NAME=${GLKVM_APP_NAME}" \
    "GLKVM_HOST_URL=${GLKVM_HOST_URL}" \
    "GLKVM_APP_ICON=${GLKVM_APP_ICON}" \
    "GLKVM_BUNDLE_ID=${GLKVM_BUNDLE_ID}" \
    "GLKVM_EDID_HEX=${GLKVM_EDID_HEX:-}" \
    "$@"
