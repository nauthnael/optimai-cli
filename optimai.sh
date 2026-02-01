#!/usr/bin/env bash
set -euo pipefail

# =======================
# OptimAI CLI All in One - Tuangg
# =======================

CLI_PATH="/usr/local/bin/optimai-cli"
TMUX_SESSION="o"
WATCHDOG_SESSION="watchdog-o"
WATCHDOG_SCRIPT="/usr/local/bin/optimai-watchdog"
TELEGRAM_CONFIG="/etc/optimai/telegram.conf"

# Prefetch crawler image
CRAWLER_IMAGE="unclecode/crawl4ai:0.7.3"

OFFICIAL_DL_URL="https://optimai.network/download/cli-node/linux"
GITHUB_RELEASE_API="https://api.github.com/repos/OptimaiNetwork/OptimAI-CLI-Node/releases/latest"

PROMO_NAME="Tuangg"
PROMO_X_URL="https://x.com/tuangg"
PROMO_TEXT="Ae dùng script thấy ok thì follow mình để update bản mới nhé 👉 ${PROMO_X_URL}"

# ===== Server Info =====
get_server_info() {
  local hostname=$(hostname 2>/dev/null || echo "Unknown")
  local public_ip=$(curl -s --connect-timeout 5 ifconfig.me || echo "Unknown")
  echo "Server: <b>$hostname</b>%0AIP: <code>$public_ip</code>"
}

SERVER_INFO=$(get_server_info)

# ===== Telegram functions =====
load_telegram_config() {
  if [[ -f "$TELEGRAM_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$TELEGRAM_CONFIG" 2>/dev/null || true
  fi
}

send_telegram() {
  local message="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    return 0
  fi

  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="$message" \
    -d parse_mode="HTML" \
    -d disable_web_page_preview=true > /dev/null || true
}

# ===== Argument parsing =====
parse_deploy_args() {
  local bot_token=""
  local chat_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bot-token=*)
        bot_token="${1#*=}"
        ;;
      --chat-id=*)
        chat_id="${1#*=}"
        ;;
      *)
        echo "[!] Tham số không hợp lệ: $1"
        ;;
    esac
    shift
  done

  if [[ -n "$bot_token" && -n "$chat_id" ]]; then
    mkdir -p /etc/optimai
    cat <<EOF > "$TELEGRAM_CONFIG"
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
EOF
    chmod 600 "$TELEGRAM_CONFIG"
    echo "[✓] Đã lưu cấu hình Telegram bảo mật."
  fi
}

# ===== UI =====
banner() {
  clear
  echo
  echo "============================================================"
  echo "  OptimAI CLI All in One - Tuangg"
  echo "============================================================"
  echo
}

promo_once_after_success() {
  echo
  echo "✅ Cài đặt & start node thành công!"
  echo "${PROMO_TEXT}"
  echo
}

must_be_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[!] Vui lòng chạy bằng root hoặc sudo"
    exit 1
  fi
}

install_curl_if_needed() {
  if command -v curl >/dev/null 2>&1; then return; fi
  echo "[*] Cài curl..."
  apt-get update -y && apt-get install -y curl
}

install_tmux_if_needed() {
  if command -v tmux >/dev/null 2>&1; then
    echo "[✓] tmux đã cài."
    return
  fi
  echo "[*] Cài tmux..."
  apt-get update -y && apt-get install -y tmux
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "[✓] Docker đã sẵn sàng."
    return
  fi

  echo "[*] Cài Docker..."
  install_curl_if_needed
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true

  if ! docker info >/dev/null 2>&1; then
    echo "[!] Docker chưa chạy được. Thử reboot hoặc systemctl start docker."
    exit 1
  fi
}

# ===== CLI download =====
download_cli_from_official() {
  install_curl_if_needed
  if curl -fL "$OFFICIAL_DL_URL" -o /tmp/optimai-cli; then
    return 0
  fi
  return 1
}

get_latest_linux_asset_url_from_github() {
  install_curl_if_needed
  local json=$(curl -fsSL "$GITHUB_RELEASE_API")
  echo "$json" | grep -oE '"browser_download_url"\s*:\s*"[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/' | grep -i linux | head -n 1
}

download_cli_from_github() {
  local url=$(get_latest_linux_asset_url_from_github || true)
  if [[ -z "$url" ]]; then
    echo "[!] Không lấy được file từ GitHub."
    exit 1
  fi
  curl -fL "$url" -o /tmp/optimai-cli
}

download_cli() {
  if download_cli_from_official; then
    :
  else
    download_cli_from_github
  fi
  chmod +x /tmp/optimai-cli
  mv /tmp/optimai-cli "$CLI_PATH"
  echo "[✓] Đã cài OptimAI CLI tại: $CLI_PATH"
}

ensure_cli() {
  if [[ ! -x "$CLI_PATH" ]]; then
    download_cli
  else
    echo "[✓] OptimAI CLI đã tồn tại."
  fi
}

# ===== Node control =====
start_node_in_tmux() {
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[!] Session '$TMUX_SESSION' đã tồn tại."
    return 1
  fi
  tmux new-session -d -s "$TMUX_SESSION" "$CLI_PATH node start"
  return 0
}

