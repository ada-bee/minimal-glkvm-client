#!/bin/sh

set -eu

cleanup_icon_file=""

cleanup() {
    if [ -n "${cleanup_icon_file}" ] && [ -f "${cleanup_icon_file}" ]; then
        /bin/rm -f "${cleanup_icon_file}"
    fi
}

trap cleanup EXIT

required_setting() {
    key="$1"
    value="$2"

    if [ -z "${value}" ] || [ "${value}" = "__REQUIRED__" ]; then
        printf "error: %s is required. Set it at build time.\n" "${key}" >&2
        exit 1
    fi
}

validate_host_url() {
    host_url="$1"

    if ! printf "%s" "${host_url}" | /usr/bin/grep -Eq '^https://[^/?#]+(:[0-9]+)?$'; then
        printf "error: GLKVM_HOST_URL must be an https URL with host and optional port only\n" >&2
        exit 1
    fi
}

validate_edid_hex() {
    edid_hex="$1"

    if [ -z "${edid_hex}" ]; then
        return
    fi

    compact="$(printf "%s" "${edid_hex}" | tr -d '[:space:]')"
    if [ -z "${compact}" ]; then
        return
    fi

    if ! printf "%s" "${compact}" | /usr/bin/grep -Eq '^[0-9A-Fa-f]+$'; then
        printf "error: GLKVM_EDID_HEX must contain only hexadecimal characters\n" >&2
        exit 1
    fi

    length="$(printf "%s" "${compact}" | /usr/bin/wc -c | tr -d ' ')"
    if [ $((length % 2)) -ne 0 ]; then
        printf "error: GLKVM_EDID_HEX must have an even number of characters\n" >&2
        exit 1
    fi
}

compact_edid_hex() {
    edid_hex="$1"
    printf "%s" "${edid_hex}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]'
}

generate_icon() {
    source_icon="$1"
    iconset_dir="$2"
    size="$3"
    name="$4"

    /usr/bin/sips -s format png -z "${size}" "${size}" "${source_icon}" --out "${iconset_dir}/${name}" >/dev/null
}

required_setting "GLKVM_APP_NAME" "${GLKVM_APP_NAME:-}"
required_setting "GLKVM_HOST_URL" "${GLKVM_HOST_URL:-}"
required_setting "GLKVM_APP_ICON" "${GLKVM_APP_ICON:-}"

validate_host_url "${GLKVM_HOST_URL}"
validate_edid_hex "${GLKVM_EDID_HEX:-}"

normalized_edid_hex="$(compact_edid_hex "${GLKVM_EDID_HEX:-}")"

icon_source="${GLKVM_APP_ICON}"

if printf "%s" "${GLKVM_APP_ICON}" | /usr/bin/grep -Eq '^https?://'; then
    cleanup_icon_file="$(/usr/bin/mktemp -t glkvm-app-icon.XXXXXX)"
    if ! /usr/bin/curl -fLsS "${GLKVM_APP_ICON}" -o "${cleanup_icon_file}"; then
        printf "error: failed to download GLKVM_APP_ICON from URL: %s\n" "${GLKVM_APP_ICON}" >&2
        exit 1
    fi
    icon_source="${cleanup_icon_file}"
elif [ ! -f "${GLKVM_APP_ICON}" ]; then
    printf "error: GLKVM_APP_ICON file does not exist: %s\n" "${GLKVM_APP_ICON}" >&2
    exit 1
fi

iconset_dir="${SRCROOT}/glkvm-client/Assets.xcassets/AppIcon.appiconset"

generate_icon "${icon_source}" "${iconset_dir}" 16 "icon_16x16.png"
generate_icon "${icon_source}" "${iconset_dir}" 32 "icon_16x16@2x.png"
generate_icon "${icon_source}" "${iconset_dir}" 32 "icon_32x32.png"
generate_icon "${icon_source}" "${iconset_dir}" 64 "icon_32x32@2x.png"
generate_icon "${icon_source}" "${iconset_dir}" 128 "icon_128x128.png"
generate_icon "${icon_source}" "${iconset_dir}" 256 "icon_128x128@2x.png"
generate_icon "${icon_source}" "${iconset_dir}" 256 "icon_256x256.png"
generate_icon "${icon_source}" "${iconset_dir}" 512 "icon_256x256@2x.png"
generate_icon "${icon_source}" "${iconset_dir}" 512 "icon_512x512.png"
generate_icon "${icon_source}" "${iconset_dir}" 1024 "icon_512x512@2x.png"

config_output="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BuildConfig.json"
config_output_dir="$(dirname "${config_output}")"
/bin/mkdir -p "${config_output_dir}"

BUILD_CONFIG_PATH="${config_output}" \
BUILD_CONFIG_APP_NAME="${GLKVM_APP_NAME}" \
BUILD_CONFIG_HOST_URL="${GLKVM_HOST_URL}" \
BUILD_CONFIG_EDID_HEX="${normalized_edid_hex}" \
/usr/bin/python3 - <<'PY'
import json
import os

config = {
    "appName": os.environ["BUILD_CONFIG_APP_NAME"],
    "hostURL": os.environ["BUILD_CONFIG_HOST_URL"],
}

edid_hex = os.environ.get("BUILD_CONFIG_EDID_HEX", "")
if edid_hex:
    config["edidHex"] = edid_hex

with open(os.environ["BUILD_CONFIG_PATH"], "w", encoding="utf-8") as handle:
    json.dump(config, handle, separators=(",", ":"))
PY
