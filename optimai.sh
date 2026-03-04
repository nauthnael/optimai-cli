#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OptimAI CLI All in One - Tuangg
# Version: 1.1.10
#
# Updates:
# v1.1.10:
#   - Watchdog viết lại dựa trên kiến trúc ổn định của v1.1.4:
#     + Type=simple + while true (không dùng oneshot+timer)
#     + Check node bằng tmux has-session (không phụ thuộc CLI output)
#     + Dùng awk thuần để tránh grep exit 1 dưới set -euo pipefail
#     + trap EXIT: cảnh báo Telegram khi watchdog chết bất ngờ
#     + Thông báo Telegram khi watchdog khởi động
#   - Giữ lại toàn bộ tính năng v1.1.9:
#     + CLI URL trực tiếp (không qua GitHub API)
#     + Login --legacy
#     + start_node_in_tmux dùng bash -lc + verify retry
#     + reinstall_cli (menu 10)
#     + Log persistent: /var/log/optimai-watchdog.log
# v1.1.9:
#   - Viết lại hoàn toàn watchdog, fix heredoc EOF expand
# v1.1.8:
#   - Fix watchdog set -euo pipefail, node_running, sleep verify
# v1.1.7:
#   - Fix start node trong tmux dùng bash -lc
#
# Dev info:
# - Link tải CLI: https://cli-node.optimai.network/optimai_cli_ubuntu
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

# ============================================================
# BANNER & UTILS
# ============================================================

banner() {
  clear
  echo "============================================================"
  echo "        OptimAI CLI All in One - Tuangg (v1.1.10)"
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
      --bot-token=*) ARG_BOT_TOKEN="${1#*=}"; shift ;;
      --bot-token)   ARG_BOT_TOKEN="${2:-}";  shift 2 ;;
      --chat-id=*)   ARG_CHAT_ID="${1#*=}";   shift ;;
      --chat-id)     ARG_CHAT_ID="${2:-}";    shift 2 ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  sudo ./optimai.sh [--bot-token=TOKEN] [--chat-id=CHAT_ID]

Examples:
  sudo ./optimai.sh --bot-token=123:ABC --chat-id=987654321
  sudo ./optimai.sh --bot-token 123:ABC --chat-id 987654321
USAGE
        exit 0 ;;
      *) shift ;;
    esac
  done
}

