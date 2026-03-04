#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OptimAI CLI All in One - Tuangg
# Version: 1.1.9
#
# Updates:
# v1.1.9:
# - Viết lại hoàn toàn create_watchdog_script():
#   + Fix lỗi heredoc: dùng EOF không quote để biến $CLI_PATH,
#     $TMUX_SESSION được expand đúng khi ghi file watchdog
#   + Watchdog script KHÔNG dùng set -euo pipefail (tránh exit ngầm)
#   + node_running(): strip ANSI codes + trim whitespace trước grep
#   + restart_node(): kill tmux -> sleep 1 -> new-session -> verify
#     retry 3 lần (mỗi lần sleep 10s) tránh false-fail
#   + Chỉ ghi restart_log sau khi xác nhận node thực sự down
#   + Telegram thông báo đầy đủ: restart OK / FAIL / BLOCK
#   + Log mọi action ra /var/log/optimai-watchdog.log (persistent)
# v1.1.8:
#   - Fix watchdog: bỏ set -euo pipefail tránh exit bất ngờ khi check/restart
#   - Fix node_running(): strip ANSI codes, trim whitespace trước khi grep
#   - Tăng verify sleep 3->8s + retry 3 lần khi check node status sau restart
#   - Fix append_restart_log: chỉ tăng count khi restart thực sự thất bại
#   - Fix restart_node(): không dùng `if !` với set -e, dùng biến exit code
# v1.1.7:
#   - Fix start node in tmux: dùng đúng câu lệnh đã test OK
#   - Watchdog check node live theo: optimai-cli node status
#   - Watchdog restart cũng start node bằng bash -lc + verify lại status
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

# ============================================================
# HELPERS - MAIN SCRIPT
# ============================================================

banner() {
  clear
  echo "============================================================"
  echo "        OptimAI CLI All in One - Tuangg (v1.1.9)"
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
  if command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      echo "[*] Node đang chạy trong tmux '$TMUX_SESSION' -> stop session..."
      tmux kill-session -t "$TMUX_SESSION" || true
      echo "[✓] Đã stop tmux session '$TMUX_SESSION'."
    fi
  fi
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
    send_telegram "<b>✅ Reinstall optimai-cli OK</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    return 0
  else
    echo "[!] Reinstall xong nhưng optimai-cli không chạy được."
    return 1
  fi
}

