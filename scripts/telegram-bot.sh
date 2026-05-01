#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
COMMON_LIB="$INSTALL_DIR/scripts/lib/common.sh"
if grep -q $'\r' "$COMMON_LIB" 2>/dev/null; then
    sed -i 's/\r$//' "$COMMON_LIB" 2>/dev/null || true
fi
# shellcheck source=scripts/lib/common.sh
source "$COMMON_LIB"

TMP_ROOT="${TELEGRAM_TMP_DIR:-$INSTALL_DIR/tmp/telegram-bot}"
LOCK_DIR="$INSTALL_DIR/.telegram-bot.lock"
CONFIRM_TTL_SECONDS="${TELEGRAM_CONFIRM_TTL_SECONDS:-300}"

declare -A PENDING_ACTION=()
declare -A PENDING_TARGET=()
declare -A PENDING_VALUE=()
declare -A PENDING_CREATED=()

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fatal() { log "ERROR: $*"; exit 1; }

require_tools() {
    local missing=() tool
    for tool in curl jq openssl tar gzip; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    [[ ${#missing[@]} -eq 0 ]] || fatal "Missing required tools: ${missing[*]}"
}

load_all_config() {
    vxd_load_main_config || return 1
    vxd_load_telegram_config || true
    TELEGRAM_CONFIG_MODE="${TELEGRAM_CONFIG_MODE:-plain}"
}

telegram_api() {
    local method="$1"
    shift
    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/${method}"
    curl -fsS --config - "$@" << EOF
url = "$url"
EOF
}

html_escape() {
    local value="${1:-}"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    printf '%s' "$value"
}

send_message() {
    local chat_id="$1"
    local text="$2"
    text="${text//\\n/$'\n'}"
    telegram_api sendMessage \
        --data-urlencode "chat_id=$chat_id" \
        --data-urlencode "text=$text" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "disable_web_page_preview=true" >/dev/null || \
    telegram_api sendMessage \
        --data-urlencode "chat_id=$chat_id" \
        --data-urlencode "text=$text" \
        --data-urlencode "disable_web_page_preview=true" >/dev/null
}

send_document() {
    local chat_id="$1"
    local file="$2"
    local caption="${3:-}"
    telegram_api sendDocument \
        -F "chat_id=$chat_id" \
        -F "document=@${file}" \
        --form-string "caption=$caption" >/dev/null
}

admin_ids_normalized() {
    printf '%s' "${TELEGRAM_ADMIN_IDS:-}" | tr ' ' ',' | tr -s ',' ',' | sed 's/^,//;s/,$//'
}

is_authorized() {
    local from_id="$1" ids id
    ids="$(admin_ids_normalized)"
    IFS=',' read -ra admin_ids <<< "$ids"
    for id in "${admin_ids[@]}"; do
        [[ "$id" == "$from_id" ]] && return 0
    done
    return 1
}

acquire_lock() {
    local waited=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        [[ $waited -ge 30 ]] && return 1
    done
    return 0
}
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }

runtime_ready() {
    load_all_config || return 1
    [[ -n "${DOMAIN:-}" && -f "$VXD_XRAY_CONFIG" ]]
}

restart_xray() {
    cd "$INSTALL_DIR" || return 1
    vxd_docker_compose restart xray >/tmp/vless-telegram-bot-restart.log 2>&1
}

with_render_restart() {
    local reason="$1"
    local backup_dir="${2:-}"
    [[ -n "$backup_dir" ]] || backup_dir="$(vxd_backup_state "$reason")"
    if ! vxd_render_xray_config; then
        vxd_restore_state "$backup_dir" || true
        return 1
    fi
    vxd_restart_xray_with_rollback "$backup_dir"
}

short_user_line() {
    local tag="$1" id="$2" status="$3" expire="$4" state="$5" used="$6" limit="$7" remark="$8"
    local icon="✅"
    local limit_text
    [[ "$status" == "disabled" ]] && icon="⏸️"
    [[ "$state" == "expired" ]] && icon="⌛"
    if [[ "$limit" == "0" ]]; then
        limit_text="unlimited"
    else
        limit_text="$(vxd_format_bytes "$limit")"
    fi
    printf '%s <b>%s</b>  <code>%s</code>\n   状态：<code>%s/%s</code>｜过期：<code>%s</code>' \
        "$icon" "$(html_escape "$tag")" "$(html_escape "$id")" "$(html_escape "$status")" "$(html_escape "$state")" "$(html_escape "$expire")"
    printf '\n   流量：<code>%s / %s</code>' "$(html_escape "$(vxd_format_bytes "$used")")" "$(html_escape "$limit_text")"
    [[ -n "$remark" ]] && printf '\n   备注：%s' "$(html_escape "$remark")"
}

request_confirm() {
    local chat_id="$1" from_id="$2" action="$3" target="$4" value="${5:-}"
    local token key now
    token="$(openssl rand -hex 3)"
    key="$chat_id:$token"
    now="$(date +%s)"
    PENDING_ACTION["$key"]="$action"
    PENDING_TARGET["$key"]="$target"
    PENDING_VALUE["$key"]="$value"
    PENDING_CREATED["$key"]="$now"
    vxd_audit "$from_id" "request-$action" "$target" "pending"
    send_message "$chat_id" "🧾 <b>需要二次确认</b>

操作：<code>$(html_escape "$action")</code>
目标：<code>$(html_escape "$target")</code>
有效期：<code>$((CONFIRM_TTL_SECONDS / 60)) 分钟</code>

确认执行：<code>/confirm $token</code>
取消操作：<code>/cancel $token</code>"
}

cmd_confirm() {
    local chat_id="$1" from_id="$2" token="$3"
    [[ -n "$token" ]] || { send_message "$chat_id" "⚠️ 用法：<code>/confirm &lt;code&gt;</code>"; return; }
    local key="$chat_id:$token"
    local action="${PENDING_ACTION[$key]:-}"
    local target="${PENDING_TARGET[$key]:-}"
    local value="${PENDING_VALUE[$key]:-}"
    local created="${PENDING_CREATED[$key]:-0}"
    local now
    now="$(date +%s)"

    if [[ -z "$action" ]]; then
        send_message "$chat_id" "🔎 <b>确认码不存在或已使用</b>"
        return
    fi
    if (( now - created > CONFIRM_TTL_SECONDS )); then
        unset PENDING_ACTION["$key"] PENDING_TARGET["$key"] PENDING_VALUE["$key"] PENDING_CREATED["$key"]
        send_message "$chat_id" "⌛ <b>确认码已过期</b>"
        return
    fi

    unset PENDING_ACTION["$key"] PENDING_TARGET["$key"] PENDING_VALUE["$key"] PENDING_CREATED["$key"]

    case "$action" in
        delete) do_delete "$chat_id" "$from_id" "$target" ;;
        restart) do_restart "$chat_id" "$from_id" ;;
        disable) do_toggle "$chat_id" "$from_id" "$target" false ;;
        *) send_message "$chat_id" "❌ 未知确认动作：<code>$(html_escape "$action")</code>" ;;
    esac
}

