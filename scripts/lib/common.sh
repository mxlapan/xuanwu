#!/bin/bash

# Common helpers for vless-xtls-docker. Source this file from scripts only.

VXD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VXD_INSTALL_DIR="${VXD_INSTALL_DIR:-$(cd "$VXD_LIB_DIR/../.." && pwd)}"
VXD_CONFIG_FILE="$VXD_INSTALL_DIR/.env"
VXD_TELEGRAM_CONFIG_FILE="$VXD_INSTALL_DIR/.env.telegram"
VXD_DATA_DIR="$VXD_INSTALL_DIR/data"
VXD_USERS_DB="$VXD_DATA_DIR/users.json"
VXD_TRAFFIC_DB="$VXD_DATA_DIR/traffic.json"
VXD_XRAY_TEMPLATE="$VXD_INSTALL_DIR/xray/config.json.template"
VXD_XRAY_CONFIG="$VXD_INSTALL_DIR/xray/config.json"
VXD_NGINX_TEMPLATE="$VXD_INSTALL_DIR/nginx/nginx.conf.template"
VXD_NGINX_CONFIG="$VXD_INSTALL_DIR/nginx/nginx.conf"
VXD_CLASH_TEMPLATE="$VXD_INSTALL_DIR/clash_config.yaml.template"
VXD_BACKUP_DIR="$VXD_INSTALL_DIR/backups"
VXD_LOG_DIR="$VXD_INSTALL_DIR/logs"
VXD_USER_LOG_DIR="$VXD_LOG_DIR/users"
VXD_AUDIT_LOG="$VXD_LOG_DIR/telegram-bot/audit.log"
VXD_XRAY_INBOUND_TAG="${VXD_XRAY_INBOUND_TAG:-vless-xtls-vision}"
VXD_REALITY_INBOUND_TAG="${VXD_REALITY_INBOUND_TAG:-vless-reality-vision}"
VXD_DEFAULT_XRAY_IMAGE="${VXD_DEFAULT_XRAY_IMAGE:-ghcr.io/xtls/xray-core:26.4.17}"
VXD_DEFAULT_NGINX_IMAGE="${VXD_DEFAULT_NGINX_IMAGE:-nginx:1.29.8-alpine}"
VXD_DEFAULT_CERTBOT_IMAGE="${VXD_DEFAULT_CERTBOT_IMAGE:-certbot/certbot:v5.5.0}"
VXD_DEFAULT_REALITY_SERVER_NAME="${VXD_DEFAULT_REALITY_SERVER_NAME:-www.microsoft.com}"
VXD_DEFAULT_ADMIN_USER_TAG="${VXD_DEFAULT_ADMIN_USER_TAG:-admin}"
VXD_DEFAULT_TRAFFIC_LIMIT="${VXD_DEFAULT_TRAFFIC_LIMIT:-20G}"

vxd_now() { date '+%Y-%m-%d %H:%M:%S'; }
vxd_today() { date -u '+%Y-%m-%d'; }
vxd_ts() { date '+%Y%m%d%H%M%S'; }

vxd_log() { echo "[$(vxd_now)] $*"; }
vxd_require_cmd() { command -v "$1" >/dev/null 2>&1; }

vxd_parse_env_value() {
    local value="$1"
    value="${value%$'\r'}"
    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value#\"}"
        value="${value%\"}"
    elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value#\'}"
        value="${value%\'}"
    fi
    printf '%s' "$value"
}

vxd_load_env_file() {
    local file="$1"
    shift
    [[ -f "$file" ]] || return 1

    local allowed=" $* "
    local key value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [[ "$allowed" == *" $key "* ]] || continue
        value="$(vxd_parse_env_value "$value")"
        printf -v "$key" '%s' "$value"
    done < "$file"
}

vxd_write_env_file() {
    local file="$1"
    shift
    local key value
    : > "$file"
    while [[ $# -gt 0 ]]; do
        key="$1"
        value="$2"
        shift 2
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        value="${value//\$/\\\$}"
        value="${value//\`/\\\`}"
        printf '%s="%s"\n' "$key" "$value" >> "$file"
    done
    chmod 600 "$file"
}

vxd_append_env_line() {
    local file="$1" key="$2" value="$3"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '%s="%s"\n' "$key" "$value" >> "$file"
}

vxd_persist_reality_config() {
    [[ -f "$VXD_CONFIG_FILE" ]] || return 0
    local tmp
    tmp="$(mktemp "$VXD_CONFIG_FILE.reality.XXXXXX")"
    awk -F= '
      BEGIN {
        skip["REALITY_ENABLED"]=1
        skip["REALITY_SERVER_NAME"]=1
        skip["REALITY_DEST"]=1
        skip["REALITY_PRIVATE_KEY"]=1
        skip["REALITY_PUBLIC_KEY"]=1
        skip["REALITY_SHORT_ID"]=1
      }
      !($1 in skip) { print }
    ' "$VXD_CONFIG_FILE" > "$tmp"
    vxd_append_env_line "$tmp" "REALITY_ENABLED" "${REALITY_ENABLED:-true}"
    vxd_append_env_line "$tmp" "REALITY_SERVER_NAME" "${REALITY_SERVER_NAME:-$VXD_DEFAULT_REALITY_SERVER_NAME}"
    vxd_append_env_line "$tmp" "REALITY_DEST" "${REALITY_DEST:-${REALITY_SERVER_NAME:-$VXD_DEFAULT_REALITY_SERVER_NAME}:443}"
    vxd_append_env_line "$tmp" "REALITY_PRIVATE_KEY" "${REALITY_PRIVATE_KEY:-}"
    vxd_append_env_line "$tmp" "REALITY_PUBLIC_KEY" "${REALITY_PUBLIC_KEY:-}"
    vxd_append_env_line "$tmp" "REALITY_SHORT_ID" "${REALITY_SHORT_ID:-}"
    mv "$tmp" "$VXD_CONFIG_FILE"
    chmod 600 "$VXD_CONFIG_FILE"
}

vxd_is_admin_tag() {
    local tag="$1"
    [[ "$tag" == "${ADMIN_USER_TAG:-$VXD_DEFAULT_ADMIN_USER_TAG}" ]]
}

vxd_load_main_config() {
    vxd_load_env_file "$VXD_CONFIG_FILE" \
        DOMAIN UUID EMAIL INSTALL_DATE CERT_SOURCE XRAY_IMAGE NGINX_IMAGE CERTBOT_IMAGE \
        ADMIN_USER_TAG \
        CLASH_PROXY_NAME_PREFIX CLASH_ALLOW_LAN CLASH_MODE CLASH_RULESET \
        TRAFFIC_DEFAULT_LIMIT TRAFFIC_SYNC_INTERVAL \
        REALITY_ENABLED REALITY_SERVER_NAME REALITY_DEST REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID || return 1
    XRAY_IMAGE="${XRAY_IMAGE:-$VXD_DEFAULT_XRAY_IMAGE}"
    NGINX_IMAGE="${NGINX_IMAGE:-$VXD_DEFAULT_NGINX_IMAGE}"
    CERTBOT_IMAGE="${CERTBOT_IMAGE:-$VXD_DEFAULT_CERTBOT_IMAGE}"
    CERT_SOURCE="${CERT_SOURCE:-project}"
    CLASH_PROXY_NAME_PREFIX="${CLASH_PROXY_NAME_PREFIX:-}"
    CLASH_ALLOW_LAN="${CLASH_ALLOW_LAN:-true}"
    CLASH_MODE="${CLASH_MODE:-rule}"
    CLASH_RULESET="${CLASH_RULESET:-loyalsoldier}"
    ADMIN_USER_TAG="${ADMIN_USER_TAG:-$VXD_DEFAULT_ADMIN_USER_TAG}"
    TRAFFIC_DEFAULT_LIMIT="${TRAFFIC_DEFAULT_LIMIT:-$VXD_DEFAULT_TRAFFIC_LIMIT}"
    TRAFFIC_SYNC_INTERVAL="${TRAFFIC_SYNC_INTERVAL:-2min}"
    REALITY_ENABLED="${REALITY_ENABLED:-true}"
    REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-$VXD_DEFAULT_REALITY_SERVER_NAME}"
    REALITY_DEST="${REALITY_DEST:-${REALITY_SERVER_NAME}:443}"
    REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-}"
    REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
    REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"
}