apply_telegram_args_if_provided() {
  if [[ -n "${ARG_BOT_TOKEN:-}" && -n "${ARG_CHAT_ID:-}" ]]; then
    mkdir -p /etc/optimai
    cat <<EOF > "$TELEGRAM_CONFIG"
TELEGRAM_BOT_TOKEN="$ARG_BOT_TOKEN"
TELEGRAM_CHAT_ID="$ARG_CHAT_ID"
EOF
    chmod 600 "$TELEGRAM_CONFIG"
    echo "[✓] Đã nhận tham số Telegram và lưu vào $TELEGRAM_CONFIG"
  elif [[ -n "${ARG_BOT_TOKEN:-}" || -n "${ARG_CHAT_ID:-}" ]]; then
    echo "[!] Cần truyền đủ cả --bot-token và --chat-id để auto cấu hình Telegram."
  fi
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

# ============================================================
# INSTALL DEPENDENCIES
# ============================================================

install_tmux_if_needed() {
  if command -v tmux >/dev/null 2>&1; then return 0; fi
  echo "[*] tmux chưa cài. Đang cài..."
  apt-get update -y
  apt-get install -y tmux
  echo "[✓] tmux đã cài."
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then return 0; fi
  echo "[*] Docker chưa cài. Đang cài..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  echo "[✓] Docker đã cài."
}

prefetch_crawler_image() {
  if command -v docker >/dev/null 2>&1; then
    echo "[*] Prefetch image crawl4ai..."
    docker pull unclecode/crawl4ai:0.7.3 >/dev/null 2>&1 || true
  fi
}

# ============================================================
# CLI MANAGEMENT
# ============================================================

download_cli_to_tmp() {
  local tmp="$1"
  echo "[*] Đang tải optimai-cli từ: $CLI_URL"
  curl -fL --retry 5 --retry-delay 2 --connect-timeout 10 "$CLI_URL" -o "$tmp"
}

ensure_cli() {
  if [[ -x "$CLI_PATH" ]]; then return 0; fi
  echo "[*] optimai-cli chưa có. Đang tải..."
  local tmp="/tmp/optimai-cli.$RANDOM.$RANDOM"
  if ! download_cli_to_tmp "$tmp"; then
    echo "[!] Tải optimai-cli thất bại."
    rm -f "$tmp" || true
    exit 1
  fi
  install -m 0755 "$tmp" "$CLI_PATH"
  rm -f "$tmp" || true
  if "$CLI_PATH" --help >/dev/null 2>&1; then
    echo "[✓] Đã cài optimai-cli: $CLI_PATH"
    return 0
  fi
  echo "[!] optimai-cli không chạy được. Có thể sai arch hoặc thiếu thư viện."
  exit 1
}

reinstall_cli() {
  echo "=== (10) Reinstall optimai-cli (xóa + tải lại bản mới) ==="

  # Stop node trước để tránh binary đang bị chiếm
  if command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      echo "[*] Kill tmux session '$TMUX_SESSION' trước khi reinstall..."
      tmux kill-session -t "$TMUX_SESSION" || true
      echo "[✓] Đã stop tmux session."
    fi
  fi

  # Backup bản cũ
  if [[ -f "$CLI_PATH" ]]; then
    local backup="${CLI_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    echo "[*] Backup: $CLI_PATH -> $backup"
    mv -f "$CLI_PATH" "$backup"
  fi

  local tmp="/tmp/optimai-cli.$RANDOM.$RANDOM"
  if ! download_cli_to_tmp "$tmp"; then
    echo "[!] Tải thất bại. Kiểm tra mạng/DNS/Firewall."
    rm -f "$tmp" || true
    return 1
  fi

  install -m 0755 "$tmp" "$CLI_PATH"
  rm -f "$tmp" || true

  if "$CLI_PATH" --help >/dev/null 2>&1; then
    echo "[✓] Reinstall OK: $CLI_PATH"
    send_telegram "<b>✅ Reinstall optimai-cli OK</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  else
    echo "[!] Reinstall xong nhưng optimai-cli không chạy được."
    return 1
  fi
  echo
}

# ============================================================
# NODE MANAGEMENT
# ============================================================

start_node_in_tmux() {
  install_tmux_if_needed

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[*] Kill session cũ '$TMUX_SESSION' để start lại sạch..."
    tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
    sleep 1
  fi

  echo "[*] Đang start node trong tmux session '$TMUX_SESSION'..."
  tmux new-session -d -s "$TMUX_SESSION" "bash -lc '${CLI_PATH} node start'"

  # Verify: retry 3 lần x 5 giây
  local i st
  for i in 1 2 3; do
    sleep 5
    st="$(tmux has-session -t "$TMUX_SESSION" 2>/dev/null && echo "running" || echo "stopped")"
    if [[ "$st" == "running" ]]; then
      echo "[✓] Node đã chạy OK (tmux session '$TMUX_SESSION' alive, lần $i)."
      echo "    Xem log: tmux attach -t $TMUX_SESSION"
      return 0
    fi
    echo "[~] Chờ node up... lần $i/3"
  done

  echo "[!] Start xong nhưng tmux session không còn tồn tại."
  echo "[*] 50 dòng log tmux gần nhất:"
  tmux capture-pane -t "${TMUX_SESSION}:0.0" -p -S -50 2>/dev/null || true
  echo "[*] Thử xem trực tiếp: tmux attach -t $TMUX_SESSION"
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

update_node() {
  echo "=== (3) Cập nhật node ==="
  ensure_cli
  if "$CLI_PATH" update; then
    echo "[✓] Update xong."
    send_telegram "<b>🔄 Node Đã Cập Nhật</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  else
    echo "[!] optimai-cli update bị lỗi."
    echo "    -> Chọn menu 10 để Reinstall optimai-cli."
    send_telegram "<b>⚠️ optimai-cli Update Lỗi</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
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

# ============================================================
# WATCHDOG - Kiến trúc v1.1.4 (Type=simple, while true)
#
# Dùng <<'EOF' (heredoc có quote) giống v1.1.4:
#   -> Biến TMUX_SESSION, CLI_PATH hardcode trực tiếp trong script
#   -> Không cần expand từ outer script, không risk lỗi heredoc
# ============================================================

create_watchdog_script() {
  cat <<'WATCHDOG_EOF' > "$WATCHDOG_SCRIPT"
#!/usr/bin/env bash
set -euo pipefail

# ---- Cấu hình ----
TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"
TELEGRAM_CONFIG="/etc/optimai/telegram.conf"
RESTART_LOG="/var/log/optimai-watchdog.log"
BLOCK_STATE="/tmp/optimai-blocked.state"

MAX_RESTARTS=4   # Số restart tối đa trong WINDOW giây
WINDOW=600       # 10 phút
SLEEP_INTERVAL=60

# ---- Telegram ----

send_telegram() {
  local message="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] Telegram chưa cấu hình, bỏ qua."
    return 0
  fi
  curl -s --connect-timeout 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
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

# ---- Load Telegram config & server info ----
if [[ -f "$TELEGRAM_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$TELEGRAM_CONFIG" 2>/dev/null || true
fi
SERVER_INFO="$(get_server_info)"

# ---- trap: cảnh báo Telegram nếu watchdog chết bất ngờ ----
trap '
  code=$?
  set +e
  if [[ $code -ne 0 ]]; then
    send_telegram "<b>🔴 Watchdog Chết Bất Ngờ</b>%0A'"$SERVER_INFO"'%0AExit code: ${code}%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")%0AKiểm tra: journalctl -u optimai-watchdog.service -n 50"
    echo "$(date "+%Y-%m-%d %H:%M:%S") [watchdog] DIE exit_code=$code"
  fi
  exit $code
' EXIT

# ---- Thông báo khởi động ----
touch "$RESTART_LOG" 2>/dev/null || true
echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] === STARTED ==="
send_telegram "<b>🛡️ OptimAI Watchdog Khởi Động</b>%0A${SERVER_INFO}%0AKiểm tra node mỗi ${SLEEP_INTERVAL} giây.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"

# ============================================================
# MAIN LOOP
# ============================================================
while true; do
  echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] === CHECK START ==="

  # -- Kiểm tra node bằng tmux has-session (không phụ thuộc CLI output) --
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] OK - tmux session '$TMUX_SESSION' alive"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] === CHECK END - sleep ${SLEEP_INTERVAL}s ==="
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  # -- Node DOWN --
  echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] WARN - tmux session '$TMUX_SESSION' NOT found"

  now=$(date +%s)
  cutoff=$((now - WINDOW))

  # Dọn log cũ ngoài window + đếm restart gần đây
  # Dùng awk thuần để tránh grep exit 1 làm chết script dưới set -e + pipefail
  tmp_log="$(mktemp)" || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] ERROR: mktemp thất bại"
    sleep "$SLEEP_INTERVAL"
    continue
  }
  awk -v c="$cutoff" '($1 ~ /^[0-9]+$/) && ($1 > c) {print}' \
    "$RESTART_LOG" 2>/dev/null > "$tmp_log" || true
  mv "$tmp_log" "$RESTART_LOG" 2>/dev/null || true

  count=$(awk '($1 ~ /^[0-9]+$/){n++} END{print n+0}' "$RESTART_LOG" 2>/dev/null || echo 0)

  echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] Restart count trong ${WINDOW}s: ${count}/${MAX_RESTARTS}"

  # -- HARD BLOCK: đã đạt ngưỡng --
  if [[ "$count" -ge "$MAX_RESTARTS" ]]; then
    oldest=$(awk '($1 ~ /^[0-9]+$/){print $1; exit}' "$RESTART_LOG" 2>/dev/null || echo "$now")
    unblock_at=$((oldest + WINDOW))
    wait_sec=$((unblock_at - now + 1))
    [[ "$wait_sec" -lt "$SLEEP_INTERVAL" ]] && wait_sec=$SLEEP_INTERVAL

    # Chỉ gửi Telegram 1 lần mỗi chu kỳ block
    last_unblock=0
    [[ -f "$BLOCK_STATE" ]] && last_unblock=$(cat "$BLOCK_STATE" 2>/dev/null || echo 0)

    if [[ "$last_unblock" -ne "$unblock_at" ]]; then
      echo "$unblock_at" > "$BLOCK_STATE" 2>/dev/null || true
      send_telegram "<b>⛔ Watchdog BLOCKED</b>%0A${SERVER_INFO}%0AĐã restart ${count}/${MAX_RESTARTS} lần trong ${WINDOW}s. Tạm dừng để tránh loop.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] BLOCKED (${count}/${MAX_RESTARTS}) - gửi Telegram, đợi ${wait_sec}s"
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] BLOCKED (${count}/${MAX_RESTARTS}) - đã cảnh báo, đợi ${wait_sec}s"
    fi

    sleep "$wait_sec"
    continue
  fi

  # -- Thực hiện restart --
  echo "$now" >> "$RESTART_LOG"
  send_telegram "<b>🟠 Node DOWN - Đang Restart ($((count + 1))/${MAX_RESTARTS})</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] Restart lần $((count + 1))/${MAX_RESTARTS}..."

  tmux new-session -d -s "$TMUX_SESSION" "bash -lc '${CLI_PATH} node start'" 2>/dev/null
  restart_exit=$?

  if [[ $restart_exit -eq 0 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] tmux new-session OK"
    # Verify sau 10s
    sleep 10
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] RESTART OK - session alive"
      send_telegram "<b>🟢 Restart Thành Công ($((count + 1))/${MAX_RESTARTS})</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    else
      echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] WARN - session đã chết ngay sau restart"
      send_telegram "<b>🔴 Restart Thất Bại - Session Chết Ngay</b>%0A${SERVER_INFO}%0AKiểm tra: tmux attach -t ${TMUX_SESSION}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    fi
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] ERROR - tmux new-session thất bại (exit ${restart_exit})"
    send_telegram "<b>🔴 Restart Thất Bại</b>%0A${SERVER_INFO}%0Atmux new-session lỗi (exit ${restart_exit})%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] === CHECK END - sleep ${SLEEP_INTERVAL}s ==="
  sleep "$SLEEP_INTERVAL"
