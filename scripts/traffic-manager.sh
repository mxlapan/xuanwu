#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
COMMON_LIB="$INSTALL_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/common.sh
source "$COMMON_LIB"

usage() {
    cat << EOF
Usage: $0 <command>

Commands:
  sync                 Query Xray stats, update usage, enforce limits
  monthly-reset        Reset monthly traffic for non-admin users
  status [tag]          Show traffic usage
EOF
}

traffic_status() {
    local filter="${1:-}"
    vxd_load_main_config || true
    vxd_ensure_user_db
    local tag used limit percent status updated limit_text
    printf '%-18s %-14s %-14s %-10s %-10s %s\n' "TAG" "USED" "LIMIT" "PERCENT" "STATUS" "UPDATED"
    while IFS=$'\t' read -r tag used limit percent status updated; do
        [[ -n "$tag" ]] || continue
        [[ -z "$filter" || "$filter" == "$tag" ]] || continue
        if [[ "$limit" == "0" ]]; then
            limit_text="unlimited"
        else
            limit_text="$(vxd_format_bytes "$limit")"
        fi
        printf '%-18s %-14s %-14s %-10s %-10s %s\n' "$tag" "$(vxd_format_bytes "$used")" "$limit_text" "$percent" "$status" "$updated"
    done < <(vxd_traffic_table)
}

cmd_sync() {
    vxd_load_main_config || true
    vxd_ensure_user_db
    local backup_dir disabled over
    if ! vxd_update_traffic_usage; then
        echo "Failed to query Xray stats API. Is the xray container running and healthy?" >&2
        exit 1
    fi
    over="$(vxd_traffic_over_limit_tags)"
    if [[ -n "$over" ]]; then
        backup_dir="$(vxd_backup_state traffic-limit)"
        if ! disabled="$(vxd_enforce_traffic_limits)"; then
            vxd_restore_state "$backup_dir" || true
            echo "Failed to update users for traffic enforcement; rolled back" >&2
            exit 1
        fi
        echo "Traffic limit reached; disabling users:"
        printf '%s\n' "$disabled"
        if ! vxd_render_xray_config || ! vxd_restart_xray_with_rollback "$backup_dir"; then
            vxd_restore_state "$backup_dir" || true
            echo "Failed to apply traffic limit changes; rolled back" >&2
            exit 1
        fi
        while IFS= read -r tag; do
            [[ -n "$tag" ]] && vxd_audit "traffic-manager" "auto-disable-limit" "$tag" "ok"
        done <<< "$disabled"
    fi
    echo "Traffic sync complete"
}

cmd_set_limit() {
    local tag="${1:-}" limit="${2:-}"
    [[ -n "$tag" && -n "$limit" ]] || { usage; exit 1; }
    vxd_load_main_config || true
    vxd_ensure_user_db
    local bytes backup_dir
    bytes="$(vxd_parse_bytes "$limit")" || { echo "Invalid limit: $limit" >&2; exit 1; }
    backup_dir="$(vxd_backup_state "set-limit-$tag")"
    if ! vxd_user_set_limit "$tag" "$bytes"; then
        echo "User not found: $tag" >&2
        exit 1
    fi
    vxd_audit "cli" "set-limit" "$tag" "bytes=$bytes"
    if [[ "$bytes" == "0" ]]; then
        echo "Limit updated: $tag => unlimited"
    else
        echo "Limit updated: $tag => $(vxd_format_bytes "$bytes")"
    fi

    local disabled
    if ! disabled="$(vxd_enforce_traffic_limits)"; then
        vxd_restore_state "$backup_dir" || true
        echo "Failed to update users for traffic enforcement; rolled back" >&2
        exit 1
    fi
    if [[ -n "$disabled" ]]; then
        echo "Current usage is already over limit; disabling affected users:"
        printf '%s\n' "$disabled"
        if ! vxd_render_xray_config || ! vxd_restart_xray_with_rollback "$backup_dir"; then
            vxd_restore_state "$backup_dir" || true
            echo "Failed to apply limit changes; rolled back" >&2
            exit 1
        fi
    fi
}

cmd_reset() {
    local tag="${1:-}"
    [[ -n "$tag" ]] || { usage; exit 1; }
    vxd_load_main_config || true
    local filter="$tag" user
    if [[ "$tag" != "all" ]]; then
        user="$(vxd_user_find "$tag")" || true
        [[ -n "$user" ]] || { echo "User not found: $tag" >&2; exit 1; }
        filter="$(jq -r '.tag' <<< "$user")"
    fi
    vxd_user_reset_traffic "$tag"
    vxd_refresh_traffic_baseline "$filter" || echo "Warning: failed to refresh live traffic baseline; next sync may count traffic since previous baseline." >&2
    vxd_audit "cli" "reset-traffic" "$tag" "ok"
    echo "Traffic reset: $tag"
}

cmd_monthly_reset() {
    vxd_load_main_config || true
    vxd_ensure_user_db
    local backup_dir
    backup_dir="$(vxd_backup_state monthly-traffic-reset)"
    vxd_reset_monthly_traffic
    vxd_refresh_traffic_baseline all || echo "Warning: failed to refresh live traffic baseline; next sync may count traffic since previous baseline." >&2
    if ! vxd_render_xray_config || ! vxd_restart_xray_with_rollback "$backup_dir"; then
        vxd_restore_state "$backup_dir" || true
        echo "Failed to apply monthly traffic reset; rolled back" >&2
        exit 1
    fi
    vxd_audit "traffic-manager" "monthly-reset" "non-admin-users" "ok"
    echo "Monthly traffic reset complete"
}

main() {
    case "${1:-sync}" in
        sync) cmd_sync ;;
        monthly-reset) cmd_monthly_reset ;;
        status) traffic_status "${2:-}" ;;
        help|--help|-h) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