cmd_cancel() {
    local chat_id="$1" token="$2"
    [[ -n "$token" ]] || { send_message "$chat_id" "⚠️ 用法：<code>/cancel &lt;code&gt;</code>"; return; }
    local key="$chat_id:$token"
    unset PENDING_ACTION["$key"] PENDING_TARGET["$key"] PENDING_VALUE["$key"] PENDING_CREATED["$key"]
    send_message "$chat_id" "✅ <b>已取消待确认操作</b>"
}

cmd_help() {
    local chat_id="$1"
    send_message "$chat_id" "🛰️ <b>VLESS 管理面板</b>

<b>用户管理</b>
• <code>/users</code> — 列出用户
• <code>/add &lt;tag&gt; [expire YYYY-MM-DD|never] [remark]</code> — 新增用户
• <code>/del &lt;tag&gt;</code> — 删除用户（二次确认）
• <code>/enable &lt;tag&gt;</code> — 启用用户
• <code>/disable &lt;tag&gt;</code> — 禁用用户（二次确认）
• <code>/expire &lt;tag&gt; YYYY-MM-DD|never</code> — 设置过期时间
• <code>/remark &lt;tag&gt; text</code> — 设置备注
• <code>/link &lt;tag&gt; [tls|reality|all]</code> — 返回 VLESS 链接
• <code>/userlog &lt;tag&gt; [lines|file]</code> — 查看/返回该用户日志

<b>配置导出</b>
• <code>/config &lt;tag&gt; [tls|reality|all] [clash|shadowrocket] [plain|tgz|enc] [password]</code>
  默认：<code>all clash plain</code>
  示例：<code>/config alice all shadowrocket enc mypass</code>

<b>流量</b>
• <code>/traffic [tag]</code> — 查看流量统计

<b>运维</b>
• <code>/status</code> — 服务状态
• <code>/restart</code> — 重启 xray（二次确认）
• <code>/confirm &lt;code&gt;</code> — 确认危险操作
• <code>/cancel &lt;code&gt;</code> — 取消待确认操作
• <code>/id</code> — 显示 Telegram ID"
}

cmd_users() {
    local chat_id="$1"
    if ! runtime_ready; then
        send_message "$chat_id" "⚠️ <b>运行配置未就绪</b>\n\n请先完成：<code>./deploy.sh install</code>"
        return
    fi
    vxd_ensure_user_db
    local body="" tag id status expire state used limit remark count=0
    while IFS=$'\t' read -r tag id status expire state used limit remark; do
        [[ -n "$tag" ]] || continue
        body+="$(short_user_line "$tag" "$id" "$status" "$expire" "$state" "$used" "$limit" "$remark")"$'\n\n'
        count=$((count + 1))
    done < <(vxd_users_table)
    if [[ $count -eq 0 ]]; then
        send_message "$chat_id" "👥 <b>用户列表</b>\n\n暂无用户。"
    else
        send_message "$chat_id" "👥 <b>用户列表</b>｜共 <code>$count</code> 个\n\n$body"
    fi
}

