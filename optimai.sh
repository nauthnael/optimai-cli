#!/usr/bin/env bash
set -euo pipefail
set +H  # Tắt history expansion: tránh lỗi "event not found" với ký tự ! trong password

# ============================================================
# OptimAI CLI All in One - Tuangg
# Version: 1.1.14
#
# Updates:
# v1.1.14:
#   - Fix auto_login(): tách expect thành 3 giai đoạn rõ ràng
#     + Giai đoạn 1: chờ prompt Email → gửi email
#     + Giai đoạn 2: chờ prompt Password → gửi password
#     + Giai đoạn 3: chờ kết quả, chấp nhận EOF (CLI thoát ngay sau login)
#     + Bỏ exp_continue sau send password (gây timeout vì loop chờ pattern)
#     + Xác nhận thành công bằng auth status thay vì parse text output
#     + Thêm --force để bỏ qua "Already logged in"
#   - Watchdog (Phương án A): bỏ check auth status mỗi chu kỳ
#     + Chỉ check auth khi node DOWN, ngay trước khi restart
#     + Giảm tải server: không còn gọi auth status mỗi 60s
#     + Logic: tmux down → check auth → re-login nếu cần → restart
#   - watchdog_auto_login(): áp dụng cùng fix 3 giai đoạn
# v1.1.13:
#   - Fix save_credentials(): bỏ printf '%q', dùng single-quote wrapping
#     + escape dấu ' bên trong → source lại chính xác 100% mọi ký tự
#   - Fix get_email() / get_password(): bỏ echo, dùng printf -v để gán
#     biến trực tiếp không qua subshell $() → tránh mất ký tự đặc biệt
#   - Refactor auto_login(): nhận email/pass trực tiếp từ biến, không
#     qua subshell trung gian
#   - Watchdog load_credentials(): hưởng lợi tự động từ fix save_credentials
# v1.1.12:
#   - Thêm credentials.conf (chmod 600): lưu email/password bảo mật
#   - Ưu tiên credentials: --email/--password > credentials.conf > hỏi tay
#   - Menu 12: Lưu/cập nhật credentials + test login ngay
#   - --email/--password tự động lưu vào credentials.conf
#   - Watchdog nâng cấp:
#     + Mỗi chu kỳ kiểm tra auth status trước (optimai-cli auth status)
#     + "Not authenticated" → tự động re-login từ credentials.conf
#     + Re-login OK → reset restart counter → start node
#     + Re-login FAIL (không có credentials) → Telegram cảnh báo, skip
#     + Phân biệt Telegram: auth expire vs node crash thông thường
# v1.1.11:
#   - Thêm auto_login() dùng expect
#   - Hỗ trợ --email= và --password=
#   - Menu 11: Re-login node thủ công
# v1.1.10:
#   - Watchdog kiến trúc v1.1.4: Type=simple + while true
#   - Check node bằng tmux has-session
#   - awk thuần tránh grep exit 1
#   - trap EXIT cảnh báo Telegram
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

OPTIMAI_CONFIG_DIR="/etc/optimai"
TELEGRAM_CONFIG="${OPTIMAI_CONFIG_DIR}/telegram.conf"
CREDENTIALS_CONFIG="${OPTIMAI_CONFIG_DIR}/credentials.conf"
SERVER_INFO=""

ARG_BOT_TOKEN=""
ARG_CHAT_ID=""
ARG_EMAIL=""
ARG_PASSWORD=""

# ============================================================
# BANNER & UTILS
# ============================================================

banner() {
  clear
  echo "============================================================"
  echo "        OptimAI CLI All in One - Tuangg (v1.1.14)"
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
      --email=*)     ARG_EMAIL="${1#*=}";     shift ;;
      --email)       ARG_EMAIL="${2:-}";      shift 2 ;;
      --password=*)  ARG_PASSWORD="${1#*=}";  shift ;;
      --password)    ARG_PASSWORD="${2:-}";   shift 2 ;;
      --bot-token=*) ARG_BOT_TOKEN="${1#*=}"; shift ;;
      --bot-token)   ARG_BOT_TOKEN="${2:-}";  shift 2 ;;
      --chat-id=*)   ARG_CHAT_ID="${1#*=}";   shift ;;
      --chat-id)     ARG_CHAT_ID="${2:-}";    shift 2 ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  sudo ./optimai.sh [OPTIONS]

