#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OptimAI CLI All in One - Tuangg
# Version: 1.1.8
#
# Updates:
# v1.1.8:
# - Fix watchdog: bỏ set -euo pipefail tránh exit bất ngờ khi check/restart
# - Fix node_running(): strip ANSI codes, trim whitespace trước khi grep
# - Tăng verify sleep 3->8s + retry 3 lần khi check node status sau restart
# - Fix append_restart_log: chỉ tăng count khi restart thực sự thất bại
# - Fix restart_node(): không dùng `if !` với set -e, dùng biến exit code
# v1.1.7:
# - Fix start node in tmux: dùng đúng câu lệnh đã test OK:
#     tmux new-session -d -s o "bash -lc '/usr/local/bin/optimai-cli node start'"
# - Watchdog check node live theo: optimai-cli node status (Node running / Node not running)
# - Watchdog restart cũng start node bằng bash -lc + verify lại status
#
# Dev info:
# - Link tải CLI mới nhất: https://cli-node.optimai.network/optimai_cli_ubuntu
# - Login: optimai-cli auth login --legacy
# ============================================================

PROMO_TEXT=$'\n✨ Ae dùng script thấy ok thì follow mình để update bản mới nhé 👉 https://x.com/tuangg\n'

TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"
CLI_URL="https://cli-node.optimai.network/optimai_cli_ubuntu"

WATCHDOG_SCRIPT="/usr/local/bin/optimai-watchdog"
WATCHDOG_SERVICE="optimai-watchdog.service"

TELEGRAM_CONFIG="/etc/optimai/telegram.conf"
SERVER_INFO=""

ARG_BOT_TOKEN=""
ARG_CHAT_ID=""

banner() {
  clear
  echo "============================================================"
  echo "        OptimAI CLI All in One - Tuangg (v1.1.8)"
  echo "============================================================"
  echo
}

must_be_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[!] Vui lòng chạy script bằng root (sudo)."
    exit 1
  fi
}

parse_deploy_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bot-token=*)
        ARG_BOT_TOKEN="${1#*=}"
        shift
        ;;
      --bot-token)
        ARG_BOT_TOKEN="${2:-}"
        shift 2
        ;;
      --chat-id=*)
        ARG_CHAT_ID="${1#*=}"
        shift
        ;;
      --chat-id)
        ARG_CHAT_ID="${2:-}"
        shift 2
        ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  sudo ./optimai.sh [--bot-token=TOKEN] [--chat-id=CHAT_ID]

Examples:
  sudo ./optimai.sh --bot-token=123:ABC --chat-id=987654321
  sudo ./optimai.sh --bot-token 123:ABC --chat-id 987654321
USAGE
        exit 0
        ;;
      *)
        shift
        ;;
    esac
  done
}