cmd_add() {
    local chat_id="$1" from_id="$2" tag="$3" expire_at="${4:-}" remark="${5:-}"
    [[ "$expire_at" == "never" ]] && expire_at=""
    if [[ -z "$tag" || ! "$tag" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        send_message "$chat_id" "⚠️ <b>参数不正确</b>\n\n用法：<code>/add &lt;tag&gt; [expire YYYY-MM-DD|never] [remark]</code>"
        return
    fi
    if [[ -n "$expire_at" && ! "$expire_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        # If the second token is not a date, treat it as remark.
        remark="$expire_at ${remark:-}"
        expire_at=""
    fi
    runtime_ready || { send_message "$chat_id" "⚠️ <b>运行配置未就绪</b>\n\n请先完成：<code>./deploy.sh install</code>"; return; }
    acquire_lock || { send_message "$chat_id" "⏳ <b>操作繁忙</b>\n\n另一个管理操作正在进行。"; return; }
    local uuid rc backup_dir
    uuid="$(vxd_generate_uuid)"
    backup_dir="$(vxd_backup_state "add-$tag")"
    if vxd_user_add "$tag" "$uuid" "$expire_at" "$remark"; then
        if with_render_restart "add-$tag" "$backup_dir"; then
            rc=0
        else
            rc=1
        fi
    else
        rc=$?
    fi
    release_lock
    if [[ $rc -eq 0 ]]; then
        vxd_audit "$from_id" "add" "$tag" "ok"
        local tls_link reality_link
        tls_link="$(vxd_vless_link "$uuid" "${tag}-TLS" tls)"
        reality_link="$(vxd_vless_link "$uuid" "${tag}-REALITY" reality)"
        send_message "$chat_id" "✅ <b>用户已新增</b>\n\n👤 Tag：<code>$(html_escape "$tag")</code>\n🆔 UUID：<code>$(html_escape "$uuid")</code>\n⏳ 过期：<code>$(html_escape "${expire_at:-never}")</code>\n🔄 xray：已重启\n\n🔗 <b>TLS Vision</b>\n<code>$(html_escape "$tls_link")</code>\n\n🔗 <b>REALITY Vision</b>\n<code>$(html_escape "$reality_link")</code>\n\n📦 <b>导出</b>\n<code>/config $(html_escape "$tag") all clash plain</code>\n<code>/config $(html_escape "$tag") all shadowrocket plain</code>\n<code>/config $(html_escape "$tag") reality clash enc</code>"
    else
        vxd_audit "$from_id" "add" "$tag" "failed:$rc"
        send_message "$chat_id" "❌ <b>新增用户失败</b>\n\n可能原因：用户已存在，或 xray 重启失败并已回滚。"
    fi
}

do_delete() {
    local chat_id="$1" from_id="$2" ident="$3"
    runtime_ready || { send_message "$chat_id" "⚠️ 运行配置未就绪。"; return; }
    acquire_lock || { send_message "$chat_id" "⏳ 操作繁忙，请稍后重试。"; return; }
    local user tag count rc=0 backup_dir
    user="$(vxd_user_find "$ident")"
    if [[ -z "$user" ]]; then
        release_lock
        send_message "$chat_id" "🔎 <b>未找到用户</b>\n\n查询：<code>$(html_escape "$ident")</code>"
        return
    fi
    count="$(vxd_user_count)"
    if [[ "$count" -le 1 ]]; then
        release_lock
        send_message "$chat_id" "🛡️ <b>已取消删除</b>\n\n至少需要保留一个用户。"
        return
    fi
    tag="$(jq -r '.tag' <<< "$user")"
    backup_dir="$(vxd_backup_state "delete-$tag")"
    vxd_user_delete "$tag" || rc=$?
    if [[ $rc -eq 0 ]]; then
        with_render_restart "delete-$tag" "$backup_dir" || rc=1
    fi
    release_lock
    if [[ $rc -eq 0 ]]; then
        vxd_audit "$from_id" "delete" "$tag" "ok"
        send_message "$chat_id" "🗑️ <b>用户已删除</b>\n\n👤 Tag：<code>$(html_escape "$tag")</code>\n🔄 xray：已重启"
    else
        vxd_audit "$from_id" "delete" "$ident" "failed:$rc"
        send_message "$chat_id" "❌ <b>删除失败</b>\n\n配置已尝试回滚，请检查日志。"
    fi
}

cmd_del() {
    local chat_id="$1" from_id="$2" ident="$3"
    [[ -n "$ident" ]] || { send_message "$chat_id" "⚠️ 用法：<code>/del &lt;tag|uuid&gt;</code>"; return; }
    request_confirm "$chat_id" "$from_id" "delete" "$ident"
}

do_toggle() {
    local chat_id="$1" from_id="$2" ident="$3" enabled="$4"
    runtime_ready || { send_message "$chat_id" "⚠️ 运行配置未就绪。"; return; }
    acquire_lock || { send_message "$chat_id" "⏳ 操作繁忙，请稍后重试。"; return; }
    local user tag rc=0 action backup_dir
    user="$(vxd_user_find "$ident")"
    if [[ -z "$user" ]]; then
        release_lock
        send_message "$chat_id" "🔎 <b>未找到用户</b>\n\n查询：<code>$(html_escape "$ident")</code>"
        return
    fi
    tag="$(jq -r '.tag' <<< "$user")"
    [[ "$enabled" == "true" ]] && action="enable" || action="disable"
    backup_dir="$(vxd_backup_state "$action-$tag")"
    vxd_user_set_enabled "$tag" "$enabled" || rc=$?
    if [[ $rc -eq 0 ]]; then
        with_render_restart "$action-$tag" "$backup_dir" || rc=1
    fi
    release_lock
    if [[ $rc -eq 0 ]]; then
        vxd_audit "$from_id" "$action" "$tag" "ok"
        send_message "$chat_id" "✅ <b>用户状态已更新</b>\n\n👤 Tag：<code>$(html_escape "$tag")</code>\n状态：<code>$([[ "$enabled" == "true" ]] && echo enabled || echo disabled)</code>\n🔄 xray：已重启"
    else
        vxd_audit "$from_id" "$action" "$ident" "failed:$rc"
        send_message "$chat_id" "❌ <b>状态更新失败</b>"
    fi
}

cmd_enable() { do_toggle "$1" "$2" "$3" true; }
cmd_disable() {
    local chat_id="$1" from_id="$2" ident="$3"
    [[ -n "$ident" ]] || { send_message "$chat_id" "⚠️ 用法：<code>/disable &lt;tag|uuid&gt;</code>"; return; }
    request_confirm "$chat_id" "$from_id" "disable" "$ident"
}

cmd_expire() {
    local chat_id="$1" from_id="$2" ident="$3" expire_at="$4"
    [[ -n "$ident" && -n "$expire_at" ]] || { send_message "$chat_id" "⚠️ 用法：<code>/expire &lt;tag|uuid&gt; YYYY-MM-DD|never</code>"; return; }
    [[ "$expire_at" == "never" ]] && expire_at=""
    if [[ -n "$expire_at" && ! "$expire_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        send_message "$chat_id" "⚠️ 日期格式应为：<code>YYYY-MM-DD</code> 或 <code>never</code>"
        return
    fi
    runtime_ready || { send_message "$chat_id" "⚠️ 运行配置未就绪。"; return; }
    acquire_lock || { send_message "$chat_id" "⏳ 操作繁忙，请稍后重试。"; return; }
    local user tag rc=0 backup_dir
    user="$(vxd_user_find "$ident")"
    if [[ -z "$user" ]]; then release_lock; send_message "$chat_id" "🔎 未找到用户：<code>$(html_escape "$ident")</code>"; return; fi
    tag="$(jq -r '.tag' <<< "$user")"
    backup_dir="$(vxd_backup_state "expire-$tag")"
    vxd_user_set_expire "$tag" "$expire_at" || rc=$?
    if [[ $rc -eq 0 ]]; then with_render_restart "expire-$tag" "$backup_dir" || rc=1; fi
    release_lock
    if [[ $rc -eq 0 ]]; then
        vxd_audit "$from_id" "expire" "$tag" "ok"
        send_message "$chat_id" "⏳ <b>过期时间已更新</b>\n\n👤 Tag：<code>$(html_escape "$tag")</code>\n过期：<code>$(html_escape "${expire_at:-never}")</code>\n🔄 xray：已重启"
    else
        vxd_audit "$from_id" "expire" "$ident" "failed:$rc"
        send_message "$chat_id" "❌ <b>过期时间更新失败</b>"
    fi
}

cmd_remark() {
    local chat_id="$1" from_id="$2" ident="$3" remark="$4"
    [[ -n "$ident" ]] || { send_message "$chat_id" "⚠️ 用法：<code>/remark &lt;tag|uuid&gt; text</code>"; return; }
    local user tag
    user="$(vxd_user_find "$ident")"
    [[ -n "$user" ]] || { send_message "$chat_id" "🔎 未找到用户：<code>$(html_escape "$ident")</code>"; return; }
    tag="$(jq -r '.tag' <<< "$user")"
    vxd_user_set_remark "$tag" "$remark"
    vxd_audit "$from_id" "remark" "$tag" "ok"
    send_message "$chat_id" "📝 <b>备注已更新</b>\n\n👤 Tag：<code>$(html_escape "$tag")</code>\n备注：$(html_escape "$remark")"
}

cmd_link() {
    local chat_id="$1" ident="$2" protocol="${3:-all}"
    [[ -n "$ident" ]] || { send_message "$chat_id" "⚠️ 用法：<code>/link &lt;tag|uuid&gt; [tls|reality|all]</code>"; return; }
    case "$protocol" in tls|reality|all) ;; *) send_message "$chat_id" "⚠️ 协议仅支持：<code>tls</code>、<code>reality</code>、<code>all</code>"; return ;; esac
    runtime_ready || { send_message "$chat_id" "⚠️ 运行配置未就绪。"; return; }
    local user uuid tag
    user="$(vxd_user_find "$ident")"
    [[ -n "$user" ]] || { send_message "$chat_id" "🔎 未找到用户：<code>$(html_escape "$ident")</code>"; return; }
    uuid="$(jq -r '.uuid' <<< "$user")"
    tag="$(jq -r '.tag' <<< "$user")"
    local body=""
    if [[ "$protocol" == "tls" || "$protocol" == "all" ]]; then
        body+="🔗 <b>TLS Vision</b>\n<code>$(html_escape "$(vxd_vless_link "$uuid" "${tag}-TLS" tls)")</code>\n\n"
    fi
    if [[ "$protocol" == "reality" || "$protocol" == "all" ]]; then
        body+="🔗 <b>REALITY Vision</b>\n<code>$(html_escape "$(vxd_vless_link "$uuid" "${tag}-REALITY" reality)")</code>\n\n"
    fi
    send_message "$chat_id" "🔗 <b>VLESS 分享链接</b>\n\n👤 Tag：<code>$(html_escape "$tag")</code>\n\n$body"
}

bot_config_has_placeholders() {
    local file="$1"
    [[ -f "$file" ]] && grep -Eq '\{\{[A-Z_][A-Z0-9_]*\}\}' "$file"
}

bot_parse_env_value() {
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

bot_load_main_env_direct() {
    local file="$INSTALL_DIR/.env"
    [[ -f "$file" ]] || return 1
    local key value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        key="${key%$'\r'}"
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        value="$(bot_parse_env_value "$value")"
        case "$key" in
            DOMAIN|REALITY_SERVER_NAME|REALITY_PUBLIC_KEY|REALITY_SHORT_ID|CLASH_PROXY_NAME_PREFIX|CLASH_ALLOW_LAN|CLASH_MODE)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$file"
}

bot_yaml_quote() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

bot_render_clash_config_fallback() {
    local user_json="$1" out_file="$2" protocol="${3:-all}"
    case "$protocol" in tls|reality|all) ;; *) return 2 ;; esac
    bot_load_main_env_direct || true
    [[ -n "${DOMAIN:-}" ]] || return 1

    local uuid tag prefix base_name tls_name reality_name allow_lan mode
    local q_tls_name q_reality_name q_domain q_uuid q_reality_server q_reality_public q_reality_short
    local proxies_yaml proxy_names_yaml template line clean_line

    uuid="$(jq -r '.uuid // .id' <<< "$user_json")"
    tag="$(jq -r '.tag // (.email | split("@")[0])' <<< "$user_json")"
    prefix="${CLASH_PROXY_NAME_PREFIX:-}"
    if [[ -n "$prefix" ]]; then
        base_name="${prefix}-${tag}"
    else
        base_name="${tag}-VLESS"
    fi
    tls_name="$base_name"
    [[ "$protocol" == "all" ]] && tls_name="${base_name}-TLS"
    reality_name="${base_name}-REALITY"
    allow_lan="${CLASH_ALLOW_LAN:-true}"
    mode="${CLASH_MODE:-rule}"

    q_tls_name="$(bot_yaml_quote "$tls_name")"
    q_reality_name="$(bot_yaml_quote "$reality_name")"
    q_domain="$(bot_yaml_quote "$DOMAIN")"
    q_uuid="$(bot_yaml_quote "$uuid")"
    q_reality_server="$(bot_yaml_quote "${REALITY_SERVER_NAME:-www.microsoft.com}")"
    q_reality_public="$(bot_yaml_quote "${REALITY_PUBLIC_KEY:-}")"
    q_reality_short="$(bot_yaml_quote "${REALITY_SHORT_ID:-}")"

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
        [[ -n "${REALITY_PUBLIC_KEY:-}" && -n "${REALITY_SHORT_ID:-}" ]] || return 1
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

    template="$INSTALL_DIR/clash_config.yaml.template"
    if [[ -f "$template" ]]; then
        : > "$out_file"
        while IFS= read -r line || [[ -n "$line" ]]; do
            clean_line="${line%$'\r'}"
            case "$clean_line" in
                "{{PROXIES}}") printf '%s\n' "$proxies_yaml" >> "$out_file" ;;
                "{{PROXY_NAMES}}") printf '%s\n' "$proxy_names_yaml" >> "$out_file" ;;
                allow-lan:*) printf 'allow-lan: %s\n' "$allow_lan" >> "$out_file" ;;
                mode:*) printf 'mode: %s\n' "$mode" >> "$out_file" ;;
                *) printf '%s\n' "$clean_line" >> "$out_file" ;;
            esac
        done < "$template"
    fi

    if [[ ! -s "$out_file" ]] || bot_config_has_placeholders "$out_file"; then
        cat > "$out_file" << EOF
