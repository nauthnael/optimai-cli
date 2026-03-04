#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OptimAI CLI All in One - Tuangg
# Version: 1.1.6
#
# Update theo dev OptimAI:
# - Link tải mới nhất: https://cli-node.optimai.network/optimai_cli_ubuntu
# - Login dùng: optimai-cli auth login --legacy
#
# Features:
# - Cài lần đầu: tự chạy node trong tmux + bật watchdog + Telegram
# - Xem log tmux
# - Cập nhật node (optimai-cli update) + có menu reinstall khi update lỗi
# - Watchdog systemd timer (30s), có BLOCK restart để tránh loop
# ============================================================

PROMO_TEXT=$'\n✨ Ae dùng script thấy ok thì follow mình để update bản mới nhé 👉 https://x.com/tuangg\n'

TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"

WATCHDOG_SCRIPT="/usr/local/bin/optimai-watchdog"
WATCHDOG_SERVICE="optimai-watchdog.service"

TELEGRAM_CONFIG="/etc/optimai/telegram.conf"
SERVER_INFO=""

# Args for Telegram (optional)
ARG_BOT_TOKEN=""
ARG_CHAT_ID=""

# Official CLI URL (updated)
CLI_URL="https://cli-node.optimai.network/optimai_cli_ubuntu"

banner() {
  clear
  echo "============================================================"
  echo "        OptimAI CLI All in One - Tuangg (v1.1.6)"
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
  local hostname
  hostname=$(hostname 2>/dev/null || echo "Unknown")
  local public_ip
  public_ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "Unknown")
  echo "Server: <b>$hostname</b>%0AIP: <code>$public_ip</code>"
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
    send_telegram "<b>✅ Reinstall optimai-cli OK</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
    return 0
  else
    echo "[!] Reinstall xong nhưng optimai-cli không chạy được."
    return 1
  fi
}

start_node_in_tmux() {
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[!] Node đang chạy trong tmux session '$TMUX_SESSION'."
    return 1
  fi
  echo "[*] Đang start node trong tmux session '$TMUX_SESSION'..."
  tmux new-session -d -s "$TMUX_SESSION" "$CLI_PATH node start"
  echo "[✓] Node đã chạy. Dùng: tmux attach -t $TMUX_SESSION"
  return 0
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
set -euo pipefail

TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"
RESTART_LOG="/tmp/optimai-restarts.log"
BLOCK_STATE="/tmp/optimai-blocked.state"
TELEGRAM_CONFIG="/etc/optimai/telegram.conf"
MAX_RESTARTS=4
WINDOW=600

send_telegram() {
  local message="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "$(date "+%Y-%m-%d %H:%M:%S"): ⚠️ Không có config Telegram"
    return 0
  fi
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="$message" \
    -d parse_mode="HTML" \
    -d disable_web_page_preview=true >/dev/null 2>&1 || true
}

get_server_info() {
  local hostname
  hostname=$(hostname 2>/dev/null || echo "Unknown")
  local public_ip
  public_ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "Unknown")
  echo "Server: <b>$hostname</b>%0AIP: <code>$public_ip</code>"
}

if [[ -f "$TELEGRAM_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$TELEGRAM_CONFIG" 2>/dev/null || true
fi

SERVER_INFO="$(get_server_info)"

now_ts() { date +%s; }

count_recent_restarts() {
  local now
  now="$(now_ts)"
  if [[ ! -f "$RESTART_LOG" ]]; then
    echo 0
    return 0
  fi

  local cutoff=$((now - WINDOW))
  awk -v c="$cutoff" '$1>=c {n++} END{print n+0}' "$RESTART_LOG" 2>/dev/null || echo 0
}

append_restart_log() {
  local now
  now="$(now_ts)"
  echo "$now restart" >> "$RESTART_LOG"
}

is_blocked() {
  if [[ ! -f "$BLOCK_STATE" ]]; then
    return 1
  fi
  local blocked_until
  blocked_until="$(cat "$BLOCK_STATE" 2>/dev/null || echo 0)"
  local now
  now="$(now_ts)"
  if [[ "$now" -lt "$blocked_until" ]]; then
    return 0
  fi
  rm -f "$BLOCK_STATE" >/dev/null 2>&1 || true
  return 1
}

set_blocked() {
  local now
  now="$(now_ts)"
  local blocked_until=$((now + WINDOW))
  echo "$blocked_until" > "$BLOCK_STATE"
}

should_notify_block_once() {
  local marker="/tmp/optimai-block-notified.marker"
  if [[ -f "$marker" ]]; then
    return 1
  fi
  echo "1" > "$marker"
  return 0
}

clear_block_notify_marker_if_unblocked() {
  local marker="/tmp/optimai-block-notified.marker"
  if [[ ! -f "$BLOCK_STATE" && -f "$marker" ]]; then
    rm -f "$marker" >/dev/null 2>&1 || true
  fi
}

main() {
  clear_block_notify_marker_if_unblocked

  if is_blocked; then
    if should_notify_block_once; then
      send_telegram "<b>⛔ Watchdog BLOCK Restart</b>%0A$SERVER_INFO%0AĐã restart quá nhiều lần trong ${WINDOW}s. Tạm dừng restart để tránh loop.%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
    fi
    exit 0
  fi

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    exit 0
  fi

  local count
  count="$(count_recent_restarts)"

  if [[ "$count" -ge "$MAX_RESTARTS" ]]; then
    set_blocked
    send_telegram "<b>⛔ Watchdog BLOCK Restart</b>%0A$SERVER_INFO%0AĐạt ngưỡng restart (${count}/${MAX_RESTARTS}) trong ${WINDOW}s. Tạm dừng restart.%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
    exit 0
  fi

  append_restart_log
  tmux new-session -d -s "$TMUX_SESSION" "$CLI_PATH node start" || true
  send_telegram "<b>⚠️ Node Đã Bị Tắt - Tự Restart</b>%0A$SERVER_INFO%0ARestart count (window): ${count}/${MAX_RESTARTS}%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
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
  send_telegram "<b>🛡️ Watchdog Đã Start</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
  echo
}

stop_watchdog() {
  echo "=== (6) Stop Watchdog Service ==="
  systemctl disable --now "${WATCHDOG_SERVICE}.timer" >/dev/null 2>&1 || true
  echo "[✓] Watchdog đã stop (timer)."
  send_telegram "<b>🛑 Watchdog Đã Stop</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
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
  send_telegram "<b>🧹 Watchdog Đã Uninstall</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
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
  send_telegram "<b>✅ Cấu Hình Telegram Thành Công</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
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
    send_telegram "<b>🟢 Node Cài Đặt & Khởi Động Thành Công</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
    start_watchdog
  else
    echo "[*] Node có thể đã chạy sẵn."
  fi
}

update_node() {
  echo "=== (3) Cập nhật node ==="
  ensure_cli
  if "$CLI_PATH" update; then
    send_telegram "<b>🔄 Node Đã Cập Nhật</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
    echo "[✓] Update xong."
  else
    echo "[!] optimai-cli update bị lỗi."
    echo "    -> Hãy chọn menu 10 để Reinstall optimai-cli (xóa + tải lại bản mới)."
    send_telegram "<b>⚠️ optimai-cli update lỗi</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
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
  echo "OptimAI CLI All in One - Tuangg - Version 1.1.6"
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