start_node_in_tmux() {
  install_tmux_if_needed

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[*] tmux session '$TMUX_SESSION' đã tồn tại -> kill để start lại."
    tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
    sleep 1
  fi

  echo "[*] Đang start node trong tmux session '$TMUX_SESSION'..."
  tmux new-session -d -s "$TMUX_SESSION" "bash -lc '${CLI_PATH} node start'"

  # verify: retry 3 lần, mỗi lần sleep 5s
  local i
  for i in 1 2 3; do
    sleep 5
    local st
    st="$("$CLI_PATH" node status 2>&1 || true)"
    local clean
    clean="$(printf '%s' "$st" | sed 's/\x1b\[[0-9;]*[mGKHF]//g' | sed 's/^[[:space:]]*//')"
    if echo "$clean" | grep -qiE '^Node running'; then
      echo "[✓] Node đã chạy OK (lần $i): $st"
      echo "    Xem log: tmux attach -t $TMUX_SESSION"
      return 0
    fi
    echo "[~] Chờ node up... lần $i/3. Status: $st"
  done

  echo "[!] Start xong nhưng node chưa chạy sau 3 lần kiểm tra."
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

# ============================================================
# WATCHDOG - VIẾT LẠI HOÀN TOÀN (v1.1.9)
#
# LƯU Ý KỸ THUẬT QUAN TRỌNG:
#   Hàm này dùng heredoc KHÔNG quote (<<EOF thay vì <<'EOF')
#   để các biến $CLI_PATH, $TMUX_SESSION, $TELEGRAM_CONFIG
#   được EXPAND đúng giá trị khi ghi ra file watchdog.
#   Dùng \$ để escape các biến chỉ cần expand lúc watchdog chạy.
# ============================================================

create_watchdog_script() {
  # Ghi watchdog script ra file - dùng EOF (không quote)
  # để $CLI_PATH, $TMUX_SESSION, $TELEGRAM_CONFIG được expand ngay
  # Các biến runtime của watchdog dùng \$ để không bị expand sớm
  cat > "$WATCHDOG_SCRIPT" <<EOF
#!/usr/bin/env bash
# OptimAI Watchdog v1.1.9 - auto-generated
# KHÔNG dùng set -euo pipefail: tránh exit ngầm khi grep/tmux return non-zero

# --- Cấu hình cứng (expand từ script cài đặt) ---
TMUX_SESSION="${TMUX_SESSION}"
CLI_PATH="${CLI_PATH}"
TELEGRAM_CONFIG="${TELEGRAM_CONFIG}"

# --- Cấu hình watchdog ---
MAX_RESTARTS=4         # Số lần restart tối đa trong WINDOW giây
WINDOW=600             # Cửa sổ thời gian tính restart (giây)
VERIFY_SLEEP=10        # Giây chờ sau mỗi lần verify node
VERIFY_RETRIES=3       # Số lần thử verify sau restart

# --- File trạng thái ---
RESTART_LOG="/var/log/optimai-watchdog.log"
BLOCK_STATE="/tmp/optimai-blocked.state"
BLOCK_MARKER="/tmp/optimai-block-notified.marker"

# ---- Utilities ----

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
now() { date +%s; }

log() {
  echo "\$(ts) [watchdog] \$*" | tee -a "\$RESTART_LOG" >&2
}

# Load telegram config nếu có
if [[ -f "\$TELEGRAM_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "\$TELEGRAM_CONFIG" 2>/dev/null || true
fi

# Lấy thông tin server (chạy 1 lần khi khởi động watchdog)
_HOSTNAME=\$(hostname 2>/dev/null || echo "Unknown")
_IP=\$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "Unknown")
SERVER_INFO="Server: <b>\${_HOSTNAME}</b>%0AIP: <code>\${_IP}</code>"

send_telegram() {
  local msg="\$1"
  [[ -z "\${TELEGRAM_BOT_TOKEN:-}" || -z "\${TELEGRAM_CHAT_ID:-}" ]] && return 0
  curl -s --connect-timeout 10 -X POST \\
    "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \\
    -d chat_id="\${TELEGRAM_CHAT_ID}" \\
    -d text="\$msg" \\
    -d parse_mode="HTML" \\
    -d disable_web_page_preview=true >/dev/null 2>&1 || true
}

# ---- Kiểm tra trạng thái node ----

# Strip ANSI escape codes, trim leading whitespace
strip_ansi() {
  sed 's/\x1b\[[0-9;]*[mGKHFJA-Z]//g' | sed 's/^[[:space:]]*//'
}

node_status_raw() {
  "\$CLI_PATH" node status 2>&1 || true
}

node_is_running() {
  local raw clean
  raw="\$(node_status_raw)"
  clean="\$(printf '%s' "\$raw" | strip_ansi)"
  echo "\$clean" | grep -qiE '^Node running'
}

# ---- Quản lý BLOCK (quá nhiều restart) ----

is_blocked() {
  [[ -f "\$BLOCK_STATE" ]] || return 1
  local until_ts
  until_ts="\$(cat "\$BLOCK_STATE" 2>/dev/null || echo 0)"
  if [[ "\$(now)" -lt "\$until_ts" ]]; then
    return 0
  fi
  # Block đã hết hạn -> xóa
  rm -f "\$BLOCK_STATE" "\$BLOCK_MARKER" >/dev/null 2>&1 || true
  return 1
}

set_block() {
  echo "\$(( \$(now) + WINDOW ))" > "\$BLOCK_STATE"
}

notify_block_once() {
  [[ -f "\$BLOCK_MARKER" ]] && return 0
  touch "\$BLOCK_MARKER"
  send_telegram "<b>⛔ Watchdog BLOCK</b>%0A\${SERVER_INFO}%0AQuá \${MAX_RESTARTS} lần restart trong \${WINDOW}s. Tạm dừng để tránh loop.%0AThời gian: \$(ts)"
}

# ---- Đếm restart gần đây ----

count_recent_restarts() {
  local cutoff
  cutoff=\$(( \$(now) - WINDOW ))
  [[ -f "\$RESTART_LOG" ]] || { echo 0; return; }
  # RESTART_LOG format: "<timestamp> RESTART"
  grep -c "RESTART\$" "\$RESTART_LOG" 2>/dev/null | awk -v c="\$cutoff" '
    # Đọc file và đếm dòng có timestamp trong window
    BEGIN { n=0 }
  ' || true
  # Đơn giản hơn: dùng awk trực tiếp
  awk -v c="\$cutoff" '
    /RESTART$/ { if (\$1+0 >= c) n++ }
    END { print n+0 }
  ' "\$RESTART_LOG" 2>/dev/null || echo 0
}

record_restart() {
  echo "\$(now) RESTART" >> "\$RESTART_LOG"
}

# ---- Restart node ----

restart_node() {
  log "Node DOWN -> bắt đầu restart..."

  # Bước 1: Kill tmux session cũ nếu còn
  if tmux has-session -t "\$TMUX_SESSION" 2>/dev/null; then
    log "Kill tmux session cũ: \$TMUX_SESSION"
    tmux kill-session -t "\$TMUX_SESSION" >/dev/null 2>&1 || true
    sleep 2
  fi

  # Bước 2: Tạo tmux session mới chạy node
  log "Tạo tmux session mới và start node..."
  tmux new-session -d -s "\$TMUX_SESSION" "bash -lc '\${CLI_PATH} node start'"
  local exit_code=\$?

  if [[ \$exit_code -ne 0 ]]; then
    log "LỖI: tmux new-session thất bại (exit \$exit_code)"
    send_telegram "<b>❌ Watchdog Restart FAIL</b>%0A\${SERVER_INFO}%0Atmux new-session lỗi (exit \${exit_code})%0AThời gian: \$(ts)"
    return 1
  fi

  # Bước 3: Verify node đã up - retry VERIFY_RETRIES lần
  log "Đang verify node... (tối đa \${VERIFY_RETRIES} lần, mỗi lần chờ \${VERIFY_SLEEP}s)"
  local i raw clean
  for (( i=1; i<=VERIFY_RETRIES; i++ )); do
    sleep "\$VERIFY_SLEEP"
    raw="\$(node_status_raw)"
    clean="\$(printf '%s' "\$raw" | strip_ansi)"
    if echo "\$clean" | grep -qiE '^Node running'; then
      log "Restart THÀNH CÔNG (lần verify \$i/\${VERIFY_RETRIES}). Status: \$raw"
      return 0
    fi
    log "Verify \$i/\${VERIFY_RETRIES}: node chưa up. Status: \$raw"
  done

  # Thất bại sau tất cả retries
  log "LỖI: Node vẫn không up sau \${VERIFY_RETRIES} lần verify."
  send_telegram "<b>❌ Watchdog Restart FAIL</b>%0A\${SERVER_INFO}%0ANode vẫn DOWN sau \${VERIFY_RETRIES} lần verify.%0AStatus: <code>\$(printf '%s' "\$raw" | head -n 2 | tr '\n' ' ')</code>%0AThời gian: \$(ts)"
  return 1
}

# ---- Main ----

main() {
  # Kiểm tra dependencies
  if ! command -v tmux >/dev/null 2>&1; then
    log "LỖI: tmux không tìm thấy. Bỏ qua."
    exit 0
  fi
  if [[ ! -x "\$CLI_PATH" ]]; then
    log "LỖI: \$CLI_PATH không tồn tại hoặc không executable. Bỏ qua."
    exit 0
  fi

  # Xóa block marker nếu block đã hết hạn
  if ! is_blocked; then
    rm -f "\$BLOCK_MARKER" >/dev/null 2>&1 || true
  fi

  # Nếu đang bị block -> skip, notify 1 lần
  if is_blocked; then
    log "BLOCKED - bỏ qua restart"
    notify_block_once
    exit 0
  fi

  # Kiểm tra node có đang chạy không
  if node_is_running; then
    log "OK - node đang chạy bình thường"
    exit 0
  fi

  # Node DOWN -> kiểm tra ngưỡng restart
  local count
  count="\$(count_recent_restarts)"
  log "Node DOWN. Số restart trong \${WINDOW}s: \${count}/\${MAX_RESTARTS}"

  if [[ \$count -ge \$MAX_RESTARTS ]]; then
    set_block
    log "Đã đạt ngưỡng restart (\${count}/\${MAX_RESTARTS}) -> BLOCK trong \${WINDOW}s"
    send_telegram "<b>⛔ Watchdog BLOCK</b>%0A\${SERVER_INFO}%0AĐạt ngưỡng \${MAX_RESTARTS} restarts trong \${WINDOW}s. Tạm dừng.%0AThời gian: \$(ts)"
    exit 0
  fi

  # Ghi log restart và thực hiện restart
  record_restart
  local new_count=\$(( count + 1 ))

  if restart_node; then
    log "Restart #\${new_count} THÀNH CÔNG"
    send_telegram "<b>♻️ Node Tự Restart</b>%0A\${SERVER_INFO}%0ANode bị DOWN và đã được khởi động lại thành công.%0ARestart lần: \${new_count}/\${MAX_RESTARTS} (trong \${WINDOW}s)%0AThời gian: \$(ts)"
  else
    log "Restart #\${new_count} THẤT BẠI"
    # Telegram đã gửi trong restart_node() khi fail
  fi

  exit 0
}

main
EOF

  chmod +x "$WATCHDOG_SCRIPT"
  echo "[✓] Đã tạo watchdog script: $WATCHDOG_SCRIPT"
}

# ============================================================
# SYSTEMD UNIT
# ============================================================

create_systemd_unit() {
  # Service unit
  cat > "/etc/systemd/system/$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=OptimAI Watchdog - check & restart node (tmux: $TMUX_SESSION)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$WATCHDOG_SCRIPT
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  # Timer unit - chạy mỗi 30 giây
  cat > "/etc/systemd/system/${WATCHDOG_SERVICE}.timer" <<EOF
[Unit]
Description=OptimAI Watchdog Timer (every 30s)

[Timer]
OnBootSec=30
OnUnitActiveSec=30
Unit=$WATCHDOG_SERVICE
AccuracySec=5

[Install]
WantedBy=timers.target
EOF
}

# ============================================================
# WATCHDOG MANAGEMENT
# ============================================================

start_watchdog() {
  echo "=== (5) Start Watchdog Service ==="
  create_watchdog_script
  create_systemd_unit
  systemctl daemon-reload
  systemctl enable --now "${WATCHDOG_SERVICE}.timer"
  echo "[✓] Watchdog đã start (timer chạy mỗi 30s)."
  echo "    Xem log: journalctl -u $WATCHDOG_SERVICE -f"
  echo "    Xem log file: tail -f /var/log/optimai-watchdog.log"
  send_telegram "<b>🛡️ Watchdog Đã Start</b>%0A${SERVER_INFO}%0AKiểm tra node mỗi 30 giây.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

stop_watchdog() {
  echo "=== (6) Stop Watchdog Service ==="
  systemctl disable --now "${WATCHDOG_SERVICE}.timer" >/dev/null 2>&1 || true
  echo "[✓] Watchdog đã stop."
  send_telegram "<b>🛑 Watchdog Đã Stop</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

status_watchdog() {
  echo "=== (7) Status Watchdog Service ==="
  echo "--- Timer ---"
  systemctl status "${WATCHDOG_SERVICE}.timer" --no-pager || true
  echo
  echo "--- Service (lần chạy gần nhất) ---"
  systemctl status "${WATCHDOG_SERVICE}" --no-pager || true
  echo
  echo "--- Log gần nhất (/var/log/optimai-watchdog.log) ---"
  if [[ -f /var/log/optimai-watchdog.log ]]; then
    tail -n 20 /var/log/optimai-watchdog.log
  else
    echo "(chưa có log)"
  fi
  echo
}

uninstall_watchdog() {
  echo "=== (9) Uninstall Watchdog Service ==="
  systemctl disable --now "${WATCHDOG_SERVICE}.timer" >/dev/null 2>&1 || true
  systemctl disable --now "${WATCHDOG_SERVICE}"       >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${WATCHDOG_SERVICE}"
  rm -f "/etc/systemd/system/${WATCHDOG_SERVICE}.timer"
  rm -f "$WATCHDOG_SCRIPT"
  systemctl daemon-reload
  echo "[✓] Đã gỡ watchdog service/unit."
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
# NODE MANAGEMENT
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

update_node() {
  echo "=== (3) Cập nhật node ==="
  ensure_cli
  if "$CLI_PATH" update; then
    echo "[✓] Update xong."
    send_telegram "<b>🔄 Node Đã Cập Nhật</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  else
    echo "[!] optimai-cli update bị lỗi."
    echo "    -> Hãy chọn menu 10 để Reinstall optimai-cli (xóa + tải lại bản mới)."
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
  echo "OptimAI CLI All in One - Tuangg - Version 1.1.9"
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
    0)  echo "Bye!"; exit 0 ;;
    *)  echo "[!] Lựa chọn không hợp lệ." ;;
  esac
done