vxd_load_telegram_config() {
    # Migration compatibility: read old keys from .env first, then override with .env.telegram.
    vxd_load_env_file "$VXD_CONFIG_FILE" TELEGRAM_BOT_TOKEN TELEGRAM_ADMIN_IDS TELEGRAM_CONFIG_MODE 2>/dev/null || true
    vxd_load_env_file "$VXD_TELEGRAM_CONFIG_FILE" TELEGRAM_BOT_TOKEN TELEGRAM_ADMIN_IDS TELEGRAM_CONFIG_MODE 2>/dev/null || true
    TELEGRAM_CONFIG_MODE="${TELEGRAM_CONFIG_MODE:-plain}"
}

vxd_save_telegram_config() {
    vxd_write_env_file "$VXD_TELEGRAM_CONFIG_FILE" \
        TELEGRAM_BOT_TOKEN "${TELEGRAM_BOT_TOKEN:-}" \
        TELEGRAM_ADMIN_IDS "${TELEGRAM_ADMIN_IDS:-}" \
        TELEGRAM_CONFIG_MODE "${TELEGRAM_CONFIG_MODE:-plain}"
}

vxd_docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

vxd_validate_user_tag() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }
vxd_validate_date_or_empty() { [[ -z "$1" || "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }
vxd_validate_protocol() { [[ "$1" =~ ^(tls|reality|all)$ ]]; }

vxd_json_escape() {
    jq -Rn --arg v "${1:-}" '$v'
}

vxd_yaml_quote() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

vxd_validate_clash_config_file() {
    local file="$1"
    [[ -s "$file" ]] || { echo "Generated Clash config is empty" >&2; return 1; }
    if grep -q '{{[A-Z_][A-Z0-9_]*}}' "$file"; then
        echo "Generated Clash config still contains template placeholders" >&2
        return 1
    fi
    grep -q '^proxies:' "$file" || { echo "Generated Clash config misses proxies section" >&2; return 1; }
    grep -q '^proxy-groups:' "$file" || { echo "Generated Clash config misses proxy-groups section" >&2; return 1; }
    grep -q 'type: vless' "$file" || { echo "Generated Clash config misses VLESS proxy" >&2; return 1; }
}

vxd_parse_reality_key_output() {
    local output="$1" private public
    private="$(printf '%s\n' "$output" | awk -F: 'tolower($1) ~ /private/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
    public="$(printf '%s\n' "$output" | awk -F: 'tolower($1) ~ /public/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
    [[ -n "$private" && -n "$public" ]] || return 1
    printf '%s\t%s\n' "$private" "$public"
}

vxd_generate_reality_keys() {
    local output parsed last_output xray_image
    xray_image="${XRAY_IMAGE:-$VXD_DEFAULT_XRAY_IMAGE}"

    if command -v xray >/dev/null 2>&1; then
        output="$(xray x25519 2>&1)" || true
        parsed="$(vxd_parse_reality_key_output "$output" 2>/dev/null || true)"
        [[ -n "$parsed" ]] && {
            printf '%s\n' "$parsed"
            return 0
        }
        last_output="$output"
    fi

    if command -v docker >/dev/null 2>&1; then
        output="$(docker run --rm "$xray_image" x25519 2>&1)" || true
        parsed="$(vxd_parse_reality_key_output "$output" 2>/dev/null || true)"
        [[ -n "$parsed" ]] && {
            printf '%s\n' "$parsed"
            return 0
        }
        last_output="$output"

        local entrypoint
        for entrypoint in xray /usr/bin/xray /usr/local/bin/xray; do
            output="$(docker run --rm --entrypoint "$entrypoint" "$xray_image" x25519 2>&1)" || true
            parsed="$(vxd_parse_reality_key_output "$output" 2>/dev/null || true)"
            [[ -n "$parsed" ]] && {
                printf '%s\n' "$parsed"
                return 0
            }
            last_output="$output"
        done
    fi

    [[ -n "${last_output:-}" ]] && printf '%s\n' "$last_output" >&2
    return 1
}

vxd_ensure_reality_config() {
    vxd_load_main_config || true
    local changed=0
    if [[ -f "$VXD_CONFIG_FILE" ]]; then
        grep -q '^REALITY_SERVER_NAME=' "$VXD_CONFIG_FILE" || changed=1
        grep -q '^REALITY_DEST=' "$VXD_CONFIG_FILE" || changed=1
    fi
    REALITY_ENABLED="${REALITY_ENABLED:-true}"
    [[ "$REALITY_ENABLED" == "true" ]] || return 0
    if [[ -z "${REALITY_SERVER_NAME:-}" ]]; then
        REALITY_SERVER_NAME="$VXD_DEFAULT_REALITY_SERVER_NAME"
        changed=1
    fi
    if [[ -z "${REALITY_DEST:-}" ]]; then
        REALITY_DEST="${REALITY_SERVER_NAME}:443"
        changed=1
    fi
    if [[ -n "${DOMAIN:-}" && "$REALITY_SERVER_NAME" == "$DOMAIN" ]]; then
        echo "REALITY_SERVER_NAME must differ from DOMAIN for nginx SNI split" >&2
        return 1
    fi
    if [[ -z "${REALITY_SHORT_ID:-}" ]]; then
        REALITY_SHORT_ID="$(openssl rand -hex 8)"
        changed=1
    fi
    if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
        local keys
        keys="$(vxd_generate_reality_keys)" || {
            echo "Failed to generate REALITY x25519 keys. Make sure xray or docker is available." >&2
            return 1
        }
        REALITY_PRIVATE_KEY="${keys%%$'\t'*}"
        REALITY_PUBLIC_KEY="${keys#*$'\t'}"
        changed=1
    fi
    if [[ "$changed" -eq 1 ]]; then
        vxd_persist_reality_config || return 1
    fi
    return 0
}

vxd_parse_bytes() {
    local input="${1:-0}"
    input="${input// /}"
    if [[ -z "$input" || "$input" =~ ^(none|off|unlimited|0)$ ]]; then
        echo 0
        return 0
    fi
    if [[ "$input" =~ ^([0-9]+)([KkMmGgTtPp])?[Bb]?$ ]]; then
        local n="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]:-}"
        local mul=1
        n=$((10#$n))
        case "${unit^^}" in
            K) mul=1024 ;;
            M) mul=$((1024**2)) ;;
            G) mul=$((1024**3)) ;;
            T) mul=$((1024**4)) ;;
            P) mul=$((1024**5)) ;;
        esac
        echo $((n * mul))
        return 0
    fi
    return 1
}

