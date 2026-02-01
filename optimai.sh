#!/usr/bin/env bash
set -euo pipefail

# =======================
# OptimAI CLI All in One - Tuangg
# Version: 1.1.3
# Release date: 2026-02-01
#
# Fix kept from 1.1.2:
# - Watchdog không bị exit do grep/pipeline + set -euo pipefail (dùng awk thuần, không grep)
# - EXIT trap chỉ gửi cảnh báo khi exit code != 0 (tránh spam “die” khi exit bình thường)
#
# Kept optimizations:
# ✅ Nếu count >= MAX_RESTARTS: KHÔNG restart, chỉ cảnh báo 1 lần (rate-limit) và chờ đến khi WINDOW trôi qua
# ✅ Stop watchdog: mặc định không xóa unit, chỉ stop/disable. Uninstall tách menu riêng.
#
# Change in 1.1.3:
# - Bổ sung lại quảng cáo ở câu chào tạm biệt (kèm icon)
# =======================

# Quảng cáo hiển thị khi thoát
PROMO_TEXT=$'\n✨ Ae dùng script thấy ok thì follow mình để update bản mới nhé 👉 https://x.com/tuagg\n'

TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"

WATCHDOG_SCRIPT="/usr/local/bin/optimai-watchdog"
WATCHDOG_SERVICE="optimai-watchdog.service"

TELEGRAM_CONFIG="/etc/optimai/telegram.conf"
SERVER_INFO=""

banner() {
  clear
  echo "============================================================"
  echo "        OptimAI CLI All in One - Tuangg (v1.1.3)"
  echo "============================================================"
  echo
}

must_be_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[!] Vui lòng chạy script bằng root (sudo)."
    exit 1
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
  local hostname
  hostname=$(hostname 2>/dev/null || echo "Unknown")
  local public_ip
  public_ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "Unknown")
  echo "Server: <b>$hostname</b>%0AIP: <code>$public_ip</code>"
}