# Generated for Mihomo / Clash.Meta compatible clients.
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

    [[ -s "$out_file" ]] && ! bot_config_has_placeholders "$out_file"
}

bot_normalize_export_format() {
    case "${1,,}" in
        clash|mihomo|meta|clashmeta|clash-meta|yaml|yml)
            printf 'clash'
            ;;
        shadowrocket|rocket|sr|node|nodes|link|links|uri|uris|txt)
            printf 'shadowrocket'
            ;;
        *)
            return 1
            ;;
    esac
}

bot_render_shadowrocket_nodes() {
    local user_json="$1" out_file="$2" protocol="${3:-all}"
    case "$protocol" in tls|reality|all) ;; *) return 2 ;; esac
    vxd_load_main_config || bot_load_main_env_direct || return 1

    local uuid tag
    uuid="$(jq -r '.uuid // .id' <<< "$user_json")"
    tag="$(jq -r '.tag // (.email | split("@")[0])' <<< "$user_json")"
    [[ -n "$uuid" && "$uuid" != "null" ]] || return 1
    [[ -n "${DOMAIN:-}" ]] || return 1

    : > "$out_file"
    if [[ "$protocol" == "tls" || "$protocol" == "all" ]]; then
        printf '%s\n' "$(vxd_vless_link "$uuid" "${tag}-TLS" tls)" >> "$out_file"
    fi
    if [[ "$protocol" == "reality" || "$protocol" == "all" ]]; then
        [[ -n "${REALITY_PUBLIC_KEY:-}" && -n "${REALITY_SHORT_ID:-}" ]] || return 1
        printf '%s\n' "$(vxd_vless_link "$uuid" "${tag}-REALITY" reality)" >> "$out_file"
    fi
    [[ -s "$out_file" ]]
}