vxd_format_bytes() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN {
      split("B KiB MiB GiB TiB PiB", u, " ");
      i=1;
      while (b >= 1024 && i < 6) { b /= 1024; i++ }
      if (i == 1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i]
    }'
}

vxd_generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        local hex
        hex="$(openssl rand -hex 16)"
        printf '%s-%s-%s-%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
    fi
}

vxd_ensure_dirs() {
    mkdir -p "$VXD_DATA_DIR" "$VXD_BACKUP_DIR" "$VXD_LOG_DIR/telegram-bot" "$VXD_USER_LOG_DIR" "$VXD_INSTALL_DIR/tmp"
    chmod 700 "$VXD_DATA_DIR" "$VXD_BACKUP_DIR" "$VXD_INSTALL_DIR/tmp" 2>/dev/null || true
    chmod 700 "$VXD_LOG_DIR/telegram-bot" "$VXD_USER_LOG_DIR" 2>/dev/null || true
}

vxd_cleanup_user_db_temps() {
    [[ -d "$VXD_DATA_DIR" ]] || return 0
    find "$VXD_DATA_DIR" -maxdepth 1 -type f \
        \( -name 'users.json.tmp.*' -o -name 'users.json.migrate.*' -o -name 'users.json.repair.*' \) \
        -delete 2>/dev/null || true
}