Options:
  --email=EMAIL          Email OptimAI (tự động lưu vào credentials)
  --password=PASSWORD    Password OptimAI (tự động lưu vào credentials)
                         Lưu ý: dùng single quotes nếu password có ký tự đặc biệt
                         Ví dụ: --password='My!Pass@#2024'
  --bot-token=TOKEN      Telegram bot token
  --chat-id=CHAT_ID      Telegram chat ID

Examples:
  sudo ./optimai.sh --email=you@mail.com --password='MyPass!@#'
  sudo ./optimai.sh --email=you@mail.com --password='MyPass!@#' --bot-token=123:ABC --chat-id=987
USAGE
        exit 0 ;;
      *) shift ;;
    esac
  done
}

apply_telegram_args_if_provided() {
  if [[ -n "${ARG_BOT_TOKEN:-}" && -n "${ARG_CHAT_ID:-}" ]]; then
    mkdir -p "$OPTIMAI_CONFIG_DIR"
    cat <<EOF > "$TELEGRAM_CONFIG"
TELEGRAM_BOT_TOKEN="$ARG_BOT_TOKEN"
TELEGRAM_CHAT_ID="$ARG_CHAT_ID"
EOF
    chmod 600 "$TELEGRAM_CONFIG"
    echo "[✓] Đã lưu Telegram config: $TELEGRAM_CONFIG"
  elif [[ -n "${ARG_BOT_TOKEN:-}" || -n "${ARG_CHAT_ID:-}" ]]; then
    echo "[!] Cần truyền đủ cả --bot-token và --chat-id."
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
# CREDENTIALS MANAGEMENT (v1.1.12)
# Lưu email/password tại /etc/optimai/credentials.conf (chmod 600)
# ============================================================

save_credentials() {
  local email="$1"
  local password="$2"
  mkdir -p "$OPTIMAI_CONFIG_DIR"
  # Dùng single-quote wrapping + escape dấu ' bên trong bằng '\''
  # Đây là cách duy nhất source lại chính xác với MỌI ký tự đặc biệt:
  # !, @, #, $, ", \, backtick, space, dấu =, v.v.
  local email_escaped password_escaped
  email_escaped="${email//\'/\'\\\'\'}"
  password_escaped="${password//\'/\'\\\'\'}"
  printf "OPTIMAI_EMAIL='%s'\nOPTIMAI_PASSWORD='%s'\n" \
    "$email_escaped" \
    "$password_escaped" \
    > "$CREDENTIALS_CONFIG"
  chmod 600 "$CREDENTIALS_CONFIG"
}

load_credentials() {
  # Trả về 0 nếu load được, 1 nếu không có file
  if [[ ! -f "$CREDENTIALS_CONFIG" ]]; then
    return 1
  fi
  # shellcheck disable=SC1090
  source "$CREDENTIALS_CONFIG" 2>/dev/null || return 1
  if [[ -z "${OPTIMAI_EMAIL:-}" || -z "${OPTIMAI_PASSWORD:-}" ]]; then
    return 1
  fi
  return 0
}

# resolve_credentials VAR_EMAIL VAR_PASSWORD
# Gán email/password vào 2 biến được chỉ định, KHÔNG qua subshell $()
# → tránh subshell strip trailing newline và các vấn đề ký tự đặc biệt
resolve_credentials() {
  local _evar="$1"
  local _pvar="$2"
  local _src_email="" _src_pass=""

  if [[ -n "${ARG_EMAIL:-}" ]]; then
    _src_email="$ARG_EMAIL"
    _src_pass="${ARG_PASSWORD:-}"
  elif [[ -f "$CREDENTIALS_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CREDENTIALS_CONFIG" 2>/dev/null || true
    _src_email="${OPTIMAI_EMAIL:-}"
    _src_pass="${OPTIMAI_PASSWORD:-}"
  fi

  printf -v "$_evar" '%s' "$_src_email"
  printf -v "$_pvar"  '%s' "$_src_pass"
}

configure_credentials() {
  echo
  echo "=== (12) Lưu credentials OptimAI ==="

  local email password

  # Hiển thị trạng thái hiện tại
  if load_credentials; then
    echo "[i] Đang lưu account: $OPTIMAI_EMAIL"
    echo "[i] Password: (đã lưu)"
    echo
  fi

  read -r    -p "Email OptimAI: " email
  read -r -s -p "Password     : " password
  echo

  if [[ -z "$email" || -z "$password" ]]; then
    echo "[!] Không được để trống."
    return 1
  fi

  save_credentials "$email" "$password"
  echo "[✓] Đã lưu credentials: $CREDENTIALS_CONFIG (chmod 600)"

  # Test login ngay
  echo
  echo "[*] Test login ngay để xác nhận..."
  if auto_login "$email" "$password"; then
    send_telegram "<b>🔑 Credentials Đã Lưu & Login OK</b>%0A${SERVER_INFO}%0AAccount: ${email}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "[✓] Credentials hợp lệ và đã lưu."
  else
    echo "[!] Login thất bại — đã lưu credentials nhưng kiểm tra lại email/password."
  fi
  echo
}

# Tự động lưu nếu truyền qua --email/--password
apply_credentials_args_if_provided() {
  if [[ -n "${ARG_EMAIL:-}" && -n "${ARG_PASSWORD:-}" ]]; then
    save_credentials "$ARG_EMAIL" "$ARG_PASSWORD"
    echo "[✓] Đã lưu credentials từ tham số dòng lệnh."
  fi
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

install_expect_if_needed() {
  if command -v expect >/dev/null 2>&1; then return 0; fi
  echo "[*] Cài expect..."
  apt-get install -y expect -qq >/dev/null 2>&1
  echo "[✓] expect đã cài."
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
  if command -v tmux >/dev/null 2>&1; then
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      echo "[*] Kill tmux session '$TMUX_SESSION' trước khi reinstall..."
      tmux kill-session -t "$TMUX_SESSION" || true
      echo "[✓] Đã stop tmux session."
    fi
  fi
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
# AUTO LOGIN
# Truyền email/password qua env var → expect đọc $env(...)
# An toàn với mọi ký tự đặc biệt: !, @, #, $, ", \, backtick
# ============================================================

auto_login() {
  local email="$1"
  local password="$2"

  install_expect_if_needed

  echo "[*] Auto login: $email"

  # Dùng --force để bỏ qua "Already logged in" nếu session cũ còn đó
  # Tách 3 giai đoạn rõ ràng, KHÔNG dùng exp_continue sau send password:
  #   Giai đoạn 1: chờ prompt Email  → gửi email
  #   Giai đoạn 2: chờ prompt Pass   → gửi password
  #   Giai đoạn 3: chờ kết quả/EOF   → CLI thoát ngay sau login, EOF là bình thường
  # Xác nhận thành công bằng auth status, không parse text output
  local output rc
  output=$(EXPECT_EMAIL="$email" EXPECT_PASSWORD="$password" \
    expect -c '
      log_user 1
      set timeout 30
      set email    $env(EXPECT_EMAIL)
      set password $env(EXPECT_PASSWORD)
      spawn '"${CLI_PATH}"' auth login --legacy --force

      # Giai đoạn 1: chờ prompt Email
      expect {
        -re {(?i)(email|e-mail|username|login)} { send "$email\r" }
        timeout { puts "TIMEOUT_EMAIL"; exit 1 }
        eof     { puts "EOF_EMAIL";    exit 1 }
      }

      # Giai đoạn 2: chờ prompt Password
      expect {
        -re {(?i)(password|pass)} { send "$password\r" }
        timeout { puts "TIMEOUT_PASSWORD"; exit 1 }
        eof     { puts "EOF_PASSWORD"; exit 1 }
      }

      # Giai đoạn 3: chờ kết quả
      # CLI thoát ngay sau khi in kết quả → EOF là bình thường
      expect {
        -re {(?i)(signed in|success|logged in|welcome)} { }
        timeout { puts "TIMEOUT_RESULT"; exit 1 }
        eof     { }
      }
    ' 2>&1)
  rc=$?

  echo "$output"

  if [[ $rc -ne 0 ]]; then
    echo "[!] Auto login thất bại (exit $rc)."
    return 1
  fi

  # Xác nhận bằng auth status — đáng tin hơn parse text output
  local status_out
  status_out=$("${CLI_PATH}" auth status 2>&1 || true)
  if echo "$status_out" | grep -qi "Logged in"; then
    echo "[✓] Login thành công — auth status: $status_out"
    return 0
  else
    echo "[!] Login thất bại — auth status: $status_out"
    return 1
  fi
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
  local i
  for i in 1 2 3; do
    sleep 5
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      echo "[✓] Node đã chạy OK (lần $i). Xem log: tmux attach -t $TMUX_SESSION"
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
    echo "[!] optimai-cli update bị lỗi. Chọn menu 10 để Reinstall."
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
# RE-LOGIN (thủ công từ menu)
# ============================================================

relogin_node() {
  echo "=== (11) Re-login node ==="
  ensure_cli

  local email password
  resolve_credentials email password

  # Nếu không có credentials thì hỏi tay
  if [[ -z "$email" ]]; then
    read -r    -p "Email OptimAI: " email
  fi
  if [[ -z "$password" ]]; then
    read -r -s -p "Password     : " password
    echo
  fi

  if [[ -z "$email" || -z "$password" ]]; then
    echo "[!] Email và password không được để trống."
    return 1
  fi

  echo "[*] Tạm stop watchdog trong khi re-login..."
  systemctl stop "$WATCHDOG_SERVICE" 2>/dev/null || true

  if auto_login "$email" "$password"; then
    echo
    echo "[*] Restart node sau khi login..."
    if start_node_in_tmux; then
      send_telegram "<b>🔑 Re-login & Restart Thành Công</b>%0A${SERVER_INFO}%0AAccount: ${email}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    else
      send_telegram "<b>⚠️ Re-login OK nhưng Node Start Lỗi</b>%0A${SERVER_INFO}%0AChạy: tmux attach -t ${TMUX_SESSION}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    fi
  else
    echo "[!] Login thất bại."
    send_telegram "<b>❌ Re-login Thất Bại</b>%0A${SERVER_INFO}%0AKiểm tra credentials (menu 12).%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  fi

  echo "[*] Khởi động lại watchdog..."
  systemctl start "$WATCHDOG_SERVICE" 2>/dev/null || true
  echo
}

# ============================================================
# WATCHDOG (v1.1.14)
# Kiến trúc: Type=simple + while true (từ v1.1.4)
# Phương án A: chỉ check auth khi node DOWN (không gọi mỗi 60s)
# Fix expect: 3 giai đoạn rõ ràng + --force + xác nhận bằng auth status
# ============================================================

create_watchdog_script() {
  cat <<'WATCHDOG_EOF' > "$WATCHDOG_SCRIPT"
#!/usr/bin/env bash
# OptimAI Watchdog v1.1.14
# KHÔNG dùng set -euo pipefail: tránh exit ngầm khi grep/awk return non-zero

# ---- Cấu hình cứng (hardcode, không expand từ outer script) ----
TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"
TELEGRAM_CONFIG="/etc/optimai/telegram.conf"
CREDENTIALS_CONFIG="/etc/optimai/credentials.conf"
RESTART_LOG="/var/log/optimai-watchdog.log"
BLOCK_STATE="/tmp/optimai-blocked.state"

MAX_RESTARTS=4    # Số restart tối đa trong WINDOW giây
WINDOW=600        # 10 phút
SLEEP_INTERVAL=60

# ============================================================
# UTILS
# ============================================================

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) [watchdog] $*" | tee -a "$RESTART_LOG"; }

# ---- Load Telegram config ----
if [[ -f "$TELEGRAM_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$TELEGRAM_CONFIG" 2>/dev/null || true
fi

get_server_info() {
  local h ip
  h=$(hostname 2>/dev/null || echo "Unknown")
  ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "Unknown")
  echo "Server: <b>$h</b>%0AIP: <code>$ip</code>"
}
SERVER_INFO="$(get_server_info)"

send_telegram() {
  local msg="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    return 0
  fi
  curl -s --connect-timeout 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="$msg" \
    -d parse_mode="HTML" \
    -d disable_web_page_preview=true >/dev/null 2>&1 || true
}

# ---- trap: cảnh báo Telegram nếu watchdog chết bất ngờ ----
trap '
  code=$?
  set +e
  if [[ $code -ne 0 ]]; then
    send_telegram "<b>🔴 Watchdog Chết Bất Ngờ</b>%0A'"$SERVER_INFO"'%0AExit: ${code}%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")%0AKiểm tra: journalctl -u optimai-watchdog.service -n 50"
    log "DIE exit_code=$code"
  fi
  exit $code
' EXIT

# ============================================================
# AUTH CHECK & AUTO LOGIN
# ============================================================

check_auth_status() {
  # Trả về 0 nếu đã login, 1 nếu chưa
  local out
  out=$("$CLI_PATH" auth status 2>&1 || true)
  if echo "$out" | grep -qi "Logged in"; then
    return 0
  fi
  return 1
}

load_credentials() {
  # Trả về 0 nếu load được credentials
  if [[ ! -f "$CREDENTIALS_CONFIG" ]]; then
    return 1
  fi
  # shellcheck disable=SC1090
  source "$CREDENTIALS_CONFIG" 2>/dev/null || return 1
  if [[ -z "${OPTIMAI_EMAIL:-}" || -z "${OPTIMAI_PASSWORD:-}" ]]; then
    return 1
  fi
  return 0
}

watchdog_auto_login() {
  # Tách 3 giai đoạn, thêm --force, xác nhận bằng auth status
  if ! command -v expect >/dev/null 2>&1; then
    log "WARN: expect chưa cài, bỏ qua auto login"
    return 1
  fi

  local output rc
  output=$(EXPECT_EMAIL="$OPTIMAI_EMAIL" EXPECT_PASSWORD="$OPTIMAI_PASSWORD" \
    expect -c '
      log_user 0
      set timeout 30
      set email    $env(EXPECT_EMAIL)
      set password $env(EXPECT_PASSWORD)
      spawn '"$CLI_PATH"' auth login --legacy --force

      # Giai đoạn 1: chờ prompt Email
      expect {
        -re {(?i)(email|e-mail|username|login)} { send "$email\r" }
        timeout { puts "TIMEOUT_EMAIL"; exit 1 }
        eof     { puts "EOF_EMAIL";    exit 1 }
      }

      # Giai đoạn 2: chờ prompt Password
      expect {
        -re {(?i)(password|pass)} { send "$password\r" }
        timeout { puts "TIMEOUT_PASSWORD"; exit 1 }
        eof     { puts "EOF_PASSWORD"; exit 1 }
      }

      # Giai đoạn 3: chờ kết quả / EOF
      expect {
        -re {(?i)(signed in|success|logged in|welcome)} { }
        timeout { puts "TIMEOUT_RESULT"; exit 1 }
        eof     { }
      }
    ' 2>&1)
  rc=$?

  if [[ $rc -ne 0 ]]; then
    log "AUTH: expect exit $rc — output: $output"
    return 1
  fi

  # Xác nhận bằng auth status
  local status_out
  status_out=$("$CLI_PATH" auth status 2>&1 || true)
  if echo "$status_out" | grep -qi "Logged in"; then
    log "AUTH: Xác nhận auth status OK"
    return 0
  else
    log "AUTH: auth status sau login: $status_out"
    return 1
  fi
}

# ============================================================
# RESTART LOG / BLOCK LOGIC
# ============================================================

now_ts() { date +%s; }

clean_and_count_restarts() {
  local now cutoff tmp_log count
  now=$(now_ts)
  cutoff=$((now - WINDOW))
  tmp_log="$(mktemp)" || { echo 0; return; }
  awk -v c="$cutoff" '($1 ~ /^[0-9]+$/) && ($1 > c) {print}' \
    "$RESTART_LOG" 2>/dev/null > "$tmp_log" || true
  mv "$tmp_log" "$RESTART_LOG" 2>/dev/null || true
  count=$(awk '($1 ~ /^[0-9]+$/){n++} END{print n+0}' "$RESTART_LOG" 2>/dev/null || echo 0)
  echo "$count"
}

reset_restart_log() {
  # Xóa restart log sau khi re-login thành công (auth expire không phải crash)
  true > "$RESTART_LOG" 2>/dev/null || true
  rm -f "$BLOCK_STATE" 2>/dev/null || true
  log "Restart log đã reset sau re-login thành công"
}

# ============================================================
# MAIN LOOP
# ============================================================

touch "$RESTART_LOG" 2>/dev/null || true
log "=== WATCHDOG STARTED ==="
send_telegram "<b>🛡️ OptimAI Watchdog Khởi Động</b>%0A${SERVER_INFO}%0AKiểm tra node mỗi ${SLEEP_INTERVAL}s.%0AThời gian: $(ts)"

while true; do
  log "=== CHECK START ==="

  # ----------------------------------------------------------
  # BƯỚC 1: Kiểm tra node có đang chạy không
  # (Phương án A: KHÔNG check auth mỗi chu kỳ — giảm tải server)
  # ----------------------------------------------------------
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "NODE: OK - tmux session '$TMUX_SESSION' alive"
    log "=== CHECK END - sleep ${SLEEP_INTERVAL}s ==="
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  # ----------------------------------------------------------
  # BƯỚC 2: Node DOWN → check auth trước khi restart
  # Chỉ gọi auth status khi cần, không gọi mỗi 60s
  # ----------------------------------------------------------
  log "NODE: DOWN - tmux session '$TMUX_SESSION' không tìm thấy"
  log "AUTH: Kiểm tra trạng thái đăng nhập..."

  if ! check_auth_status; then
    log "AUTH: Not authenticated — bắt đầu re-login..."

    if load_credentials; then
      log "AUTH: Tìm thấy credentials ($OPTIMAI_EMAIL), đang re-login..."
      send_telegram "<b>🔑 Auth Hết Hạn - Đang Re-login</b>%0A${SERVER_INFO}%0AAccount: ${OPTIMAI_EMAIL}%0AThời gian: $(ts)"

      if watchdog_auto_login; then
        log "AUTH: Re-login thành công ($OPTIMAI_EMAIL)"
        send_telegram "<b>✅ Re-login Thành Công</b>%0A${SERVER_INFO}%0AAccount: ${OPTIMAI_EMAIL}%0AThời gian: $(ts)"
        # Reset restart counter: node tắt vì auth expire, không phải crash
        reset_restart_log
        # Tiếp tục xuống để restart node
      else
        log "AUTH: Re-login THẤT BẠI ($OPTIMAI_EMAIL)"
        send_telegram "<b>❌ Re-login Thất Bại</b>%0A${SERVER_INFO}%0AAccount: ${OPTIMAI_EMAIL}%0AKiểm tra credentials (menu 12).%0AThời gian: $(ts)"
        log "=== CHECK END (auth fail) - sleep ${SLEEP_INTERVAL}s ==="
        sleep "$SLEEP_INTERVAL"
        continue
      fi
    else
      log "AUTH: Không có credentials — không thể tự re-login"
      send_telegram "<b>⚠️ Auth Hết Hạn - Không Có Credentials</b>%0A${SERVER_INFO}%0AChạy menu 12 để lưu credentials.%0AThời gian: $(ts)"
      log "=== CHECK END (no credentials) - sleep ${SLEEP_INTERVAL}s ==="
      sleep "$SLEEP_INTERVAL"
      continue
    fi
  else
    log "AUTH: OK - đã đăng nhập"
  fi

  # ----------------------------------------------------------
  # BƯỚC 3: Thực hiện restart node (với block logic)
  # ----------------------------------------------------------
  local_now=$(now_ts)
  count=$(clean_and_count_restarts)
  log "NODE: Restart count trong ${WINDOW}s: ${count}/${MAX_RESTARTS}"

  # HARD BLOCK: quá nhiều restart
  if [[ "$count" -ge "$MAX_RESTARTS" ]]; then
    oldest=$(awk '($1 ~ /^[0-9]+$/){print $1; exit}' "$RESTART_LOG" 2>/dev/null || echo "$local_now")
    unblock_at=$((oldest + WINDOW))
    wait_sec=$((unblock_at - local_now + 1))
    [[ "$wait_sec" -lt "$SLEEP_INTERVAL" ]] && wait_sec=$SLEEP_INTERVAL

    last_unblock=0
    [[ -f "$BLOCK_STATE" ]] && last_unblock=$(cat "$BLOCK_STATE" 2>/dev/null || echo 0)

    if [[ "$last_unblock" -ne "$unblock_at" ]]; then
      echo "$unblock_at" > "$BLOCK_STATE" 2>/dev/null || true
      send_telegram "<b>⛔ Watchdog BLOCKED</b>%0A${SERVER_INFO}%0ANode crash liên tục: ${count}/${MAX_RESTARTS} lần trong ${WINDOW}s.%0ATạm dừng restart để tránh loop.%0AThời gian: $(ts)"
      log "NODE: BLOCKED (${count}/${MAX_RESTARTS}) - gửi Telegram, đợi ${wait_sec}s"
    else
      log "NODE: BLOCKED (${count}/${MAX_RESTARTS}) - đã cảnh báo, đợi ${wait_sec}s"
    fi

    sleep "$wait_sec"
    continue
  fi

  # Thực hiện restart
  echo "$local_now" >> "$RESTART_LOG"
  send_telegram "<b>🟠 Node DOWN - Đang Restart ($((count + 1))/${MAX_RESTARTS})</b>%0A${SERVER_INFO}%0AThời gian: $(ts)"
  log "NODE: Restart lần $((count + 1))/${MAX_RESTARTS}..."

  tmux new-session -d -s "$TMUX_SESSION" "bash -lc '${CLI_PATH} node start'" 2>/dev/null
  restart_exit=$?

  if [[ $restart_exit -eq 0 ]]; then
    sleep 10
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      log "NODE: RESTART OK - session alive"
      send_telegram "<b>🟢 Restart Thành Công ($((count + 1))/${MAX_RESTARTS})</b>%0A${SERVER_INFO}%0AThời gian: $(ts)"
    else
      log "NODE: WARN - session chết ngay sau restart"
      send_telegram "<b>🔴 Restart Thất Bại - Session Chết Ngay</b>%0A${SERVER_INFO}%0AKiểm tra: tmux attach -t ${TMUX_SESSION}%0AThời gian: $(ts)"
    fi
  else
    log "NODE: ERROR - tmux new-session thất bại (exit ${restart_exit})"
    send_telegram "<b>🔴 Restart Thất Bại</b>%0A${SERVER_INFO}%0Atmux lỗi (exit ${restart_exit})%0AThời gian: $(ts)"
  fi

  log "=== CHECK END - sleep ${SLEEP_INTERVAL}s ==="
  sleep "$SLEEP_INTERVAL"
done
WATCHDOG_EOF

  chmod +x "$WATCHDOG_SCRIPT"
  echo "[✓] Đã tạo watchdog script: $WATCHDOG_SCRIPT"
}

create_watchdog_service() {
  cat <<EOF > "/etc/systemd/system/$WATCHDOG_SERVICE"
[Unit]
Description=OptimAI Watchdog v1.1.14 - Tuangg (tmux: $TMUX_SESSION)
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
  echo "[✓] Watchdog đã start và enable."
  echo "    Xem log live  : journalctl -u $WATCHDOG_SERVICE -f"
  echo "    Xem log file  : tail -f /var/log/optimai-watchdog.log"
  send_telegram "<b>🛡️ Watchdog Đã Start</b>%0A${SERVER_INFO}%0AKiểm tra node + auth mỗi 60 giây.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

stop_watchdog() {
  echo "=== (6) Stop Watchdog Service ==="
  systemctl stop    "$WATCHDOG_SERVICE" 2>/dev/null || true
  systemctl disable "$WATCHDOG_SERVICE" 2>/dev/null || true
  echo "[✓] Watchdog đã stop & disable."
  send_telegram "<b>🛑 Watchdog Đã Stop</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

status_watchdog() {
  echo "=== (7) Status Watchdog Service ==="
  systemctl status "$WATCHDOG_SERVICE" --no-pager || true
  echo
  # Hiện thị auth status hiện tại
  echo "--- Auth status hiện tại ---"
  if [[ -x "$CLI_PATH" ]]; then
    "$CLI_PATH" auth status 2>&1 || true
  fi
  echo
  echo "--- Credentials đã lưu ---"
  if load_credentials 2>/dev/null; then
    echo "Account: $OPTIMAI_EMAIL (password: đã lưu)"
  else
    echo "(chưa có credentials — chọn menu 12 để lưu)"
  fi
  echo
  echo "--- Log gần nhất ---"
  if [[ -f /var/log/optimai-watchdog.log ]]; then
    tail -n 25 /var/log/optimai-watchdog.log
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
  echo "[✓] Đã uninstall watchdog."
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
  read -r -p "Chat ID  : " chat_id
  if [[ -z "$bot_token" || -z "$chat_id" ]]; then
    echo "[!] Không được để trống."
    return
  fi
  mkdir -p "$OPTIMAI_CONFIG_DIR"
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

  local email password
  resolve_credentials email password

  if [[ -n "$email" && -n "$password" ]]; then
    echo "[*] Dùng credentials đã có (${email})..."
    # Lưu lại nếu đến từ --email/--password (chưa có trong file)
    if [[ -n "${ARG_EMAIL:-}" ]]; then
      save_credentials "$email" "$password"
      echo "[✓] Đã lưu credentials."
    fi
    if ! auto_login "$email" "$password"; then
      echo "[!] Auto login thất bại. Chuyển sang nhập tay:"
      "$CLI_PATH" auth login --legacy
    fi
  else
    echo "[*] Login OptimAI (nhập email & password):"
    "$CLI_PATH" auth login --legacy
    echo
    echo "[*] Muốn lưu credentials để watchdog tự re-login sau này?"
    read -r -p "Lưu credentials? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      configure_credentials
    fi
  fi

  echo
  if start_node_in_tmux; then
    send_telegram "<b>🟢 Node Cài Đặt & Khởi Động Thành Công</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
    start_watchdog
  else
    echo "[!] Start node thất bại."
    send_telegram "<b>⚠️ Node Start Thất Bại</b>%0A${SERVER_INFO}%0AChạy: tmux attach -t ${TMUX_SESSION}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  fi
}

# ============================================================
# ENTRY POINT
# ============================================================

on_exit() { echo -e "$PROMO_TEXT"; }
trap on_exit EXIT

parse_deploy_args "$@"
banner
must_be_root
apply_telegram_args_if_provided
apply_credentials_args_if_provided
load_telegram_config

while true; do
  echo "OptimAI CLI All in One - Tuangg - Version 1.1.14"
  echo "1)  Cài đặt node lần đầu (tự động watchdog + Telegram)"
  echo "2)  Xem log node (tmux attach)"
  echo "3)  Cập nhật node"
  echo "4)  Kiểm tra rewards"
  echo "5)  Start Watchdog Service"
  echo "6)  Stop Watchdog Service"
  echo "7)  Status Watchdog + Auth + Log"
  echo "8)  Cấu hình Telegram"
  echo "9)  Uninstall Watchdog Service"
  echo "10) Reinstall optimai-cli"
  echo "11) Re-login node (thủ công)"
  echo "12) Lưu/cập nhật credentials"
  echo "0)  Thoát"
  echo
  read -r -p "Chọn [0-12]: " choice

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
    11) relogin_node ;;
    12) configure_credentials ;;
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