cmd_config() {
    local chat_id="$1" ident="$2" opt1="${3:-}" opt2="${4:-}" rest="${5:-}"
    local protocol="all" mode="${TELEGRAM_CONFIG_MODE:-plain}" export_format="clash" password="" fmt token raw_token
    [[ -n "$ident" ]] || { send_message "$chat_id" "⚠️ 用法：<code>/config &lt;tag|uuid&gt; [tls|reality|all] [clash|shadowrocket] [plain|tgz|enc] [password]</code>"; return; }

    local tokens=()
    [[ -n "$opt1" ]] && tokens+=("$opt1")
    [[ -n "$opt2" ]] && tokens+=("$opt2")
    if [[ -n "$rest" ]]; then
        read -r -a rest_tokens <<< "$rest"
        tokens+=("${rest_tokens[@]}")
    fi
    local password_tokens=()
    for raw_token in "${tokens[@]}"; do
        token="${raw_token,,}"
        case "$token" in
            tls|reality|all)
                protocol="$token"
                ;;
            plain|tgz|enc)
                mode="$token"
                ;;
            *)
                if fmt="$(bot_normalize_export_format "$token" 2>/dev/null)"; then
                    export_format="$fmt"
                elif [[ "$mode" == "enc" ]]; then
                    password_tokens+=("$raw_token")
                else
                    send_message "$chat_id" "⚠️ 用法：<code>/config &lt;tag|uuid&gt; [tls|reality|all] [clash|shadowrocket] [plain|tgz|enc] [password]</code>"
                    return
                fi
                ;;
        esac
    done
    if [[ ${#password_tokens[@]} -gt 0 ]]; then
        password="${password_tokens[*]}"
    fi
    case "$mode" in plain|tgz|enc) ;; *) send_message "$chat_id" "⚠️ 打包方式仅支持：<code>plain</code>、<code>tgz</code>、<code>enc</code>"; return ;; esac
    runtime_ready || { send_message "$chat_id" "⚠️ 运行配置未就绪。"; return; }
    local user tag workdir config_file archive enc passfile export_label ext
    user="$(vxd_user_find "$ident")"
    [[ -n "$user" ]] || { send_message "$chat_id" "🔎 未找到用户：<code>$(html_escape "$ident")</code>"; return; }
    tag="$(jq -r '.tag' <<< "$user")"
    workdir="$(mktemp -d "$TMP_ROOT/${tag}.XXXXXX")"

    case "$export_format" in
        clash)
            ext="clash.yaml"
            export_label="Mihomo/Clash.Meta 完整配置"
            config_file="$workdir/${tag}.${protocol}.${ext}"
            if ! vxd_make_clash_config "$user" "$config_file" "$protocol" || bot_config_has_placeholders "$config_file"; then
                log "Primary Clash generator failed or stale; using Telegram fallback generator for $tag/$protocol"
                bot_render_clash_config_fallback "$user" "$config_file" "$protocol" || true
            fi
            ;;
        shadowrocket)
            ext="shadowrocket.txt"
            export_label="Shadowrocket 纯节点"
            config_file="$workdir/${tag}.${protocol}.${ext}"
            bot_render_shadowrocket_nodes "$user" "$config_file" "$protocol" || true
            ;;
    esac

    if [[ ! -s "$config_file" ]] || bot_config_has_placeholders "$config_file"; then
        rm -rf "$workdir"
        send_message "$chat_id" "❌ <b>配置生成失败</b>\n\n请检查服务端 <code>.env</code> 中 DOMAIN / REALITY_PUBLIC_KEY / REALITY_SHORT_ID 是否完整。"
        return
    fi
    case "$mode" in
        plain)
            send_document "$chat_id" "$config_file" "✅ ${export_label}：$tag / $protocol"
            ;;
        tgz)
            archive="$workdir/${tag}.${protocol}.${export_format}.tar.gz"
            tar -czf "$archive" -C "$workdir" "$(basename "$config_file")"
            send_document "$chat_id" "$archive" "📦 ${export_label}压缩包：$tag / $protocol"
            ;;
        enc)
            archive="$workdir/${tag}.${protocol}.${export_format}.tar.gz"
            enc="$archive.enc"
            passfile="$workdir/password.txt"
            [[ -n "$password" ]] || password="$(openssl rand -base64 18 | tr -d '\n')"
            printf '%s' "$password" > "$passfile"
            chmod 600 "$passfile"
            tar -czf "$archive" -C "$workdir" "$(basename "$config_file")"
            openssl enc -aes-256-cbc -pbkdf2 -salt -in "$archive" -out "$enc" -pass "file:$passfile"
            send_document "$chat_id" "$enc" "🔐 ${export_label}加密压缩包：$tag / $protocol"
            send_message "$chat_id" "🔐 <b>加密配置已生成</b>\n\n👤 Tag：<code>$(html_escape "$tag")</code>\n类型：<code>$(html_escape "$export_label")</code>\n🔑 解密密码：<code>$(html_escape "$password")</code>\n\n<b>解密示例</b>\n<code>openssl enc -d -aes-256-cbc -pbkdf2 -in $(html_escape "$(basename "$enc")") -out $(html_escape "${tag}.${export_format}.tar.gz")</code>"
            ;;
    esac
    rm -rf "$workdir"
}