vxd_migrate_user_db() {
    [[ -f "$VXD_USERS_DB" ]] || return 0
    local tmp
    tmp="$(mktemp "$VXD_USERS_DB.migrate.XXXXXX")"
    if ! jq --arg now "$(vxd_now)" '
      if type == "array" then {users:.} else . end |
      .users = (.users // []) |
      .users |= map(
        .traffic_limit_bytes = ((.traffic_limit_bytes // 0) | tonumber) |
        .traffic_used_bytes = ((.traffic_used_bytes // 0) | tonumber) |
        .traffic_auto_disable = (.traffic_auto_disable // true) |
        .traffic_updated_at = (.traffic_updated_at // "") |
        .traffic_limited_at = (.traffic_limited_at // "") |
        .updated_at = (.updated_at // $now)
      )
    ' "$VXD_USERS_DB" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$VXD_USERS_DB" || { rm -f "$tmp"; return 1; }
    chmod 600 "$VXD_USERS_DB"
}

vxd_user_db_is_valid() {
    [[ -f "$VXD_USERS_DB" ]] && jq -e '((type == "object") and ((.users // []) | type == "array")) or (type == "array")' "$VXD_USERS_DB" >/dev/null 2>&1
}

vxd_repair_user_db() {
    [[ -f "$VXD_USERS_DB" ]] || return 0
    vxd_load_main_config || true

    local now domain admin_tag limit tmp
    now="$(vxd_now)"
    domain="${DOMAIN:-example.com}"
    admin_tag="${ADMIN_USER_TAG:-$VXD_DEFAULT_ADMIN_USER_TAG}"
    limit="$(vxd_parse_bytes "${TRAFFIC_DEFAULT_LIMIT:-$VXD_DEFAULT_TRAFFIC_LIMIT}" 2>/dev/null || echo 0)"

    if [[ -n "${UUID:-}" ]] && ! jq -e --arg tag "$admin_tag" --arg uuid "$UUID" 'any((.users // [])[]?; (.tag == $tag) or (.uuid == $uuid))' "$VXD_USERS_DB" >/dev/null 2>&1; then
        tmp="$(mktemp "$VXD_USERS_DB.repair.XXXXXX")"
        if ! jq --arg tag "$admin_tag" --arg uuid "$UUID" --arg domain "$domain" --arg now "$now" '
          .users = (.users // []) |
          .users += [{
            tag:$tag,
            uuid:$uuid,
            email:($tag+"@"+$domain),
            enabled:true,
            expire_at:"",
            remark:"admin user (unlimited)",
            traffic_limit_bytes:0,
            traffic_used_bytes:0,
            traffic_auto_disable:false,
            traffic_updated_at:"",
            traffic_limited_at:"",
            created_at:$now,
            updated_at:$now
          }]
        ' "$VXD_USERS_DB" > "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        mv "$tmp" "$VXD_USERS_DB" || { rm -f "$tmp"; return 1; }
    fi

    if [[ -f "$VXD_XRAY_CONFIG" ]] && jq -e . "$VXD_XRAY_CONFIG" >/dev/null 2>&1; then
        tmp="$(mktemp "$VXD_USERS_DB.repair.XXXXXX")"
        if ! jq \
          --slurpfile xray "$VXD_XRAY_CONFIG" \
          --arg tls_tag "$VXD_XRAY_INBOUND_TAG" \
          --arg reality_tag "$VXD_REALITY_INBOUND_TAG" \
          --arg domain "$domain" \
          --arg admin "$admin_tag" \
          --arg now "$now" \
          --argjson limit "$limit" '
          def client_tag:
            if ((.email // "") | length) > 0 then ((.email // "") | split("@")[0])
            else (((.id // "user") | tostring)[0:8])
            end;
          ([
            $xray[0].inbounds[]? |
            select((.tag == $tls_tag) or (.tag == $reality_tag)) |
            .settings.clients[]? |
            client_tag as $tag |
            {
              tag:$tag,
              uuid:(.id // ""),
              email:(((.email // "") as $email | if ($email | length) > 0 then $email else ($tag+"@"+$domain) end))
            }
          ] | map(select((.uuid // "") != "")) | unique_by(.uuid)) as $clients |
          .users = (.users // []) |
          reduce $clients[] as $c (.;
            if any((.users // [])[]?; (.uuid == $c.uuid) or (.tag == $c.tag)) then
              .
            else
              .users += [{
                tag:$c.tag,
                uuid:$c.uuid,
                email:$c.email,
                enabled:true,
                expire_at:"",
                remark:(if $c.tag == $admin then "admin user (unlimited)" else "imported from xray/config.json" end),
                traffic_limit_bytes:(if $c.tag == $admin then 0 else $limit end),
                traffic_used_bytes:0,
                traffic_auto_disable:($c.tag != $admin),
                traffic_updated_at:"",
                traffic_limited_at:"",
                created_at:$now,
                updated_at:$now
              }]
            end
          )
        ' "$VXD_USERS_DB" > "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        mv "$tmp" "$VXD_USERS_DB" || { rm -f "$tmp"; return 1; }
    fi

    tmp="$(mktemp "$VXD_USERS_DB.repair.XXXXXX")"
    if ! jq --arg admin "$admin_tag" --arg now "$now" '
      .users = (.users // []) |
      .users |= map(
        if .tag == $admin then
          .traffic_limit_bytes = 0 |
          .traffic_auto_disable = false |
          .updated_at = (.updated_at // $now)
        else
          .
        end
      )
    ' "$VXD_USERS_DB" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$VXD_USERS_DB" || { rm -f "$tmp"; return 1; }

    chmod 600 "$VXD_USERS_DB" 2>/dev/null || true
}

vxd_ensure_user_db() {
    vxd_ensure_dirs
    vxd_cleanup_user_db_temps

    if [[ -f "$VXD_USERS_DB" ]]; then
        if vxd_user_db_is_valid; then
            vxd_migrate_user_db || return 1
            vxd_repair_user_db || return 1
            vxd_user_db_is_valid && return 0
        fi
        mv "$VXD_USERS_DB" "$VXD_USERS_DB.broken.$(vxd_ts)" 2>/dev/null || true
    fi

    local now domain uuid tmp admin_tag
    now="$(vxd_now)"
    domain="${DOMAIN:-example.com}"
    uuid="${UUID:-}"
    admin_tag="${ADMIN_USER_TAG:-$VXD_DEFAULT_ADMIN_USER_TAG}"
    tmp="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"

    if [[ -n "$uuid" ]]; then
        jq -n --arg tag "$admin_tag" --arg uuid "$uuid" --arg domain "$domain" --arg now "$now" '
          {users:[{
            tag:$tag,
            uuid:$uuid,
            email:($tag+"@"+$domain),
            enabled:true,
            expire_at:"",
            remark:"admin user (unlimited)",
            traffic_limit_bytes:0,
            traffic_used_bytes:0,
            traffic_auto_disable:false,
            traffic_updated_at:"",
            traffic_limited_at:"",
            created_at:$now,
            updated_at:$now
          }]}
        ' > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        jq -n '{users:[]}' > "$tmp" || { rm -f "$tmp"; return 1; }
    fi

    mv "$tmp" "$VXD_USERS_DB" || { rm -f "$tmp"; return 1; }
    chmod 600 "$VXD_USERS_DB"
    vxd_repair_user_db || return 1
}

vxd_traffic_users_db() {
    vxd_ensure_user_db || return 1
    if jq -e '((type == "object") and ((.users // []) | type == "array"))' "$VXD_USERS_DB" >/dev/null 2>&1; then
        cat "$VXD_USERS_DB"
    elif jq -e 'type == "array"' "$VXD_USERS_DB" >/dev/null 2>&1; then
        jq '{users:.}' "$VXD_USERS_DB"
    else
        jq -n '{users:[]}'
    fi
}

vxd_active_clients_json() {
    local domain="${DOMAIN:-example.com}"
    local today
    today="$(vxd_today)"
    vxd_ensure_user_db
    jq --arg domain "$domain" --arg today "$today" '[
      .users[]? |
      select((.enabled // true) == true) |
      select(((.expire_at // "") == "") or ((.expire_at // "") >= $today)) |
      {id:.uuid, email:((.tag // "user") + "@" + $domain), flow:"xtls-rprx-vision", level:0}
    ]' "$VXD_USERS_DB"
}

vxd_render_xray_config() {
    vxd_load_main_config || true
    [[ -n "${DOMAIN:-}" ]] || { echo "DOMAIN is not set" >&2; return 1; }
    [[ -f "$VXD_XRAY_TEMPLATE" ]] || { echo "Missing template: $VXD_XRAY_TEMPLATE" >&2; return 1; }
    vxd_ensure_reality_config || return 1
    vxd_ensure_user_db

    local tmp base clients
    tmp="$(mktemp "$VXD_XRAY_CONFIG.render.XXXXXX")"
    base="$(mktemp "$VXD_XRAY_CONFIG.base.XXXXXX")"
    clients="$(vxd_active_clients_json)"

    sed -e "s/{{UUID}}/${UUID:-00000000-0000-0000-0000-000000000000}/g" \
        -e "s/{{DOMAIN}}/$DOMAIN/g" \
        -e "s/{{REALITY_SERVER_NAME}}/${REALITY_SERVER_NAME:-$VXD_DEFAULT_REALITY_SERVER_NAME}/g" \
        -e "s/{{REALITY_DEST}}/${REALITY_DEST:-${REALITY_SERVER_NAME:-$VXD_DEFAULT_REALITY_SERVER_NAME}:443}/g" \
        -e "s/{{REALITY_PRIVATE_KEY}}/${REALITY_PRIVATE_KEY:-}/g" \
        -e "s/{{REALITY_SHORT_ID}}/${REALITY_SHORT_ID:-}/g" \
        "$VXD_XRAY_TEMPLATE" > "$base"

    jq --arg tls_tag "$VXD_XRAY_INBOUND_TAG" --arg reality_tag "$VXD_REALITY_INBOUND_TAG" --argjson clients "$clients" '
      (.inbounds[] | select(.tag == $tls_tag).settings.clients) = $clients |
      (.inbounds[] | select(.tag == $reality_tag).settings.clients) = $clients
    ' "$base" > "$tmp"

    mv "$tmp" "$VXD_XRAY_CONFIG"
    rm -f "$base"
    chmod 600 "$VXD_XRAY_CONFIG"
}

vxd_backup_state() {
    local reason="${1:-manual}"
    vxd_ensure_dirs
    reason="${reason//[^A-Za-z0-9._-]/_}"
    local dir="$VXD_BACKUP_DIR/$(vxd_ts)-$reason"
    mkdir -p "$dir"
    [[ -f "$VXD_CONFIG_FILE" ]] && cp "$VXD_CONFIG_FILE" "$dir/.env"
    [[ -f "$VXD_TELEGRAM_CONFIG_FILE" ]] && cp "$VXD_TELEGRAM_CONFIG_FILE" "$dir/.env.telegram"
    [[ -f "$VXD_USERS_DB" ]] && mkdir -p "$dir/data" && cp "$VXD_USERS_DB" "$dir/data/users.json"
    [[ -f "$VXD_XRAY_CONFIG" ]] && mkdir -p "$dir/xray" && cp "$VXD_XRAY_CONFIG" "$dir/xray/config.json"
    [[ -f "$VXD_NGINX_CONFIG" ]] && mkdir -p "$dir/nginx" && cp "$VXD_NGINX_CONFIG" "$dir/nginx/nginx.conf"
    echo "$dir"
}

vxd_restore_state() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    [[ -f "$dir/.env" ]] && cp "$dir/.env" "$VXD_CONFIG_FILE"
    [[ -f "$dir/.env.telegram" ]] && cp "$dir/.env.telegram" "$VXD_TELEGRAM_CONFIG_FILE"
    [[ -f "$dir/data/users.json" ]] && mkdir -p "$VXD_DATA_DIR" && cp "$dir/data/users.json" "$VXD_USERS_DB"
    [[ -f "$dir/xray/config.json" ]] && mkdir -p "$VXD_INSTALL_DIR/xray" && cp "$dir/xray/config.json" "$VXD_XRAY_CONFIG"
    [[ -f "$dir/nginx/nginx.conf" ]] && mkdir -p "$VXD_INSTALL_DIR/nginx" && cp "$dir/nginx/nginx.conf" "$VXD_NGINX_CONFIG"
}

vxd_restart_xray_with_rollback() {
    local backup_dir="$1"
    cd "$VXD_INSTALL_DIR" || return 1
    if vxd_docker_compose restart xray; then
        return 0
    fi
    vxd_log "xray restart failed, rolling back from $backup_dir" >&2
    vxd_restore_state "$backup_dir" || true
    vxd_docker_compose restart xray >/dev/null 2>&1 || true
    return 1
}

vxd_user_find() {
    local ident="$1"
    vxd_ensure_user_db
    jq -c --arg ident "$ident" '.users[]? | select(.uuid == $ident or .tag == $ident or .email == $ident)' "$VXD_USERS_DB" | head -n 1
}

vxd_user_count() {
    vxd_ensure_user_db
    jq -r '.users | length' "$VXD_USERS_DB"
}

vxd_user_add() {
    local tag="$1"
    local uuid="${2:-$(vxd_generate_uuid)}"
    local expire_at="${3:-}"
    local remark="${4:-}"
    vxd_validate_user_tag "$tag" || return 2
    vxd_validate_date_or_empty "$expire_at" || return 3
    vxd_ensure_user_db
    if [[ -n "$(vxd_user_find "$tag")" ]]; then
        return 4
    fi
    local now tmp domain
    now="$(vxd_now)"
    domain="${DOMAIN:-example.com}"
    tmp="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"
    local limit auto_disable
    if vxd_is_admin_tag "$tag"; then
        limit=0
        auto_disable=false
    else
        limit="$(vxd_parse_bytes "${TRAFFIC_DEFAULT_LIMIT:-$VXD_DEFAULT_TRAFFIC_LIMIT}" 2>/dev/null || echo 0)"
        auto_disable=true
    fi
    jq --arg tag "$tag" --arg uuid "$uuid" --arg email "$tag@$domain" --arg expire "$expire_at" --arg remark "$remark" --arg now "$now" --argjson limit "$limit" --argjson auto_disable "$auto_disable" '
      .users += [{tag:$tag,uuid:$uuid,email:$email,enabled:true,expire_at:$expire,remark:$remark,traffic_limit_bytes:$limit,traffic_used_bytes:0,traffic_auto_disable:$auto_disable,traffic_updated_at:"",traffic_limited_at:"",created_at:$now,updated_at:$now}]
    ' "$VXD_USERS_DB" > "$tmp" && mv "$tmp" "$VXD_USERS_DB"
    chmod 600 "$VXD_USERS_DB"
}

vxd_user_delete() {
    local ident="$1"
    local user uuid tmp
    user="$(vxd_user_find "$ident")"
    [[ -n "$user" ]] || return 4
    uuid="$(jq -r '.uuid' <<< "$user")"
    tmp="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"
    jq --arg uuid "$uuid" '.users |= map(select(.uuid != $uuid))' "$VXD_USERS_DB" > "$tmp" && mv "$tmp" "$VXD_USERS_DB"
    chmod 600 "$VXD_USERS_DB"
}

vxd_user_set_enabled() {
    local ident="$1"
    local enabled="$2"
    local user uuid now tmp
    user="$(vxd_user_find "$ident")"
    [[ -n "$user" ]] || return 4
    uuid="$(jq -r '.uuid' <<< "$user")"
    now="$(vxd_now)"
    tmp="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"
    jq --arg uuid "$uuid" --argjson enabled "$enabled" --arg now "$now" '(.users[] | select(.uuid == $uuid)) |= (.enabled=$enabled | .updated_at=$now)' "$VXD_USERS_DB" > "$tmp" && mv "$tmp" "$VXD_USERS_DB"
    chmod 600 "$VXD_USERS_DB"
}

vxd_user_set_expire() {
    local ident="$1"
    local expire_at="$2"
    vxd_validate_date_or_empty "$expire_at" || return 3
    local user uuid now tmp
    user="$(vxd_user_find "$ident")"
    [[ -n "$user" ]] || return 4
    uuid="$(jq -r '.uuid' <<< "$user")"
    now="$(vxd_now)"
    tmp="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"
    jq --arg uuid "$uuid" --arg expire "$expire_at" --arg now "$now" '(.users[] | select(.uuid == $uuid)) |= (.expire_at=$expire | .updated_at=$now)' "$VXD_USERS_DB" > "$tmp" && mv "$tmp" "$VXD_USERS_DB"
    chmod 600 "$VXD_USERS_DB"
}

vxd_user_set_remark() {
    local ident="$1"
    local remark="$2"
    local user uuid now tmp
    user="$(vxd_user_find "$ident")"
    [[ -n "$user" ]] || return 4
    uuid="$(jq -r '.uuid' <<< "$user")"
    now="$(vxd_now)"
    tmp="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"
    jq --arg uuid "$uuid" --arg remark "$remark" --arg now "$now" '(.users[] | select(.uuid == $uuid)) |= (.remark=$remark | .updated_at=$now)' "$VXD_USERS_DB" > "$tmp" && mv "$tmp" "$VXD_USERS_DB"
    chmod 600 "$VXD_USERS_DB"
}

vxd_user_set_limit() {
    local ident="$1"
    local limit_bytes="$2"
    local user uuid now tmp
    user="$(vxd_user_find "$ident")"
    [[ -n "$user" ]] || return 4
    uuid="$(jq -r '.uuid' <<< "$user")"
    now="$(vxd_now)"
    tmp="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"
    jq --arg uuid "$uuid" --argjson limit "$limit_bytes" --arg now "$now" '
      (.users[] | select(.uuid == $uuid)) |= (.traffic_limit_bytes=$limit | .updated_at=$now)
    ' "$VXD_USERS_DB" > "$tmp" && mv "$tmp" "$VXD_USERS_DB"
    chmod 600 "$VXD_USERS_DB"
}

vxd_user_reset_traffic() {
    local ident="$1"
    local now tmp
    now="$(vxd_now)"
    vxd_ensure_user_db
    tmp="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"
    if [[ "$ident" == "all" ]]; then
        jq --arg now "$now" '.users |= map(.traffic_used_bytes=0 | .traffic_updated_at=$now | .traffic_limited_at="")' "$VXD_USERS_DB" > "$tmp"
    else
        local user uuid
        user="$(vxd_user_find "$ident")"
        [[ -n "$user" ]] || { rm -f "$tmp"; return 4; }
        uuid="$(jq -r '.uuid' <<< "$user")"
        jq --arg uuid "$uuid" --arg now "$now" '(.users[] | select(.uuid == $uuid)) |= (.traffic_used_bytes=0 | .traffic_updated_at=$now | .traffic_limited_at="")' "$VXD_USERS_DB" > "$tmp"
    fi
    mv "$tmp" "$VXD_USERS_DB"
    chmod 600 "$VXD_USERS_DB"
}

vxd_reset_monthly_traffic() {
    vxd_load_main_config || true
    vxd_ensure_user_db
    local now tmp admin_tag
    now="$(vxd_now)"
    admin_tag="${ADMIN_USER_TAG:-$VXD_DEFAULT_ADMIN_USER_TAG}"
    tmp="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"
    jq --arg now "$now" --arg admin "$admin_tag" '
      .users |= map(
        if (.tag == $admin) then
          .traffic_limit_bytes = 0 |
          .traffic_auto_disable = false |
          .traffic_updated_at = $now
        else
          .traffic_used_bytes = 0 |
          .traffic_updated_at = $now |
          (if ((.traffic_limited_at // "") != "") then .enabled = true else . end) |
          .traffic_limited_at = "" |
          .updated_at = $now
        end
      )
    ' "$VXD_USERS_DB" > "$tmp" && mv "$tmp" "$VXD_USERS_DB"
    chmod 600 "$VXD_USERS_DB"
}

vxd_users_table() {
    vxd_load_main_config || true
    vxd_ensure_user_db
    local today
    today="$(vxd_today)"
    jq -r --arg today "$today" '
      .users[]? |
      [
        .tag,
        (.uuid[0:8] + "..."),
        (if (.enabled // true) then "enabled" else "disabled" end),
        (if ((.expire_at // "") == "") then "never" else .expire_at end),
        (if (((.expire_at // "") != "") and ((.expire_at // "") < $today)) then "expired" else "active" end),
        ((.traffic_used_bytes // 0) | tostring),
        ((.traffic_limit_bytes // 0) | tostring),
        (.remark // "")
      ] | @tsv
    ' "$VXD_USERS_DB"
}

vxd_vless_link() {
    local uuid="$1"
    local name="$2"
    local protocol="${3:-tls}"
    vxd_load_main_config || true
    case "$protocol" in
        reality)
            printf 'vless://%s@%s:443?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s' \
              "$uuid" "$DOMAIN" "${REALITY_SERVER_NAME:-$VXD_DEFAULT_REALITY_SERVER_NAME}" "${REALITY_PUBLIC_KEY:-}" "${REALITY_SHORT_ID:-}" "$name"
            ;;
        tls|*)
            printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision#%s' \
              "$uuid" "$DOMAIN" "$DOMAIN" "$name"
            ;;
    esac
}

vxd_make_clash_config() {
    local user_json="$1"
    local out_file="$2"
    local protocol="${3:-tls}"
    vxd_load_main_config || true
    vxd_validate_protocol "$protocol" || { echo "Invalid protocol: $protocol" >&2; return 2; }
    if [[ "$protocol" == "reality" || "$protocol" == "all" ]]; then
        vxd_ensure_reality_config || return 1
    fi
    local uuid tag prefix base_name allow_lan mode proxies_yaml proxy_names_yaml tls_name reality_name q_tls_name q_reality_name q_domain q_uuid q_reality_server q_reality_public q_reality_short
    uuid="$(jq -r '.uuid // .id' <<< "$user_json")"
    tag="$(jq -r '.tag // (.email | split("@")[0])' <<< "$user_json")"
    prefix="${CLASH_PROXY_NAME_PREFIX:-}"
    if [[ -n "$prefix" ]]; then
        base_name="${prefix}-${tag}"
    else
        base_name="${tag}-VLESS"
    fi
    allow_lan="${CLASH_ALLOW_LAN:-true}"
    mode="${CLASH_MODE:-rule}"
    tls_name="$base_name"
    reality_name="${base_name}-REALITY"
    [[ "$protocol" == "all" ]] && tls_name="${base_name}-TLS"
    q_tls_name="$(vxd_yaml_quote "$tls_name")"
    q_reality_name="$(vxd_yaml_quote "$reality_name")"
    q_domain="$(vxd_yaml_quote "$DOMAIN")"
    q_uuid="$(vxd_yaml_quote "$uuid")"
    q_reality_server="$(vxd_yaml_quote "${REALITY_SERVER_NAME:-$VXD_DEFAULT_REALITY_SERVER_NAME}")"
    q_reality_public="$(vxd_yaml_quote "${REALITY_PUBLIC_KEY:-}")"
    q_reality_short="$(vxd_yaml_quote "${REALITY_SHORT_ID:-}")"

    proxies_yaml=""
    proxy_names_yaml=""
    if [[ "$protocol" == "tls" || "$protocol" == "all" ]]; then
        proxies_yaml+="  - name: $q_tls_name
    server: $q_domain
    port: 443
    type: vless
    uuid: $q_uuid
    encryption: none
    tls: true
    udp: true
    flow: xtls-rprx-vision
    packet-encoding: xudp
    skip-cert-verify: false
    servername: $q_domain
    client-fingerprint: chrome
    network: tcp"
        proxy_names_yaml+="      - $q_tls_name"
    fi
    if [[ "$protocol" == "reality" || "$protocol" == "all" ]]; then
        [[ -n "$proxies_yaml" ]] && proxies_yaml+=$'\n'
        [[ -n "$proxy_names_yaml" ]] && proxy_names_yaml+=$'\n'
        proxies_yaml+="  - name: $q_reality_name
    server: $q_domain
    port: 443
    type: vless
    uuid: $q_uuid
    encryption: none
    tls: true
    udp: true
    flow: xtls-rprx-vision
    packet-encoding: xudp
    skip-cert-verify: false
    servername: $q_reality_server
    client-fingerprint: chrome
    network: tcp
    reality-opts:
      public-key: $q_reality_public
      short-id: $q_reality_short"
        proxy_names_yaml+="      - $q_reality_name"
    fi

    if [[ -f "$VXD_CLASH_TEMPLATE" ]]; then
        local line clean_line
        : > "$out_file"
        while IFS= read -r line || [[ -n "$line" ]]; do
            clean_line="${line%$'\r'}"
            case "$clean_line" in
                "{{PROXIES}}")
                    printf '%s\n' "$proxies_yaml" >> "$out_file"
                    ;;
                "{{PROXY_NAMES}}")
                    printf '%s\n' "$proxy_names_yaml" >> "$out_file"
                    ;;
                allow-lan:*)
                    printf 'allow-lan: %s\n' "$allow_lan" >> "$out_file"
                    ;;
                mode:*)
                    printf 'mode: %s\n' "$mode" >> "$out_file"
                    ;;
                *)
                    printf '%s\n' "$clean_line" >> "$out_file"
                    ;;
            esac
        done < "$VXD_CLASH_TEMPLATE"
    else
        cat > "$out_file" << EOF
port: 7890
socks-port: 7891
allow-lan: $allow_lan
mode: $mode
log-level: info
proxies:
$proxies_yaml
proxy-groups:
  - name: PROXY
    type: select
    proxies:
$proxy_names_yaml
rules:
  - MATCH,PROXY
EOF
    fi
    vxd_validate_clash_config_file "$out_file"
}

vxd_audit() {
    local actor="${1:-unknown}"
    local action="${2:-unknown}"
    local target="${3:-}"
    local result="${4:-}"
    vxd_ensure_dirs
    target="${target:0:128}"
    printf '[%s] actor=%s action=%s target=%s result=%s\n' "$(vxd_now)" "$actor" "$action" "$target" "$result" >> "$VXD_AUDIT_LOG"
    chmod 600 "$VXD_AUDIT_LOG" 2>/dev/null || true
}

vxd_cert_days_left() {
    local cert="$VXD_INSTALL_DIR/certs/fullchain.pem"
    [[ -f "$cert" ]] || { echo "missing"; return 1; }
    local expiry current days
    expiry="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)" || return 1
    current="$(date +%s)"
    days=$(( ( $(date -d "$expiry" +%s) - current ) / 86400 ))
    echo "$days"
}

vxd_ensure_traffic_db() {
    vxd_ensure_dirs
    if [[ -f "$VXD_TRAFFIC_DB" ]] && jq -e '.users | type == "object"' "$VXD_TRAFFIC_DB" >/dev/null 2>&1; then
        return 0
    fi
    jq -n '{users:{}, updated_at:""}' > "$VXD_TRAFFIC_DB"
    chmod 600 "$VXD_TRAFFIC_DB"
}

vxd_collect_traffic_tsv() {
    local raw line name value email tag dir tmp
    tmp="$(mktemp)"
    if ! raw="$(docker exec xray xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>" 2>/dev/null)"; then
        rm -f "$tmp"
        return 1
    fi

    if jq -e . >/dev/null 2>&1 <<< "$raw"; then
        while IFS=$'\t' read -r name value; do
            [[ -n "$name" ]] || continue
            if [[ "$name" =~ user\>\>\>([^[:space:]\>]+)\>\>\>traffic\>\>\>(uplink|downlink) ]]; then
                email="${BASH_REMATCH[1]}"
                dir="${BASH_REMATCH[2]}"
                tag="${email%@*}"
                printf '%s\t%s\t%s\n' "$tag" "$dir" "${value:-0}" >> "$tmp"
            fi
        done < <(jq -r '(.stat // .stats // [])[]? | [.name, (.value // 0)] | @tsv' <<< "$raw")
    else
        while IFS= read -r line; do
            if [[ "$line" =~ user\>\>\>([^[:space:]\>]+)\>\>\>traffic\>\>\>(uplink|downlink).*value[[:space:]]*[:=][[:space:]]*([0-9]+) ]]; then
                email="${BASH_REMATCH[1]}"
                dir="${BASH_REMATCH[2]}"
                value="${BASH_REMATCH[3]}"
                tag="${email%@*}"
                printf '%s\t%s\t%s\n' "$tag" "$dir" "$value" >> "$tmp"
            fi
        done <<< "$raw"
    fi

    awk -F '\t' '
      { if ($2=="uplink") up[$1]+=$3; else if ($2=="downlink") down[$1]+=$3; seen[$1]=1 }
      END { for (u in seen) printf "%s\t%d\t%d\n", u, up[u]+0, down[u]+0 }
    ' "$tmp"
    rm -f "$tmp"
}

vxd_refresh_traffic_baseline() {
    local filter="${1:-all}" collect_file now tag uplink downlink current tmp
    vxd_ensure_traffic_db
    collect_file="$(mktemp)"
    if ! vxd_collect_traffic_tsv > "$collect_file"; then
        rm -f "$collect_file"
        return 1
    fi

    now="$(vxd_now)"
    while IFS=$'\t' read -r tag uplink downlink; do
        [[ -n "$tag" ]] || continue
        [[ "$filter" == "all" || "$filter" == "$tag" ]] || continue
        current=$((uplink + downlink))
        tmp="$(mktemp "$VXD_TRAFFIC_DB.tmp.XXXXXX")"
        if ! jq --arg tag "$tag" --argjson up "$uplink" --argjson down "$downlink" --argjson total "$current" --arg now "$now" '
          .users[$tag] = {uplink:$up,downlink:$down,last_total:$total,updated_at:$now} | .updated_at=$now
        ' "$VXD_TRAFFIC_DB" > "$tmp"; then
            rm -f "$tmp" "$collect_file"
            return 1
        fi
        mv "$tmp" "$VXD_TRAFFIC_DB" || { rm -f "$tmp" "$collect_file"; return 1; }
    done < "$collect_file"
    rm -f "$collect_file"
    chmod 600 "$VXD_TRAFFIC_DB" 2>/dev/null || true
}

vxd_traffic_over_limit_tags() {
    vxd_ensure_user_db
    jq -r '
      .users[]? |
      select((.enabled // true) == true) |
      select((.traffic_auto_disable // true) == true) |
      select(((.traffic_limit_bytes // 0) | tonumber) > 0) |
      select(((.traffic_used_bytes // 0) | tonumber) >= ((.traffic_limit_bytes // 0) | tonumber)) |
      .tag
    ' "$VXD_USERS_DB"
}

vxd_enforce_traffic_limits() {
    vxd_ensure_user_db
    local now over tag tmp disabled
    now="$(vxd_now)"
    disabled=""
    over="$(vxd_traffic_over_limit_tags)"
    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        vxd_user_set_enabled "$tag" false || return 1
        tmp="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"
        if ! jq --arg tag "$tag" --arg now "$now" '
          (.users[] | select(.tag == $tag)) |= (.traffic_limited_at=$now | .updated_at=$now)
        ' "$VXD_USERS_DB" > "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        mv "$tmp" "$VXD_USERS_DB" || { rm -f "$tmp"; return 1; }
        disabled+="${tag}"$'\n'
    done <<< "$over"
    [[ -n "$disabled" ]] && chmod 600 "$VXD_USERS_DB" 2>/dev/null || true
    printf '%s' "$disabled"
}

vxd_update_traffic_usage() {
    vxd_load_main_config || true
    vxd_ensure_user_db
    vxd_ensure_traffic_db

    local now tag uplink downlink current last delta tmp tmp2 collect_file
    now="$(vxd_now)"
    collect_file="$(mktemp)"
    if ! vxd_collect_traffic_tsv > "$collect_file"; then
        rm -f "$collect_file"
        return 1
    fi

    while IFS=$'\t' read -r tag uplink downlink; do
        [[ -n "$tag" ]] || continue
        current=$((uplink + downlink))
        last="$(jq -r --arg tag "$tag" '.users[$tag].last_total // empty' "$VXD_TRAFFIC_DB")"
        if [[ -z "$last" ]]; then
            delta=0
        elif (( current >= last )); then
            delta=$((current - last))
        else
            # Xray stats reset after restart; count current value as new traffic.
            delta="$current"
        fi

        tmp="$(mktemp "$VXD_TRAFFIC_DB.tmp.XXXXXX")"
        if ! jq --arg tag "$tag" --argjson up "$uplink" --argjson down "$downlink" --argjson total "$current" --arg now "$now" '
          .users[$tag] = {uplink:$up,downlink:$down,last_total:$total,updated_at:$now} | .updated_at=$now
        ' "$VXD_TRAFFIC_DB" > "$tmp"; then
            rm -f "$tmp" "$collect_file"
            return 1
        fi
        mv "$tmp" "$VXD_TRAFFIC_DB" || { rm -f "$tmp" "$collect_file"; return 1; }

        if (( delta > 0 )) && jq -e --arg tag "$tag" 'any(.users[]?; .tag == $tag)' "$VXD_USERS_DB" >/dev/null; then
            tmp2="$(mktemp "$VXD_USERS_DB.tmp.XXXXXX")"
            if ! jq --arg tag "$tag" --argjson delta "$delta" --arg now "$now" '
              (.users[] | select(.tag == $tag)) |= (.traffic_used_bytes=((.traffic_used_bytes // 0) + $delta) | .traffic_updated_at=$now)
            ' "$VXD_USERS_DB" > "$tmp2"; then
                rm -f "$tmp2" "$collect_file"
                return 1
            fi
            mv "$tmp2" "$VXD_USERS_DB" || { rm -f "$tmp2" "$collect_file"; return 1; }
        fi
    done < "$collect_file"
    rm -f "$collect_file"

    tmp="$(mktemp "$VXD_TRAFFIC_DB.tmp.XXXXXX")"
    if ! jq --slurpfile userdb <(vxd_traffic_users_db) --arg now "$now" '
      ($userdb[0].users // [] | map(.tag // empty) | map(select(. != "")) | unique) as $tags |
      reduce $tags[] as $tag (.;
        if (.users[$tag]? == null) then
          .users[$tag] = {uplink:0,downlink:0,last_total:null,updated_at:$now}
        else
          .
        end
      ) |
      .updated_at=$now
    ' "$VXD_TRAFFIC_DB" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$VXD_TRAFFIC_DB" || { rm -f "$tmp"; return 1; }

    chmod 600 "$VXD_TRAFFIC_DB" "$VXD_USERS_DB" 2>/dev/null || true
}

vxd_traffic_table() {
    vxd_load_main_config || true
    vxd_ensure_user_db || return 1
    jq -r '
      (.users // [])[]? |
      [
        .tag,
        ((.traffic_used_bytes // 0) | tostring),
        ((.traffic_limit_bytes // 0) | tostring),
        (if ((.traffic_limit_bytes // 0) | tonumber) > 0 then ((((.traffic_used_bytes // 0) | tonumber) * 100 / ((.traffic_limit_bytes // 1) | tonumber)) | floor | tostring) + "%" else "unlimited" end),
        (if (.enabled // true) then "enabled" else "disabled" end),
        (.traffic_updated_at // "")
      ] | @tsv
    ' < <(vxd_traffic_users_db)
}
