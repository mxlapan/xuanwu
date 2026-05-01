#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
COMMON_LIB="$INSTALL_DIR/scripts/lib/common.sh"
if grep -q $'\r' "$COMMON_LIB" 2>/dev/null; then
    sed -i 's/\r$//' "$COMMON_LIB" 2>/dev/null || true
fi
# shellcheck source=scripts/lib/common.sh
source "$COMMON_LIB"

ACCESS_LOG="${XRAY_ACCESS_LOG:-$INSTALL_DIR/logs/xray/access.log}"
OUT_DIR="${USER_LOG_DIR:-$INSTALL_DIR/logs/users}"

sanitize_tag() {
    local tag="$1"
    tag="${tag%@*}"
    tag="$(printf '%s' "$tag" | tr -c 'A-Za-z0-9._-' '_')"
    [[ -n "$tag" ]] || tag="unknown"
    printf '%s' "$tag"
}

extract_user() {
    local line="$1"
    local email tag
    email="$(printf '%s\n' "$line" | grep -oE '([Ee]mail|[Uu]ser|tag)[=:][[:space:]]*"?[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' | head -n 1 | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$' || true)"
    if [[ -z "$email" ]]; then
        email="$(printf '%s\n' "$line" | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' | head -n 1 || true)"
    fi
    if [[ -n "$email" ]]; then
        sanitize_tag "$email"
        return
    fi
    tag="unknown"
    printf '%s' "$tag"
}

main() {
    vxd_load_main_config || true
    mkdir -p "$(dirname "$ACCESS_LOG")"
    mkdir -p "$OUT_DIR"
    chmod 700 "$OUT_DIR"
    touch "$ACCESS_LOG"
    chmod 600 "$ACCESS_LOG" 2>/dev/null || true

    echo "[$(vxd_now)] user log splitter started, source=$ACCESS_LOG, out=$OUT_DIR"
    tail -n 0 -F "$ACCESS_LOG" | while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        tag="$(extract_user "$line")"
        printf '%s\n' "$line" >> "$OUT_DIR/${tag}.log"
        chmod 600 "$OUT_DIR/${tag}.log" 2>/dev/null || true
    done
}

main "$@"