cmd_traffic() {
    local chat_id="$1" ident="${2:-}"
    runtime_ready || { send_message "$chat_id" "⚠️ 运行配置未就绪。"; return; }
    local sync_warning=""
    if ! vxd_update_traffic_usage; then
        sync_warning="⚠️ 本次实时同步失败，以下为上次保存的数据。\n\n"
    fi
    local filter="" user body="" tag used limit percent status updated limit_text count=0
    if [[ -n "$ident" ]]; then
        user="$(vxd_user_find "$ident")"
        [[ -n "$user" ]] || { send_message "$chat_id" "🔎 未找到用户：<code>$(html_escape "$ident")</code>"; return; }
        filter="$(jq -r '.tag' <<< "$user")"
    fi

    while IFS=$'\t' read -r tag used limit percent status updated; do
        [[ -n "$tag" ]] || continue
        [[ -z "$filter" || "$filter" == "$tag" ]] || continue
        if [[ "$limit" == "0" ]]; then
            limit_text="unlimited"
        else
            limit_text="$(vxd_format_bytes "$limit")"
        fi
        body+="👤 <b>$(html_escape "$tag")</b>
   用量：<code>$(html_escape "$(vxd_format_bytes "$used")") / $(html_escape "$limit_text")</code>
   进度：<code>$(html_escape "$percent")</code>｜状态：<code>$(html_escape "$status")</code>
   更新：<code>$(html_escape "${updated:-never}")</code>

"
        count=$((count + 1))
    done < <(vxd_traffic_table)

    if [[ $count -eq 0 ]]; then
        send_message "$chat_id" "${sync_warning}📈 <b>流量统计</b>

暂无数据。"
    else
        send_message "$chat_id" "${sync_warning}📈 <b>流量统计</b>｜共 <code>$count</code> 个

$body"
    fi
}