send_telegram() {
  local message="$1"

  if [[ -f "$TELEGRAM_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$TELEGRAM_CONFIG" 2>/dev/null || true
  fi

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    return 0
  fi

  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="$message" \
    -d parse_mode="HTML" \
    -d disable_web_page_preview=true >/dev/null 2>&1 || true
}

get_server_info() {
  local hostname ip
  hostname=$(hostname 2>/dev/null || echo "Unknown")
  ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "Unknown")
  echo "Server: <b>$hostname</b>%0AIP: <code>$ip</code>"
}

load_telegram_config() {
  SERVER_INFO="$(get_server_info)"
}

apply_telegram_args_if_provided() {
  if [[ -n "$ARG_BOT_TOKEN" && -n "$ARG_CHAT_ID" ]]; then
    mkdir -p /etc/optimai
    cat <<EOF > "$TELEGRAM_CONFIG"
TELEGRAM_BOT_TOKEN="$ARG_BOT_TOKEN"
TELEGRAM_CHAT_ID="$ARG_CHAT_ID"
EOF
    chmod 600 "$TELEGRAM_CONFIG"
  fi
}

install_tmux_if_needed() {
  if command -v tmux >/dev/null 2>&1; then
    return 0
  fi
  echo "[*] tmux chưa cài. Đang cài..."
  apt-get update -y
  apt-get install -y tmux
  echo "[✓] tmux đã cài."
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  echo "[*] Docker chưa cài. Đang cài..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  echo "[✓] Docker đã cài."
}

prefetch_crawler_image() {
  if command -v docker >/dev/null 2>&1; then
    echo "[*] Prefetch image crawl4ai..."
    docker pull unclecode/crawl4ai:0.7.3 >/dev/null 2>&1 || true
  fi
}

download_cli_to_tmp() {
  local tmp="$1"
  echo "[*] Đang tải optimai-cli mới nhất từ: $CLI_URL"
  curl -fL --retry 5 --retry-delay 2 --connect-timeout 10 "$CLI_URL" -o "$tmp"
}

ensure_cli() {
  if [[ -x "$CLI_PATH" ]]; then
    return 0
  fi

  echo "[*] optimai-cli chưa có. Đang tải..."
  local tmp="/tmp/optimai-cli.$RANDOM.$RANDOM"

  if ! download_cli_to_tmp "$tmp"; then
    echo "[!] Tải optimai-cli thất bại."
    rm -f "$tmp" >/dev/null 2>&1 || true
    exit 1
  fi

  install -m 0755 "$tmp" "$CLI_PATH"
  rm -f "$tmp" >/dev/null 2>&1 || true

  if "$CLI_PATH" --help >/dev/null 2>&1; then
    echo "[✓] Đã cài optimai-cli: $CLI_PATH"
    return 0
  fi

  echo "[!] optimai-cli không chạy được sau khi tải. Có thể sai arch hoặc thiếu thư viện."
  exit 1
}

reinstall_cli() {
  echo "=== (10) Reinstall optimai-cli (xóa + tải lại bản mới) ==="

  # stop node trong tmux để tránh đang dùng binary
  if command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      echo "[*] Node đang chạy trong tmux '$TMUX_SESSION' -> stop session..."
      tmux kill-session -t "$TMUX_SESSION" || true
      echo "[✓] Đã stop tmux session '$TMUX_SESSION'."
    fi
  fi

  # backup bản cũ
  if [[ -f "$CLI_PATH" ]]; then
    local backup="${CLI_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    echo "[*] Backup optimai-cli cũ -> $backup"
    mv -f "$CLI_PATH" "$backup"
  fi

  local tmp="/tmp/optimai-cli.$RANDOM.$RANDOM"
  if ! download_cli_to_tmp "$tmp"; then
    echo "[!] Tải thất bại. Kiểm tra mạng/DNS/Firewall."
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 1
  fi

  install -m 0755 "$tmp" "$CLI_PATH"
  rm -f "$tmp" >/dev/null 2>&1 || true

  if "$CLI_PATH" --help >/dev/null 2>&1; then
    echo "[✓] Reinstall OK: $CLI_PATH"
    send_telegram "<b>✅ Reinstall optimai-cli OK</b>%0A$SERVER_INFO%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    return 0
  else
    echo "[!] Reinstall xong nhưng optimai-cli không chạy được."
    return 1
  fi
}

# ===== FIX START NODE (v1.1.7) =====
start_node_in_tmux() {
  install_tmux_if_needed

  # nếu session tồn tại -> kill để start lại cho sạch
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[*] tmux session '$TMUX_SESSION' đã tồn tại -> kill để start lại."
    tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
  fi

  echo "[*] Đang start node trong tmux session '$TMUX_SESSION'..."
  # Dùng đúng câu lệnh bạn xác nhận OK
  tmux new-session -d -s "$TMUX_SESSION" "bash -lc '$CLI_PATH node start'"

  # verify nhanh
  sleep 3
  local st
  st="$("$CLI_PATH" node status 2>&1 || true)"

  if echo "$st" | grep -qiE '^Node running'; then
    echo "[✓] Node đã chạy OK: $st"
    echo "    Xem log: tmux attach -t $TMUX_SESSION"
    return 0
  fi

  echo "[!] Start xong nhưng node chưa chạy."
  echo "    Status: $st"
  echo
  echo "[*] 50 dòng log tmux gần nhất:"
  tmux capture-pane -t "${TMUX_SESSION}:0.0" -p -S -50 2>/dev/null || true
  echo
  echo "[*] Thử xem trực tiếp:"
  echo "    tmux attach -t $TMUX_SESSION"
  return 1
}

view_logs_menu() {
  echo
  echo "=== (2) Xem log node ==="
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux attach -t "$TMUX_SESSION"
  else
    echo "[!] Không thấy tmux session '$TMUX_SESSION'. Node có thể đang tắt."
  fi
  echo
}

create_watchdog_script() {
  cat <<'EOF' > "$WATCHDOG_SCRIPT"
#!/usr/bin/env bash
# KHÔNG dùng set -euo pipefail ở đây để tránh exit bất ngờ khi check status
# Mỗi lệnh quan trọng sẽ được xử lý lỗi thủ công

TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"

RESTART_LOG="/tmp/optimai-restarts.log"
BLOCK_STATE="/tmp/optimai-blocked.state"
MARKER="/tmp/optimai-block-notified.marker"
ERR_LOG="/tmp/optimai-watchdog.err"

TELEGRAM_CONFIG="/etc/optimai/telegram.conf"

MAX_RESTARTS=4
WINDOW=600

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*" >> "$ERR_LOG"; }

send_telegram() {
  local message="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    return 0
  fi
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="$message" \
    -d parse_mode="HTML" \
    -d disable_web_page_preview=true >/dev/null 2>&1 || true
}

get_server_info() {
  local hostname ip
  hostname=$(hostname 2>/dev/null || echo "Unknown")
  ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "Unknown")
  echo "Server: <b>$hostname</b>%0AIP: <code>$ip</code>"
}

if [[ -f "$TELEGRAM_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$TELEGRAM_CONFIG" 2>/dev/null || true
fi
SERVER_INFO="$(get_server_info)"

now_ts() { date +%s; }

count_recent_restarts() {
  local now cutoff
  now="$(now_ts)"
  cutoff=$((now - WINDOW))
  [[ -f "$RESTART_LOG" ]] || { echo 0; return; }
  awk -v c="$cutoff" '$1>=c {n++} END{print n+0}' "$RESTART_LOG" 2>/dev/null || echo 0
}

append_restart_log() {
  local now
  now="$(now_ts)"
  echo "$now restart" >> "$RESTART_LOG"
}

is_blocked() {
  [[ -f "$BLOCK_STATE" ]] || return 1
  local until now
  until="$(cat "$BLOCK_STATE" 2>/dev/null || echo 0)"
  now="$(now_ts)"
  if [[ "$now" -lt "$until" ]]; then
    return 0
  fi
  rm -f "$BLOCK_STATE" >/dev/null 2>&1 || true
  return 1
}

set_blocked() {
  local now
  now="$(now_ts)"
  echo $((now + WINDOW)) > "$BLOCK_STATE"
}

notify_block_once() {
  [[ -f "$MARKER" ]] && return 0
  echo 1 > "$MARKER"
  send_telegram "<b>⛔ Watchdog BLOCK Restart</b>%0A$SERVER_INFO%0AĐã restart quá nhiều lần trong ${WINDOW}s. Tạm dừng restart để tránh loop.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
}

clear_block_marker_if_needed() {
  [[ -f "$BLOCK_STATE" ]] && return 0
  [[ -f "$MARKER" ]] && rm -f "$MARKER" >/dev/null 2>&1 || true
}

node_status_text() {
  "$CLI_PATH" node status 2>&1 || true
}

node_running() {
  local out clean
  out="$(node_status_text)"
  # Strip ANSI color codes và trim whitespace trước khi grep
  clean="$(echo "$out" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^[[:space:]]*//')"
  echo "$clean" | grep -qiE '^Node running'
}

tmux_session_exists() {
  tmux has-session -t "$TMUX_SESSION" 2>/dev/null
}

restart_node() {
  log "Restart requested..."

  # kill tmux session nếu có (kể cả zombie)
  if tmux_session_exists; then
    log "Killing tmux session '$TMUX_SESSION'"
    tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
    sleep 1
  fi

  log "Starting node in tmux '$TMUX_SESSION'..."
  # Dùng biến exit code thay vì `if !` để tương thích với môi trường không có set -e
  tmux new-session -d -s "$TMUX_SESSION" "bash -lc '$CLI_PATH node start'"
  local tmux_exit=$?

  if [[ $tmux_exit -ne 0 ]]; then
    log "ERROR: tmux new-session failed (exit $tmux_exit)"
    send_telegram "<b>❌ Watchdog restart FAIL</b>%0A$SERVER_INFO%0Atmux new-session failed (exit $tmux_exit)%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    return 1
  fi

  # Chờ lâu hơn (8s) để node có thời gian khởi động, retry 3 lần
  local retries=3
  local wait_sec=8
  local attempt=0
  local st

  while [[ $attempt -lt $retries ]]; do
    sleep "$wait_sec"
    st="$(node_status_text)"
    local clean
    clean="$(echo "$st" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^[[:space:]]*//')"
    if echo "$clean" | grep -qiE '^Node running'; then
      log "Restart OK (attempt $((attempt+1))). Status: $st"
      return 0
    fi
    attempt=$((attempt + 1))
    log "Verify attempt $attempt/$retries: node chưa running. Status: $st"
  done

  log "ERROR: Restart attempted but node still NOT running after ${retries} retries. Status: $st"
  send_telegram "<b>❌ Watchdog restart FAIL</b>%0A$SERVER_INFO%0AStatus sau restart: <code>$(echo "$st" | head -n 2 | tr '\n' ' ')</code>%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  return 1
}

main() {
  clear_block_marker_if_needed

  command -v tmux >/dev/null 2>&1 || { log "tmux not found"; exit 0; }
  [[ -x "$CLI_PATH" ]] || { log "optimai-cli missing or not executable"; exit 0; }

  if is_blocked; then
    log "BLOCKED - skip restart"
    notify_block_once
    exit 0
  fi

  if node_running; then
    log "OK - node is running"
    exit 0
  fi

  local count
  count="$(count_recent_restarts)"

  if [[ "$count" -ge "$MAX_RESTARTS" ]]; then
    set_blocked
    log "too many restarts (${count}/${MAX_RESTARTS}) -> BLOCK"
    send_telegram "<b>⛔ Watchdog BLOCK Restart</b>%0A$SERVER_INFO%0AĐạt ngưỡng restart (${count}/${MAX_RESTARTS}) trong ${WINDOW}s. Tạm dừng restart.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    exit 0
  fi

  local st
  st="$(node_status_text)"
  log "Node DOWN. Status: $st"

  # Ghi log restart TRƯỚC khi thực hiện để đúng count window
  append_restart_log

  if restart_node; then
    send_telegram "<b>⚠️ Node DOWN - Tự Restart</b>%0A$SERVER_INFO%0ARestart count (window): $((count+1))/${MAX_RESTARTS}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  fi
  # Dù restart thành công hay thất bại đều exit 0 để systemd không retry liên tục
  exit 0
}

main
EOF

  chmod +x "$WATCHDOG_SCRIPT"
}

create_systemd_unit() {
  cat <<EOF > "/etc/systemd/system/$WATCHDOG_SERVICE"
[Unit]
Description=OptimAI Watchdog (tmux session: $TMUX_SESSION)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT

[Install]
WantedBy=multi-user.target
EOF

  cat <<EOF > "/etc/systemd/system/${WATCHDOG_SERVICE}.timer"
[Unit]
Description=Run OptimAI Watchdog every 30 seconds

[Timer]
OnBootSec=30
OnUnitActiveSec=30
Unit=$WATCHDOG_SERVICE

[Install]
WantedBy=timers.target
EOF
}

start_watchdog() {
  echo "=== (5) Start Watchdog Service ==="
  create_watchdog_script
  create_systemd_unit
  systemctl daemon-reload
  systemctl enable --now "${WATCHDOG_SERVICE}.timer"
  echo "[✓] Watchdog đã start (timer)."
  send_telegram "<b>🛡️ Watchdog Đã Start</b>%0A$SERVER_INFO%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

stop_watchdog() {
  echo "=== (6) Stop Watchdog Service ==="
  systemctl disable --now "${WATCHDOG_SERVICE}.timer" >/dev/null 2>&1 || true
  echo "[✓] Watchdog đã stop (timer)."
  send_telegram "<b>🛑 Watchdog Đã Stop</b>%0A$SERVER_INFO%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

status_watchdog() {
  echo "=== (7) Status Watchdog Service ==="
  systemctl status "${WATCHDOG_SERVICE}.timer" --no-pager || true
  echo
}

uninstall_watchdog() {
  echo "=== (9) Uninstall Watchdog Service (xóa unit) ==="
  systemctl disable --now "${WATCHDOG_SERVICE}.timer" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${WATCHDOG_SERVICE}" "/etc/systemd/system/${WATCHDOG_SERVICE}.timer" >/dev/null 2>&1 || true
  rm -f "$WATCHDOG_SCRIPT" >/dev/null 2>&1 || true
  systemctl daemon-reload
  echo "[✓] Đã gỡ watchdog service/unit."
  send_telegram "<b>🧹 Watchdog Đã Uninstall</b>%0A$SERVER_INFO%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

configure_telegram() {
  echo
  echo "=== (8) Cấu hình Telegram ==="
  read -r -p "Bot Token: " bot_token
  read -r -p "Chat ID: " chat_id
  if [[ -z "$bot_token" || -z "$chat_id" ]]; then
    echo "[!] Không được để trống."
    return
  fi
  mkdir -p /etc/optimai
  cat <<EOF > "$TELEGRAM_CONFIG"
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
EOF
  chmod 600 "$TELEGRAM_CONFIG"
  load_telegram_config
  send_telegram "<b>✅ Cấu Hình Telegram Thành Công</b>%0A$SERVER_INFO%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "[✓] Đã lưu & gửi test message."
  echo
}

install_first_time() {
  echo "=== (1) Cài node lần đầu ==="
  ensure_cli
  install_docker_if_needed
  install_tmux_if_needed
  prefetch_crawler_image

  echo "[*] Login OptimAI (nhập email & password):"
  "$CLI_PATH" auth login --legacy

  echo
  if start_node_in_tmux; then
    send_telegram "<b>🟢 Node Cài Đặt & Khởi Động Thành Công</b>%0A$SERVER_INFO%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    start_watchdog
  else
    echo "[!] Start node thất bại. Xem log tmux ở trên."
  fi
}

update_node() {
  echo "=== (3) Cập nhật node ==="
  ensure_cli
  if "$CLI_PATH" update; then
    send_telegram "<b>🔄 Node Đã Cập Nhật</b>%0A$SERVER_INFO%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "[✓] Update xong."
  else
    echo "[!] optimai-cli update bị lỗi."
    echo "    -> Hãy chọn menu 10 để Reinstall optimai-cli (xóa + tải lại bản mới)."
    send_telegram "<b>⚠️ optimai-cli update lỗi</b>%0A$SERVER_INFO%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    return 1
  fi
  echo
}

check_rewards() {
  echo "=== (4) Kiểm tra rewards ==="
  ensure_cli
  "$CLI_PATH" rewards balance || true
  echo
}

on_exit() {
  echo -e "$PROMO_TEXT"
}
trap on_exit EXIT

# ===== Main =====
parse_deploy_args "$@"
banner
must_be_root
apply_telegram_args_if_provided
load_telegram_config

while true; do
  echo "OptimAI CLI All in One - Tuangg - Version 1.1.8"
  echo "1) Cài đặt node lần đầu (tự động watchdog service + Telegram)"
  echo "2) Xem log node (tmux session '$TMUX_SESSION')"
  echo "3) Cập nhật node"
  echo "4) Kiểm tra rewards"
  echo "5) Start Watchdog Service"
  echo "6) Stop Watchdog Service"
  echo "7) Status Watchdog Service"
  echo "8) Cấu hình Telegram"
  echo "9) Uninstall Watchdog Service (xóa unit)"
  echo "10) Reinstall optimai-cli (xóa + tải lại bản mới)"
  echo "0) Thoát"
  echo
  read -r -p "Chọn [0-10]: " choice

  case "$choice" in
    1) install_first_time ;;
    2) view_logs_menu ;;
    3) update_node ;;
    4) check_rewards ;;
    5) start_watchdog ;;
    6) stop_watchdog ;;
    7) status_watchdog ;;
    8) configure_telegram ;;
    9) uninstall_watchdog ;;
    10) reinstall_cli ;;
    0) echo "Bye!"; exit 0 ;;
    *) echo "[!] Lựa chọn không hợp lệ." ;;
  esac
done