load_telegram_config() {
  SERVER_INFO=$(get_server_info)
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

install_tmux_if_needed() {
  if command -v tmux >/dev/null 2>&1; then
    return 0
  fi
  echo "[*] tmux chưa cài. Đang cài..."
  apt-get update -y
  apt-get install -y tmux
  echo "[✓] tmux đã cài."
}

prefetch_crawler_image() {
  if command -v docker >/dev/null 2>&1; then
    echo "[*] Prefetch image crawl4ai..."
    docker pull unclecode/crawl4ai:0.7.3 >/dev/null 2>&1 || true
  fi
}

ensure_cli() {
  if [[ -x "$CLI_PATH" ]]; then
    return 0
  fi

  echo "[*] optimai-cli chưa có. Đang tải..."
  local api_url="https://api.github.com/repos/optimai-network/optimai-cli/releases/latest"

  local download_url
  download_url="$(curl -fsSL "$api_url" \
    | grep -oE '"browser_download_url":[ ]*"[^"]+"' \
    | cut -d'"' -f4 \
    | grep -i linux \
    | head -n 1 || true)"

  if [[ -z "$download_url" ]]; then
    echo "[!] Không tìm thấy bản release phù hợp (linux)."
    exit 1
  fi

  curl -fsSL "$download_url" -o "$CLI_PATH"
  chmod +x "$CLI_PATH"
  echo "[✓] Đã cài optimai-cli: $CLI_PATH"
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
  echo "$(date "+%Y-%m-%d %H:%M:%S"): 🔄 Đang gửi Telegram"
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

# Chỉ cảnh báo die khi exit code != 0, và tránh set -e làm trap chết ngược
trap '
  code=$?
  set +e
  if [[ $code -ne 0 ]]; then
    msg="<b>🔴 Watchdog Die Bất Ngờ</b>%0A$SERVER_INFO%0AExit code: ${code}%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")%0AVui lòng kiểm tra: journalctl -u optimai-watchdog"
    send_telegram "$msg"
    echo "$(date "+%Y-%m-%d %H:%M:%S"): ❌ Watchdog die (exit code: ${code})"
  fi
  exit $code
' EXIT

startup_msg="<b>🟢 OptimAI Watchdog Khởi Động Thành Công</b>%0A$SERVER_INFO%0AĐang bảo vệ node – chu kỳ 60 giây.%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
send_telegram "$startup_msg"
echo "$(date "+%Y-%m-%d %H:%M:%S"): ✅ Đã gửi thông báo khởi động"

touch "$RESTART_LOG" || true

while true; do
  echo "$(date "+%Y-%m-%d %H:%M:%S"): === BẮT ĐẦU KIỂM TRA ==="

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "$(date "+%Y-%m-%d %H:%M:%S"): ✅ Node ổn định"
  else
    now=$(date +%s)
    cutoff=$((now - WINDOW))

    # FIX ROOT: dùng awk thuần để tránh grep exit 1 làm chết script dưới set -e + pipefail
    tmp="$(mktemp)" || { echo "$(date "+%Y-%m-%d %H:%M:%S"): mktemp failed"; sleep 60; continue; }
    awk -v c="$cutoff" '($1 ~ /^[0-9]+$/) && ($1 > c) {print $1}' "$RESTART_LOG" 2>/dev/null > "$tmp" || true
    mv "$tmp" "$RESTART_LOG" 2>/dev/null || true

    count=$(awk '($1 ~ /^[0-9]+$/){n++} END{print n+0}' "$RESTART_LOG" 2>/dev/null || echo 0)

    # HARD BLOCK + rate-limit + wait until WINDOW passes
    if [[ "$count" -ge "$MAX_RESTARTS" ]]; then
      oldest=$(head -n 1 "$RESTART_LOG" 2>/dev/null || echo "$now")
      unblock_at=$((oldest + WINDOW))
      wait_sec=$((unblock_at - now + 1))
      if [[ "$wait_sec" -lt 60 ]]; then wait_sec=60; fi

      last_unblock=0
      if [[ -f "$BLOCK_STATE" ]]; then
        last_unblock=$(cat "$BLOCK_STATE" 2>/dev/null || echo 0)
      fi

      if [[ "$last_unblock" -ne "$unblock_at" ]]; then
        echo "$unblock_at" > "$BLOCK_STATE" 2>/dev/null || true
        block_msg="<b>🔴 Watchdog BLOCKED – Giới Hạn Restart</b>%0A$SERVER_INFO%0AĐã đạt $MAX_RESTARTS lần trong 10 phút.%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
        send_telegram "$block_msg"
        echo "$(date "+%Y-%m-%d %H:%M:%S"): 🚫 BLOCKED ($count/$MAX_RESTARTS) - đợi $wait_sec giây"
      else
        echo "$(date "+%Y-%m-%d %H:%M:%S"): 🚫 BLOCKED ($count/$MAX_RESTARTS) - đã cảnh báo, đợi $wait_sec giây"
      fi

      sleep "$wait_sec"
      continue
    fi

    alert_msg="<b>🟠 Node Dừng – Đang Restart ($((count + 1))/$MAX_RESTARTS)</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
    send_telegram "$alert_msg"

    echo "$(date "+%Y-%m-%d %H:%M:%S"): ⚠️ Restart lần $((count + 1))"
    echo "$now" >> "$RESTART_LOG"

    if tmux new-session -d -s "$TMUX_SESSION" "$CLI_PATH node start" 2>/dev/null; then
      success_msg="<b>🟢 Restart Thành Công</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
      send_telegram "$success_msg"
    else
      fail_msg="<b>🔴 Restart Thất Bại</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
      send_telegram "$fail_msg"
    fi
  fi

  echo "$(date "+%Y-%m-%d %H:%M:%S"): === KẾT THÚC KIỂM TRA – ngủ 60 giây ==="
  sleep 60
done
EOF

  chmod +x "$WATCHDOG_SCRIPT"
}

create_watchdog_service() {
  cat <<EOF > "/etc/systemd/system/$WATCHDOG_SERVICE"
[Unit]
Description=OptimAI Watchdog Service - Tuangg
After=network.target

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

start_watchdog() {
  echo
  echo "=== (5) Start Watchdog Service ==="
  create_watchdog_script
  create_watchdog_service
  systemctl enable --now "$WATCHDOG_SERVICE"
  echo "[✓] Watchdog service đã start và enable."
  echo "   Xem log: journalctl -u $WATCHDOG_SERVICE -f"
  echo
}

stop_watchdog() {
  echo
  echo "=== (6) Stop Watchdog Service ==="
  systemctl stop "$WATCHDOG_SERVICE" 2>/dev/null || true
  systemctl disable "$WATCHDOG_SERVICE" 2>/dev/null || true
  echo "[✓] Watchdog service đã stop & disable (không xóa unit)."
  echo
}

uninstall_watchdog() {
  echo
  echo "=== (9) Uninstall Watchdog Service (xóa unit) ==="
  systemctl stop "$WATCHDOG_SERVICE" 2>/dev/null || true
  systemctl disable "$WATCHDOG_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$WATCHDOG_SERVICE"
  systemctl daemon-reload
  echo "[✓] Đã uninstall watchdog: stop/disable + xóa file service."
  echo
}

status_watchdog() {
  echo
  echo "=== (7) Status Watchdog Service ==="
  systemctl status "$WATCHDOG_SERVICE" --no-pager
  echo
  echo "👉 Xem log: journalctl -u $WATCHDOG_SERVICE -f"
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
  "$CLI_PATH" auth login

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
  "$CLI_PATH" update
  send_telegram "<b>🔄 Node Đã Cập Nhật</b>%0A$SERVER_INFO%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")"
  echo "[✓] Update xong."
}

check_rewards() {
  echo "=== (4) Kiểm tra rewards ==="
  ensure_cli
  "$CLI_PATH" rewards balance
}

parse_deploy_args() { return 0; }

# ===== Main =====
parse_deploy_args "$@"
load_telegram_config
banner
must_be_root

while true; do
  echo "OptimAI CLI All in One - Tuangg - Version 1.1.3"
  echo "1) Cài đặt node lần đầu (tự động watchdog service + Telegram)"
  echo "2) Xem log node (tmux session '$TMUX_SESSION')"
  echo "3) Cập nhật node"
  echo "4) Kiểm tra rewards"
  echo "5) Start Watchdog Service"
  echo "6) Stop Watchdog Service"
  echo "7) Status Watchdog Service"
  echo "8) Cấu hình Telegram"
  echo "9) Uninstall Watchdog Service (xóa unit)"
  echo "0) Thoát"
  echo
  read -r -p "Chọn [0-9]: " choice

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
    0)
      echo -e "Tạm biệt! 👋😄${PROMO_TEXT}"
      exit 0
      ;;
    *) echo "[!] Lựa chọn không hợp lệ." ;;
  esac

  echo
  read -r -p "Nhấn Enter để tiếp tục..."
  clear
  banner
done