cmd_userlog() {
    local chat_id="$1" tag="$2" mode="${3:-80}"
    [[ -n "$tag" ]] || { send_message "$chat_id" "⚠️ 用法：<code>/userlog &lt;tag&gt; [lines|file]</code>"; return; }
    if ! vxd_validate_user_tag "$tag"; then
        send_message "$chat_id" "⚠️ Tag 格式不正确。"
        return
    fi
    local file="$VXD_USER_LOG_DIR/${tag}.log"
    if [[ ! -f "$file" ]]; then
        send_message "$chat_id" "🪵 <b>暂无该用户日志</b>

文件：<code>$(html_escape "$file")</code>"
        return
    fi
    if [[ "$mode" == "file" ]]; then
        send_document "$chat_id" "$file" "🪵 用户日志：$tag"
        return
    fi
    local lines="$mode"
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=80
    (( lines > 200 )) && lines=200
    local content
    content="$(tail -n "$lines" "$file" 2>/dev/null || true)"
    [[ -n "$content" ]] || content="(empty)"
    if (( ${#content} > 3200 )); then
        content="... (truncated) ...
${content: -3200}"
    fi
    send_message "$chat_id" "🪵 <b>用户日志</b>｜<code>$(html_escape "$tag")</code>｜最后 <code>$lines</code> 行

<pre>$(html_escape "$content")</pre>"
}

cmd_status() {
    local chat_id="$1"
    load_all_config || { send_message "$chat_id" "⚠️ 配置未就绪。"; return; }
    local cert_days users active bot_state traffic_state logsplit_state compose_output
    cert_days="$(vxd_cert_days_left 2>/dev/null || echo missing)"
    users="$(jq -r '.users | length' "$VXD_USERS_DB" 2>/dev/null || echo 0)"
    active="$(vxd_active_clients_json 2>/dev/null | jq -r 'length' 2>/dev/null || echo 0)"
    bot_state="$(systemctl is-active vless-telegram-bot 2>/dev/null || echo unknown)"
    traffic_state="$(systemctl is-active vless-traffic-manager.timer 2>/dev/null || echo unknown)"
    logsplit_state="$(systemctl is-active vless-user-log-splitter 2>/dev/null || echo unknown)"
    cd "$INSTALL_DIR" || return
    compose_output="$(vxd_docker_compose ps 2>&1 | tail -n 12)"
    send_message "$chat_id" "📊 <b>服务状态</b>

🌐 域名：<code>$(html_escape "${DOMAIN:-unknown}")</code>
🧬 REALITY SNI：<code>$(html_escape "${REALITY_SERVER_NAME:-unknown}")</code>
🔐 证书剩余：<code>$(html_escape "$cert_days")</code> 天
👥 用户：<code>$users</code> 总 / <code>$active</code> 活跃
📈 流量统计：<code>$(html_escape "$traffic_state")</code>
🪵 用户日志：<code>$(html_escape "$logsplit_state")</code>
🤖 Bot：<code>$(html_escape "$bot_state")</code>

<pre>$(html_escape "$compose_output")</pre>"
}

do_restart() {
    local chat_id="$1" from_id="$2"
    if restart_xray; then
        vxd_audit "$from_id" "restart" "xray" "ok"
        send_message "$chat_id" "🔄 <b>xray 已重启</b>"
    else
        vxd_audit "$from_id" "restart" "xray" "failed"
        send_message "$chat_id" "❌ <b>xray 重启失败</b>\n\n请检查 Docker 日志。"
    fi
}

cmd_restart() { request_confirm "$1" "$2" "restart" "xray"; }

trim_leading_space() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    printf '%s' "$value"
}

handle_text() {
    local chat_id="$1" from_id="$2" text="$3"
    local raw_cmd cmd args arg1 arg2 arg3 rest
    raw_cmd="${text%%[[:space:]]*}"
    cmd="${raw_cmd#/}"
    cmd="${cmd%@*}"
    cmd="${cmd,,}"
    args="$(trim_leading_space "${text#"$raw_cmd"}")"

    if [[ "$cmd" == "id" ]]; then
        send_message "$chat_id" "🪪 <b>Telegram ID</b>\n\nchat_id：<code>$(html_escape "$chat_id")</code>\nuser_id：<code>$(html_escape "$from_id")</code>"
        return
    fi

    if ! is_authorized "$from_id"; then
        send_message "$chat_id" "🚫 <b>未授权</b>\n\n请把此 user_id 加入 <code>TELEGRAM_ADMIN_IDS</code>：\n<code>$(html_escape "$from_id")</code>"
        vxd_audit "$from_id" "unauthorized" "$cmd" "blocked"
        return
    fi

    read -r arg1 arg2 arg3 rest <<< "$args"
    case "$cmd" in
        start|help) cmd_help "$chat_id" ;;
        users) cmd_users "$chat_id" ;;
        add) cmd_add "$chat_id" "$from_id" "${arg1:-}" "${arg2:-}" "${arg3:-}${rest:+ $rest}" ;;
        del|delete) cmd_del "$chat_id" "$from_id" "${arg1:-}" ;;
        enable) cmd_enable "$chat_id" "$from_id" "${arg1:-}" ;;
        disable) cmd_disable "$chat_id" "$from_id" "${arg1:-}" ;;
        expire) cmd_expire "$chat_id" "$from_id" "${arg1:-}" "${arg2:-}" ;;
        remark) cmd_remark "$chat_id" "$from_id" "${arg1:-}" "${arg2:-}${arg3:+ $arg3}${rest:+ $rest}" ;;
        link) cmd_link "$chat_id" "${arg1:-}" "${arg2:-all}" ;;
        config) cmd_config "$chat_id" "${arg1:-}" "${arg2:-}" "${arg3:-}" "${rest:-}" ;;
        traffic) cmd_traffic "$chat_id" "${arg1:-}" ;;
        userlog|ulog) cmd_userlog "$chat_id" "${arg1:-}" "${arg2:-80}" ;;
        status) cmd_status "$chat_id" ;;
        restart) cmd_restart "$chat_id" "$from_id" ;;
        confirm) cmd_confirm "$chat_id" "$from_id" "${arg1:-}" ;;
        cancel) cmd_cancel "$chat_id" "${arg1:-}" ;;
        *) send_message "$chat_id" "❓ <b>未知命令</b>\n\n命令：<code>/$(html_escape "$cmd")</code>\n发送 <code>/help</code> 查看帮助。" ;;
    esac
}