done
WATCHDOG_EOF

  chmod +x "$WATCHDOG_SCRIPT"
  echo "[✓] Đã tạo watchdog script: $WATCHDOG_SCRIPT"
}

create_watchdog_service() {
  # Type=simple + Restart=always (giống v1.1.4, ổn định hơn oneshot+timer)
  cat <<EOF > "/etc/systemd/system/$WATCHDOG_SERVICE"
[Unit]
Description=OptimAI Watchdog - Tuangg (tmux: $TMUX_SESSION)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

# ============================================================
# WATCHDOG MANAGEMENT
# ============================================================

start_watchdog() {
  echo "=== (5) Start Watchdog Service ==="
  create_watchdog_script
  create_watchdog_service
  systemctl enable --now "$WATCHDOG_SERVICE"
  echo "[✓] Watchdog service đã start và enable."
  echo "    Xem log: journalctl -u $WATCHDOG_SERVICE -f"
  echo "    Log file: tail -f /var/log/optimai-watchdog.log"
  send_telegram "<b>🛡️ Watchdog Đã Start</b>%0A${SERVER_INFO}%0AKiểm tra node mỗi 60 giây.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

stop_watchdog() {
  echo "=== (6) Stop Watchdog Service ==="
  systemctl stop    "$WATCHDOG_SERVICE" 2>/dev/null || true
  systemctl disable "$WATCHDOG_SERVICE" 2>/dev/null || true
  echo "[✓] Watchdog đã stop & disable (không xóa unit)."
  send_telegram "<b>🛑 Watchdog Đã Stop</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

status_watchdog() {
  echo "=== (7) Status Watchdog Service ==="
  systemctl status "$WATCHDOG_SERVICE" --no-pager || true
  echo
  echo "--- Log gần nhất (/var/log/optimai-watchdog.log) ---"
  if [[ -f /var/log/optimai-watchdog.log ]]; then
    tail -n 20 /var/log/optimai-watchdog.log
  else
    echo "(chưa có log)"
  fi
  echo
  echo "👉 Theo dõi live: journalctl -u $WATCHDOG_SERVICE -f"
  echo
}

uninstall_watchdog() {
  echo "=== (9) Uninstall Watchdog Service ==="
  systemctl stop    "$WATCHDOG_SERVICE" 2>/dev/null || true
  systemctl disable "$WATCHDOG_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$WATCHDOG_SERVICE"
  rm -f "$WATCHDOG_SCRIPT"
  systemctl daemon-reload
  echo "[✓] Đã uninstall watchdog: stop/disable + xóa unit + xóa script."
  send_telegram "<b>🧹 Watchdog Đã Uninstall</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

# ============================================================
# TELEGRAM CONFIG
# ============================================================

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
  send_telegram "<b>✅ Cấu Hình Telegram Thành Công</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "[✓] Đã lưu & gửi test message."
  echo
}

# ============================================================
# FIRST INSTALL
# ============================================================

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
    send_telegram "<b>🟢 Node Cài Đặt & Khởi Động Thành Công</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    start_watchdog
  else
    echo "[!] Start node thất bại. Xem log tmux ở trên."
    send_telegram "<b>⚠️ Node Start Thất Bại</b>%0A${SERVER_INFO}%0AChạy: tmux attach -t ${TMUX_SESSION}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  fi
}

# ============================================================
# ENTRY POINT
# ============================================================

on_exit() {
  echo -e "$PROMO_TEXT"
}
trap on_exit EXIT

parse_deploy_args "$@"
banner
must_be_root
apply_telegram_args_if_provided
load_telegram_config

while true; do
  echo "OptimAI CLI All in One - Tuangg - Version 1.1.10"
  echo "1)  Cài đặt node lần đầu (tự động watchdog + Telegram)"
  echo "2)  Xem log node (tmux attach)"
  echo "3)  Cập nhật node"
  echo "4)  Kiểm tra rewards"
  echo "5)  Start Watchdog Service"
  echo "6)  Stop Watchdog Service"
  echo "7)  Status Watchdog Service + Log"
  echo "8)  Cấu hình Telegram"
  echo "9)  Uninstall Watchdog Service"
  echo "10) Reinstall optimai-cli (xóa + tải lại bản mới)"
  echo "0)  Thoát"
  echo
  read -r -p "Chọn [0-10]: " choice

  case "$choice" in
    1)  install_first_time ;;
    2)  view_logs_menu ;;
    3)  update_node ;;
    4)  check_rewards ;;
    5)  start_watchdog ;;
    6)  stop_watchdog ;;
    7)  status_watchdog ;;
    8)  configure_telegram ;;
    9)  uninstall_watchdog ;;
    10) reinstall_cli ;;
    0)
      echo "Bye! 👋"
      exit 0
      ;;
    *) echo "[!] Lựa chọn không hợp lệ." ;;
  esac

  echo
  read -r -p "Nhấn Enter để tiếp tục..."
  clear
  banner
done