print_log_instructions() {
  echo
  echo "📌 Xem log node: tmux attach -t ${TMUX_SESSION}"
  echo "📌 Thoát log: Ctrl + b rồi d"
  echo
}

ask_and_maybe_open_logs() {
  read -r -p "Bạn có muốn xem log ngay? (y/N): " ans
  case "${ans:-}" in
    y|Y)
      tmux attach -t "$TMUX_SESSION"
      ;;
    *) echo "[*] Có thể xem sau bằng: tmux attach -t ${TMUX_SESSION}" ;;
  esac
}

view_logs_menu() {
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[!] Node chưa chạy (không có session '$TMUX_SESSION')."
    return
  fi
  print_log_instructions
  tmux attach -t "$TMUX_SESSION"
}

prefetch_crawler_image() {
  echo "[*] Prefetch image ${CRAWLER_IMAGE}..."
  docker pull "${CRAWLER_IMAGE}" || true
}

# ===== Watchdog (phiên bản cải tiến: robust hơn, debug tốt hơn) =====
start_watchdog() {
  echo
  echo "=== Bật watchdog ==="

  if tmux has-session -t "$WATCHDOG_SESSION" 2>/dev/null; then
    echo "[✓] Watchdog đã chạy (session '$WATCHDOG_SESSION')."
    return
  fi

  cat <<'EOF' > "$WATCHDOG_SCRIPT"
#!/usr/bin/env bash
set -euo pipefail

TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"
RESTART_LOG="/tmp/optimai-restarts.log"
TELEGRAM_CONFIG="/etc/optimai/telegram.conf"
MAX_RESTARTS=4
WINDOW=600

# Trap để log khi script die bất ngờ
trap 'echo "$(date '+%Y-%m-%d %H:%M:%S'): ❌ Watchdog script kết thúc bất ngờ (exit code: $?)"; exit' EXIT

# Load config Telegram
if [[ -f "$TELEGRAM_CONFIG" ]]; then
  source "$TELEGRAM_CONFIG" 2>/dev/null || echo "$(date '+%Y-%m-%d %H:%M:%S'): ⚠️ Lỗi load config Telegram"
fi

# Server info
get_server_info() {
  local hostname=$(hostname 2>/dev/null || echo "Unknown")
  local public_ip=$(curl -s --connect-timeout 5 ifconfig.me || echo "Unknown")
  echo "Server: <b>$hostname</b>%0AIP: <code>$public_ip</code>"
}
SERVER_INFO=$(get_server_info) || echo "$(date '+%Y-%m-%d %H:%M:%S'): ⚠️ Lỗi lấy server info"

# Send Telegram với debug log
send_telegram() {
  local message="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ⚠️ Không có config Telegram → bỏ qua gửi"
    return
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S'): 🔄 Đang gửi Telegram: $message"
  if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="$message" \
    -d parse_mode="HTML" \
    -d disable_web_page_preview=true > /dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ✅ Gửi Telegram thành công"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ❌ Gửi Telegram thất bại (curl error)"
  fi
}

touch "$RESTART_LOG" || echo "$(date '+%Y-%m-%d %H:%M:%S'): ⚠️ Lỗi touch restart log"

while true; do
  echo "------------------------------------------------------------"
  echo "$(date '+%Y-%m-%d %H:%M:%S'): === BẮT ĐẦU KIỂM TRA ==="

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ✅ Node đang chạy ổn định"
  else
    now=$(date +%s)
    cutoff=$((now - WINDOW))

    # Dọn log cũ an toàn
    if [[ -f "$RESTART_LOG" ]]; then
      temp_file=$(mktemp) || { echo "$(date '+%Y-%m-%d %H:%M:%S'): ❌ Lỗi mktemp"; continue; }
      grep -E "^[0-9]+$" "$RESTART_LOG" 2>/dev/null | awk -v c="$cutoff" '$1 > c {print}' > "$temp_file" 2>/dev/null || echo "$(date '+%Y-%m-%d %H:%M:%S'): ⚠️ Lỗi awk/grep dọn log"
      mv "$temp_file" "$RESTART_LOG" 2>/dev/null || echo "$(date '+%Y-%m-%d %H:%M:%S'): ⚠️ Lỗi mv temp file"
    fi

    count=$(grep -c -E "^[0-9]+$" "$RESTART_LOG" 2>/dev/null || echo 0)

    alert_msg="<b>🟠 OptimAI Node Dừng – Đang Restart ($((count + 1))/$MAX_RESTARTS)</b>%0A$SERVER_INFO%0AThời gian phát hiện: $(date '+%Y-%m-%d %H:%M:%S')%0A<b>Tip:</b> tail -n 50 /var/log/optimai-node.log"
    send_telegram "$alert_msg"

    echo "$(date '+%Y-%m-%d %H:%M:%S'): ⚠️ Node dừng → restart lần $((count + 1))/$MAX_RESTARTS"
    echo "$now" >> "$RESTART_LOG" || echo "$(date '+%Y-%m-%d %H:%M:%S'): ⚠️ Lỗi ghi restart log"

    if tmux new-session -d -s "$TMUX_SESSION" "$CLI_PATH node start" 2>/dev/null; then
      success_msg="<b>🟢 Restart Thành Công</b>%0A$SERVER_INFO%0ANode đã chạy lại.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
      send_telegram "$success_msg"
      echo "$(date '+%Y-%m-%d %H:%M:%S'): ✅ Restart thành công"
    else
      fail_msg="<b>🔴 Restart Thất Bại</b>%0A$SERVER_INFO%0ANode vẫn dừng – sẽ thử lại chu kỳ sau.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
      send_telegram "$fail_msg"
      echo "$(date '+%Y-%m-%d %H:%M:%S'): ❌ Restart thất bại"
    fi

    if [ "$((count + 1))" -ge "$MAX_RESTARTS" ]; then
      block_msg="<b>🔴 Watchdog BLOCKED – Giới Hạn Restart</b>%0A$SERVER_INFO%0AĐã đạt $MAX_RESTARTS lần trong 10 phút.%0AVui lòng kiểm tra thủ công.%0A%0A<b>Tip:</b> tail -n 50 /var/log/optimai-node.log%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
      send_telegram "$block_msg"
      echo "$(date '+%Y-%m-%d %H:%M:%S'): ⚠️ Đạt giới hạn → tạm dừng restart"
    fi
  fi

  # Gửi thông báo watchdog khởi động chỉ sau kiểm tra đầu tiên thành công (xác nhận script ổn định)
  if [[ -z "${WATCHDOG_STARTED:-}" ]]; then
    startup_msg="<b>🟢 OptimAI Watchdog Khởi Động Thành Công</b>%0A$SERVER_INFO%0AĐang bảo vệ node ổn định – chu kỳ 60 giây.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    send_telegram "$startup_msg"
    export WATCHDOG_STARTED=1
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ✅ Watchdog ổn định – đã gửi thông báo khởi động"
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S'): === KẾT THÚC KIỂM TRA – ngủ 60 giây ==="
  sleep 60
done
EOF

  chmod +x "$WATCHDOG_SCRIPT"
  tmux new-session -d -s "$WATCHDOG_SESSION" "$WATCHDOG_SCRIPT"
  echo "[✓] Watchdog đã bật thành công (phiên bản cải tiến: robust hơn, debug chi tiết, thông báo khởi động chỉ khi ổn định)."
}