poll_loop() {
    local offset=0 updates update update_id chat_id from_id text
    log "Telegram bot started"
    while true; do
        load_all_config || { log "Config missing, retrying..."; sleep 5; continue; }
        updates="$(telegram_api getUpdates --get --data-urlencode "offset=$offset" --data-urlencode "timeout=30" 2>/tmp/vless-telegram-bot-api.log)" || {
            log "getUpdates failed: $(cat /tmp/vless-telegram-bot-api.log 2>/dev/null)"
            sleep 5
            continue
        }
        while IFS= read -r update; do
            update_id="$(jq -r '.update_id' <<< "$update")"
            offset=$((update_id + 1))
            chat_id="$(jq -r '.message.chat.id // .edited_message.chat.id // empty' <<< "$update")"
            from_id="$(jq -r '.message.from.id // .edited_message.from.id // empty' <<< "$update")"
            text="$(jq -r '.message.text // .edited_message.text // empty' <<< "$update")"
            [[ -n "$chat_id" && -n "$from_id" && -n "$text" ]] || continue
            [[ "$text" == /* ]] || continue
            handle_text "$chat_id" "$from_id" "$text" || log "Command failed: $text"
        done < <(jq -c '.result[]?' <<< "$updates")
    done
}

main() {
    load_all_config || fatal "Config not found: $VXD_CONFIG_FILE"
    require_tools
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || fatal "TELEGRAM_BOT_TOKEN missing in $VXD_TELEGRAM_CONFIG_FILE"
    [[ -n "${TELEGRAM_ADMIN_IDS:-}" ]] || log "WARNING: TELEGRAM_ADMIN_IDS missing; only /id will be usable."
    mkdir -p "$TMP_ROOT"
    chmod 700 "$TMP_ROOT"
    vxd_ensure_dirs
    poll_loop
}

main "$@"
