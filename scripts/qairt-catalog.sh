#!/usr/bin/env bash
# Software Center catalog helpers for Qualcomm AI Runtime Community Edition.
# Sourced by refresh-vendor.sh. Not a user-facing installer.
set -Eeuo pipefail

QAIRT_CATALOG_PRODUCT=${QAIRT_CATALOG_PRODUCT:-Qualcomm_AI_Runtime_Community}
QAIRT_CATALOG_APIGEE_URL=${QAIRT_CATALOG_APIGEE_URL:-https://apigwx-aws.qualcomm.com}
QAIRT_CATALOG_LIME_API=${QAIRT_CATALOG_LIME_API:-/qsc/internal}
QAIRT_CATALOG_APP_NAME=${QAIRT_CATALOG_APP_NAME:-QSCPRD}
QAIRT_CATALOG_CLIENT_TYPE=${QAIRT_CATALOG_CLIENT_TYPE:-UI}
QAIRT_CATALOG_CLIENT_ID=${QAIRT_CATALOG_CLIENT_ID:-000106f5-9d9a-15ae-8d7a-905b0a310000}
QAIRT_DOWNLOAD_PREFIX=${QAIRT_DOWNLOAD_PREFIX:-https://softwarecenter.qualcomm.com/api/download/software/sdks}

qairt_die() { echo "qairt-catalog: $*" >&2; return 1; }

qairt_version_tuple() {
    local ver=$1
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$ver" | awk -F. '{printf "%d %d %d %d\n", $1, $2, $3, $4}'
}

qairt_zip_url() {
    local ver=$1
    printf '%s/%s/All/%s/v%s.zip\n' "$QAIRT_DOWNLOAD_PREFIX" "$QAIRT_CATALOG_PRODUCT" "$ver" "$ver"
}

qairt_extract_spa_api_key() {
    local work html main_js js_file chunk key=''
    work=$(mktemp -d)
    html="$work/index.html"
    curl --fail --silent --show-error --location --retry 4 --retry-all-errors \
        --compressed \
        "https://softwarecenter.qualcomm.com/catalog/item/${QAIRT_CATALOG_PRODUCT}" \
        --output "$html"
    main_js=$(awk -F'"' '/src="main-[^"]+\.js"/{print $2; exit}' "$html")
    [[ -n "$main_js" ]] || { rm -rf "$work"; qairt_die "Software Center HTML has no main-*.js"; return 1; }
    case "$main_js" in
        http*) ;;
        /*) main_js="https://softwarecenter.qualcomm.com${main_js}" ;;
        *) main_js="https://softwarecenter.qualcomm.com/${main_js}" ;;
    esac
    js_file="$work/main.js"
    curl --fail --silent --show-error --location --retry 4 --retry-all-errors \
        --compressed "$main_js" --output "$js_file"
    key=$(sed -n 's/.*qscInternalApiKey:"\([^"]*\)".*/\1/p' "$js_file" | head -n 1)
    if [[ -z "$key" ]]; then
        while IFS= read -r chunk; do
            [[ -n "$chunk" ]] || continue
            curl --fail --silent --show-error --location --retry 4 --retry-all-errors \
                --compressed "https://softwarecenter.qualcomm.com/${chunk}" \
                --output "$work/chunk.js"
            key=$(sed -n 's/.*qscInternalApiKey:"\([^"]*\)".*/\1/p' "$work/chunk.js" | head -n 1)
            [[ -z "$key" ]] || break
        done < <(grep -oE 'chunk-[A-Z0-9]+\.js' "$js_file" | sort -u)
    fi
    rm -rf "$work"
    [[ -n "$key" ]] || { qairt_die "could not extract Software Center catalog API key from SPA"; return 1; }
    printf '%s\n' "$key"
}

qairt_catalog_curl() {
    local url=$1 dest=$2 key=$3 tracing
    tracing=$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')
    curl --fail --silent --show-error --location --retry 4 --retry-all-errors \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        -H "Authorization: ${key}" \
        -H 'X-QCOM-TokenType: apikey' \
        -H "X-QCOM-AppName: ${QAIRT_CATALOG_APP_NAME}" \
        -H "X-QCOM-ClientType: ${QAIRT_CATALOG_CLIENT_TYPE}" \
        -H "X-QCOM-ClientId: ${QAIRT_CATALOG_CLIENT_ID}" \
        -H "X-QCOM-TracingID: ${tracing}" \
        -H 'Origin: https://softwarecenter.qualcomm.com' \
        -H 'Referer: https://softwarecenter.qualcomm.com/' \
        "$url" --output "$dest"
}

qairt_catalog_latest() {
    local work key product_json releases_json product_id latest
    work=$(mktemp -d)
    key=$(qairt_extract_spa_api_key) || { rm -rf "$work"; return 1; }
    product_json="$work/product.json"
    releases_json="$work/releases.json"
    qairt_catalog_curl \
        "${QAIRT_CATALOG_APIGEE_URL}${QAIRT_CATALOG_LIME_API}/v1/products/?name=${QAIRT_CATALOG_PRODUCT}" \
        "$product_json" "$key" || { rm -rf "$work"; return 1; }
    product_id=$(jq -er --arg name "$QAIRT_CATALOG_PRODUCT" '
        .products[] | select(.name == $name) | .id
    ' "$product_json") || { rm -rf "$work"; qairt_die "catalog product id missing"; return 1; }
    qairt_catalog_curl \
        "${QAIRT_CATALOG_APIGEE_URL}${QAIRT_CATALOG_LIME_API}/v1/products/${product_id}/releases" \
        "$releases_json" "$key" || { rm -rf "$work"; return 1; }
    latest=$(jq -er '
        .releases
        | map(select(
            (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))
            and .version != "0.0.0.0"
            and .componentInstallType == "Zip"
            and .targetOperatingSystem == "All"
            and .targetArchitecture == "Any"
          ))
        | if length == 0 then error("no Community Edition zip releases") else . end
        | max_by(.version | split(".") | map(tonumber))
        | .version
    ' "$releases_json") || { rm -rf "$work"; qairt_die "could not select latest catalog version"; return 1; }
    rm -rf "$work"
    printf '%s\n' "$latest"
}

qairt_zip_has_runtime() {
    local zip=$1 ver=$2 target=$3
    unzip -l "$zip" | grep -F "qairt/${ver}/bin/${target}/qnn-platform-validator" >/dev/null || return 1
    unzip -l "$zip" | grep -F "qairt/${ver}/lib/${target}/libQnnHtp.so" >/dev/null || return 1
    unzip -l "$zip" | grep -F "qairt/${ver}/lib/${target}/libQnnHtpV68Stub.so" >/dev/null || return 1
    unzip -l "$zip" | grep -F "qairt/${ver}/lib/hexagon-v68/unsigned/libQnnHtpV68Skel.so" >/dev/null || return 1
    unzip -l "$zip" | grep -F "qairt/${ver}/LICENSE.pdf" >/dev/null || return 1
}

qairt_pick_target() {
    local zip=$1 ver=$2
    local preferred=aarch64-oe-linux-gcc11.2
    if qairt_zip_has_runtime "$zip" "$ver" "$preferred"; then
        printf '%s\n' "$preferred"
        return 0
    fi
    local target
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        if qairt_zip_has_runtime "$zip" "$ver" "$target"; then
            printf '%s\n' "$target"
            return 0
        fi
    done < <(unzip -l "$zip" | awk -v ver="$ver" '
        $0 ~ "qairt/" ver "/bin/aarch64-oe-linux-gcc" {
            n=split($NF, a, "/")
            print a[4]
        }
    ' | sort -u | sort -t. -k2,2nr)
    return 1
}