stop_watchdog() {
  if tmux has-session -t "$WATCHDOG_SESSION" 2>/dev/null; then
    tmux kill-session -t "$WATCHDOG_SESSION"
    echo "[✓] Đã dừng watchdog."
  else
    echo "[!] Watchdog không chạy."
  fi
}

view_watchdog_logs() {
  if tmux has-session -t "$WATCHDOG_SESSION" 2>/dev/null; then
    echo "👉 Thoát log: Ctrl + b rồi d"
    tmux attach -t "$WATCHDOG_SESSION"
  else
    echo "[!] Watchdog chưa chạy (không có session '$WATCHDOG_SESSION')."
  fi
}

configure_telegram() {
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
}

# ===== Actions =====
install_first_time() {
  echo "=== (1) Cài node lần đầu ==="
  ensure_cli
  install_docker_if_needed
  install_tmux_if_needed
  prefetch_crawler_image
  "$CLI_PATH" auth login

  if start_node_in_tmux; then
    promo_once_after_success
    send_telegram "<b>🟢 Node Cài Đặt & Khởi Động Thành Công</b>%0A$SERVER_INFO%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    print_log_instructions
    ask_and_maybe_open_logs
    start_watchdog
  fi
}

update_node() {
  ensure_cli
  "$CLI_PATH" update
  send_telegram "<b>🔄 Node Đã Cập Nhật</b>%0A$SERVER_INFO%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "[✓] Update xong."
}

check_rewards() {
  ensure_cli
  "$CLI_PATH" rewards balance
}

# ===== Main =====
parse_deploy_args "$@"
load_telegram_config

banner
must_be_root

while true; do
  echo "OptimAI CLI All in One - Tuangg"
  echo "1) Cài đặt node lần đầu (tự động watchdog + Telegram)"
  echo "2) Xem log node (session '$TMUX_SESSION')"
  echo "3) Cập nhật node"
  echo "4) Kiểm tra rewards"
  echo "5) Bật watchdog"
  echo "6) Dừng watchdog"
  echo "7) Xem log watchdog (session '$WATCHDOG_SESSION')"
  echo "8) Cấu hình Telegram"
  echo "0) Thoát"
  echo
  read -r -p "Chọn [0-8]: " choice

  case "$choice" in
    1) install_first_time ;;
    2) view_logs_menu ;;
    3) update_node ;;
    4) check_rewards ;;
    5) start_watchdog ;;
    6) stop_watchdog ;;
    7) view_watchdog_logs ;;
    8) configure_telegram ;;
    0) echo "Tạm biệt! ${PROMO_TEXT}" ; exit 0 ;;
    *) echo "[!] Không hợp lệ." ;;
  esac

  echo
  read -r -p "Nhấn Enter để tiếp tục..."
  clear
  banner
done
