#!/usr/bin/env bash
set -euo pipefail
set +H  # Tắt history expansion: tránh lỗi "event not found" với ký tự ! trong password

# ============================================================
# OptimAI CLI All in One - Tuangg
# Version: 1.1.27
#
# Updates:
# v1.1.27:
#   - Hủy bỏ giới hạn luồng Docker `max-concurrent-downloads` do trình giải nén `unpigz` lõi của Docker mặc định vẫn sẽ bung đa luồng ăn 100% CPU.
#
# v1.1.26:
#   - Tối ưu Docker Threading Core: Bổ sung thuật toán chặn sập VPS do Docker giải nén đa luồng bằng cách giới hạn max-concurrent-downloads thông qua JQ, có Validation Loop.
#
# v1.1.25:
#   - Khắc phục lỗi Timeout 600s: Bổ sung Interactive Pre-pull ở Menu 1. Tự động múc 100% dung lượng hệ thống để tải an toàn Image bản chuẩn.
#   - Xóa rác Cận chiến (16GB RAM): Ở chế độ Setup lần đầu, thẳng tay huỷ duyệt `latest` và các version cũ, chỉ giữa duy nhất 1 bản đĩa đang cài đặt để giảm tải cực hạn.
#
# v1.1.24:
#   - Sửa lỗi Menu 1 bị treo tải Image `latest` lãng phí băng thông: Để `optimai-cli` tự động quyết định tag version cần tải thay vì script tự block pre-pull kéo trùng lặp 2 lần.
#   - Tối ưu xoá rác v2: Tách biệt logic ép tắt toàn bộ Container `crawl4ai` cũ và xoá bộ cài Image cũ để khắc phục lỗi xung đột 2 Container (7.3 và 7.8) chạy song song trên VPS.
#
# v1.1.23:
#   - Tự động Xoá Containers/Images cũ: Dọn dẹp phiên bản Docker trùng lặp (multi-versions) và gỡ rác image cũ 0.7.3 khi update lên 0.7.8+ giúp giảm RAM và Disk.
#
# v1.1.22:
#   - Tự động quét dọn rác thư mục /tmp/_MEI* do ứng dụng rò rỉ khi crash/kill.
#
# v1.1.21:
#   - Tối ưu OS Repo cài Docker: Hỗ trợ tự detect đầy đủ Debian/Devuan.
#   - Tối ưu ổ cứng (Log): Tự động xoay vòng file log (rotate) khi vượt quá 10MB.
#   - Watchdog Zero Downtime: Sử dụng tail --pid theo dõi tiến trình chạy ngầm qua sự kiện tmux, phản ứng lập tức khi node crash (thay vì sleep mù).
#   - Deadlock Recovery: Triệt để phá huỷ tiến trình node bị treo và cắt gọn tmux session chết cứng trước khi restart (bằng pkill -9).
#   - Auto-prune Storage: Thêm chức năng cảnh báo dọn dẹp Docker storage nếu ổ gốc nhỏ hơn 10GB.
#   - Preload Latest Image: Trải nghiệm phiên bản node engine ổn định nhất (crawl4ai:latest).
#
# v1.1.20:
#   - Hỗ trợ Devuan (SysVinit) song song với Debian/Ubuntu (systemd)
#   - Thêm detect_init(): tự động nhận diện init system khi khởi động
#     + systemd: dùng systemctl (Debian, Ubuntu)
#     + sysvinit: dùng service + update-rc.d (Devuan mặc định)
#     + runit: dùng sv (Devuan với runit)
#   - Thêm 7 wrapper functions thay thế toàn bộ systemctl calls:
#     svc_start / svc_stop / svc_enable / svc_disable /
#     svc_status / svc_reload / svc_log
#   - create_watchdog_service(): tách nhánh systemd vs sysvinit
#     + systemd  → /etc/systemd/system/optimai-watchdog.service
#     + sysvinit → /etc/init.d/optimai-watchdog (SysV init script)
#     + runit    → /etc/sv/optimai-watchdog/run
#   - Tất cả menu (5,6,7,8,9,11) hoạt động đúng trên cả 2 distro
# v1.1.19:
#   - Fix watchdog_auto_login(): thêm setsid trước expect
#     + v1.1.18 dùng TTYPath=/dev/tty1 → VPS không có console vật lý
#       → kernel gửi SIGHUP → watchdog chết ngay khi khởi động
#     + Fix: bỏ TTY khỏi unit file, dùng setsid thay thế
#     + setsid tạo session mới → expect tự allocate PTY riêng
#     + Không cần TTY từ systemd, watchdog chạy ổn định
#   - Bỏ StandardInput=tty-force, TTYPath, TTYReset, TTYVHangup khỏi unit file
# v1.1.18:
#   - Thử fix watchdog bằng TTYPath=/dev/tty1 (không thành công trên VPS)
#     + Gây SIGHUP ngay khi start → revert ở v1.1.19
# v1.1.17:
#   - Fix do_login() và watchdog_auto_login():
#     + Thêm "after 200" trước send password (200ms delay)
#     + CLI dùng getpass() để đọc password — cần tắt echo terminal trước
#     + Nếu send quá sớm, password bị gửi khi echo chưa tắt → CLI nhận sai
#     + after 200 đảm bảo CLI đã tắt echo xong mới nhận password
# v1.1.16:
#   - Tách auto_login() thành 2 hàm rõ trách nhiệm:
#     + do_login(email, pass): login thật, không --force
#       Dùng cho: menu 12 (test credentials mới), watchdog (auth đã expire)
#     + check_and_login(email, pass): check auth status trước
#       Nếu đã login → return 0 ngay (không login lại, nhanh)
#       Nếu chưa login → gọi do_login()
#       Dùng cho: menu 1 (install/start node), menu 11 (re-login thủ công)
#   - Bỏ hoàn toàn --force: không cần thiết với logic mới
#   - Kết quả: menu 1 chạy lại node khi đã login → xong ngay, không chờ
# v1.1.15:
#   - Fix auto_login() Giai đoạn 3:
#     + Tăng timeout lên 120s (2 phút) để chờ server OptimAI xử lý chậm
#     + Timeout không còn là lỗi — chờ xong rồi dùng auth status xác nhận
#     + EOF cũng không phải lỗi
#     + Nguồn sự thật duy nhất: auth status sau khi expect thoát
#   - Áp dụng cùng fix cho watchdog_auto_login()
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

OPTIMAI_CONFIG_DIR="/etc/optimai"
TELEGRAM_CONFIG="${OPTIMAI_CONFIG_DIR}/telegram.conf"
CREDENTIALS_CONFIG="${OPTIMAI_CONFIG_DIR}/credentials.conf"
SERVER_INFO=""

ARG_BOT_TOKEN=""
ARG_CHAT_ID=""
ARG_EMAIL=""
ARG_PASSWORD=""

# ============================================================
# INIT SYSTEM DETECTION & SERVICE WRAPPERS
# Hỗ trợ: systemd (Debian/Ubuntu) | sysvinit (Devuan) | runit (Devuan runit)
# ============================================================

detect_init() {
  if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
    echo "systemd"
  elif command -v sv &>/dev/null && [[ -d /etc/sv ]]; then
    echo "runit"
  elif [[ -d /etc/init.d ]]; then
    echo "sysvinit"
  else
    echo "unknown"
  fi
}

INIT_SYSTEM=$(detect_init)

# Tên service không có .service suffix (dùng cho sysvinit/runit)
WATCHDOG_SERVICE_NAME="optimai-watchdog"
# Tên đầy đủ cho systemd
WATCHDOG_SERVICE="${WATCHDOG_SERVICE_NAME}.service"
# SysV init script path
WATCHDOG_INITD="/etc/init.d/${WATCHDOG_SERVICE_NAME}"
# Runit service dir
WATCHDOG_RUNIT="/etc/sv/${WATCHDOG_SERVICE_NAME}"

svc_start() {
  local name="$1"
  case "$INIT_SYSTEM" in
    systemd)  systemctl start  "$name"         2>/dev/null || true ;;
    runit)    sv start "${name%.service}"      2>/dev/null || true ;;
    *)        service  "${name%.service}" start 2>/dev/null || true ;;
  esac
}

svc_stop() {
  local name="$1"
  case "$INIT_SYSTEM" in
    systemd)  systemctl stop   "$name"         2>/dev/null || true ;;
    runit)    sv stop  "${name%.service}"      2>/dev/null || true ;;
    *)        service  "${name%.service}" stop  2>/dev/null || true ;;
  esac
}

svc_enable() {
  # Enable + start service
  local name="$1"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl enable --now "$name" 2>/dev/null || true
      ;;
    runit)
      ln -sf "$WATCHDOG_RUNIT" /etc/service/ 2>/dev/null || true
      ;;
    *)
      update-rc.d "${name%.service}" defaults 2>/dev/null || true
      service "${name%.service}" start 2>/dev/null || true
      ;;
  esac
}

svc_disable() {
  local name="$1"
  case "$INIT_SYSTEM" in
    systemd)
      systemctl disable "$name" 2>/dev/null || true
      ;;
    runit)
      rm -f "/etc/service/${name%.service}" 2>/dev/null || true
      sv stop "${name%.service}" 2>/dev/null || true
      ;;
    *)
      service "${name%.service}" stop 2>/dev/null || true
      update-rc.d "${name%.service}" remove 2>/dev/null || true
      ;;
  esac
}

svc_status() {
  local name="$1"
  case "$INIT_SYSTEM" in
    systemd)  systemctl status "$name" --no-pager 2>/dev/null || true ;;
    runit)    sv status "${name%.service}"         2>/dev/null || true ;;
    *)        service   "${name%.service}" status  2>/dev/null || true ;;
  esac
}

svc_reload() {
  # daemon-reload chỉ cần với systemd
  case "$INIT_SYSTEM" in
    systemd)  systemctl daemon-reload 2>/dev/null || true ;;
    *)        true ;;
  esac
}

svc_log() {
  local name="$1"
  case "$INIT_SYSTEM" in
    systemd)  journalctl -u "$name" -n 50 --no-pager 2>/dev/null || true ;;
    *)        tail -50 /var/log/optimai-watchdog.log 2>/dev/null || true ;;
  esac
}

svc_log_cmd() {
  # Trả về chuỗi lệnh xem log live (dùng trong hint/Telegram)
  local name="$1"
  case "$INIT_SYSTEM" in
    systemd)  echo "journalctl -u $name -f" ;;
    *)        echo "tail -f /var/log/optimai-watchdog.log" ;;
  esac
}


# ============================================================
# BANNER & UTILS
# ============================================================

banner() {
  clear
  echo "============================================================"
  echo "        OptimAI CLI All in One - Tuangg (v1.1.27)"
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

  # Test login với credentials mới — dùng do_login (login thật, không check trước)
  echo
  echo "[*] Test login ngay để xác nhận credentials..."
  if do_login "$email" "$password"; then
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
  local os_id
  os_id=$(. /etc/os-release && echo "$ID")
  curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${os_id} \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  svc_enable "docker"
  echo "[✓] Docker đã cài."
}

install_expect_if_needed() {
  if command -v expect >/dev/null 2>&1; then return 0; fi
  echo "[*] Cài expect..."
  apt-get update -y -qq >/dev/null 2>&1 || true
  apt-get install -y expect -qq >/dev/null 2>&1
  echo "[✓] expect đã cài."
}

interactive_prepull() {
  if ! command -v docker >/dev/null 2>&1; then return 0; fi

  echo "[*] Kiểm tra dung lượng ổ đĩa..."
  local free_kb yn
  free_kb=$(df -k / | awk 'NR==2 {print $4}')
  if [[ "$free_kb" -lt 10485760 ]]; then
    echo "[!] Cảnh báo: Ổ cứng gốc ( / ) còn trống dưới 10GB."
    read -r -p "[?] Bạn có muốn dọn dẹp hệ thống Docker để giải phóng không gian không? [y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      echo "[*] Đang xóa các rác Docker cũ..."
      docker image prune -a -f
    fi
  fi

  echo
  echo "[*] Để tránh lỗi Timeout 600s của OptimAI CLI trên VPS mạng yếu,"
  echo "    hệ thống có thể hỗ trợ tiền tải (pre-pull) Image Node trước khi cài đặt."
  local want_pull
  read -r -p "[?] Bạn có muốn tải trước Image không? (y/N - Nhấn Enter mặc định là KHÔNG): " want_pull
  if [[ ! "$want_pull" =~ ^[Yy]$ ]]; then
    echo "  -> Bỏ qua tiền tải. Để cho OptimAI CLI tự động xử lý."
    return 0
  fi

  local user_tag
  read -r -p "[?] Nhập phiên bản Image cần tải (Nhấn Enter mặc định dùng '0.7.8'): " user_tag
  user_tag="${user_tag:-0.7.8}"

  echo "[*] Vệ sinh vùng nhớ RAM & tắt Container đụng độ..."
  docker rm -f $(docker ps -aq --filter "name=optimai_crawl4ai" 2>/dev/null) >/dev/null 2>&1 || true

  echo "[*] Dọn dẹp ổ đĩa siêu gắt (Chỉ cố thủ giữ lại bản $user_tag)..."
  local tags t
  tags=$(docker images --format '{{.Tag}}' unclecode/crawl4ai 2>/dev/null | grep -v "^${user_tag}$" || true)
  
  for t in $tags; do
    if [ -n "$t" ]; then
      echo "  - Gỡ bỏ Image cũ chiếm không gian: unclecode/crawl4ai:$t"
      docker rmi "unclecode/crawl4ai:$t" >/dev/null 2>&1 || true
    fi
  done

  echo "[*] Tiến hành kéo dữ liệu Node không giới hạn thời gian (pulling unclecode/crawl4ai:$user_tag) ..."
  docker pull "unclecode/crawl4ai:$user_tag"
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
# AUTO LOGIN (v1.1.20)
#
# Tách thành 2 hàm:
#   do_login(email, pass)        — login thật bằng expect
#   check_and_login(email, pass) — check auth trước, chỉ login khi cần
#
# Truyền email/password qua env var → expect đọc $env(...)
# An toàn với mọi ký tự đặc biệt: !, @, #, $, ", \, backtick
# ============================================================

# do_login EMAIL PASSWORD
# Login thật bằng expect. Không check auth trước.
# Dùng cho: menu 12 (test credentials mới), watchdog (auth đã xác nhận expire)
do_login() {
  local email="$1"
  local password="$2"

  install_expect_if_needed

  echo "[*] Đang login: $email"

  # 3 giai đoạn — không dùng --force, không dùng exp_continue:
  #   Giai đoạn 1: chờ prompt Email  → gửi email    (timeout 30s → lỗi)
  #   Giai đoạn 2: chờ prompt Pass   → gửi password (timeout 30s → lỗi)
  #   Giai đoạn 3: chờ server xử lý  → timeout 120s KHÔNG phải lỗi
  # Xác nhận kết quả bằng auth status — nguồn sự thật duy nhất
  local output rc
  output=$(EXPECT_EMAIL="$email" EXPECT_PASSWORD="$password" \
    expect -c '
      log_user 1
      set email    $env(EXPECT_EMAIL)
      set password $env(EXPECT_PASSWORD)
      spawn '"${CLI_PATH}"' auth login --legacy

      # Giai đoạn 1: chờ prompt Email (timeout 30s)
      set timeout 30
      expect {
        -re {(?i)(email|e-mail|username|login)} { send "$email\r" }
        timeout { puts "TIMEOUT_EMAIL"; exit 1 }
        eof     { puts "EOF_EMAIL";    exit 1 }
      }

      # Giai đoạn 2: chờ prompt Password (timeout 30s)
      # after 200: chờ CLI tắt echo terminal xong mới gửi password
      set timeout 30
      expect {
        -re {(?i)(password|pass)} { after 200; send "$password\r" }
        timeout { puts "TIMEOUT_PASSWORD"; exit 1 }
        eof     { puts "EOF_PASSWORD"; exit 1 }
      }

      # Giai đoạn 3: chờ server xử lý (timeout 120s = 2 phút)
      # Timeout và EOF KHÔNG phải lỗi — auth status xác nhận sau
      set timeout 120
      expect {
        -re {(?i)(signed in|success|logged in|welcome)} { }
        timeout { }
        eof     { }
      }
    ' 2>&1)
  rc=$?

  echo "$output"

  if [[ $rc -ne 0 ]]; then
    echo "[!] Login thất bại (expect exit $rc)."
    return 1
  fi

  # Xác nhận bằng auth status — nguồn sự thật duy nhất
  echo "[*] Xác nhận auth status..."
  local status_out
  status_out=$("${CLI_PATH}" auth status 2>&1 || true)
  if echo "$status_out" | grep -qi "Logged in"; then
    echo "[✓] Login thành công — $status_out"
    return 0
  else
    echo "[!] Login thất bại — $status_out"
    return 1
  fi
}

# Kiểm tra auth status trước. Nếu đã login → return 0 ngay (không login lại).
# Nếu chưa login → gọi do_login().
# Dùng cho: menu 1 (install/start node), menu 11 (re-login thủ công)
check_and_login() {
  local email="$1"
  local password="$2"

  echo "[*] Kiểm tra trạng thái đăng nhập..."
  local status_out
  status_out=$("${CLI_PATH}" auth status 2>&1 || true)
  if echo "$status_out" | grep -qi "Logged in"; then
    echo "[✓] Đã đăng nhập — $status_out"
    return 0
  fi

  echo "[*] Chưa đăng nhập. Tiến hành login: $email"
  do_login "$email" "$password"
}

# ============================================================
# NODE MANAGEMENT
# ============================================================

start_node_in_tmux() {
  install_tmux_if_needed

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[*] Kill session cũ '$TMUX_SESSION' để start lại sạch..."
    timeout 5 tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
  fi
  
  # Dọn dẹp triệt để phòng trường hợp Zombie Process treo hệ thống
  pkill -9 -f "${CLI_PATH} node start" >/dev/null 2>&1 || true
  
  # Giải phóng file rác tạm của PyInstaller tránh full /tmp Disk
  rm -rf /tmp/_MEI* >/dev/null 2>&1 || true
  
  # Xoá tận gốc toàn bộ Container thuộc dòng OptimAI trước để tránh xung đột chạy đè (Vd: 7.3 vs 7.8)
  if command -v docker >/dev/null 2>&1; then
    docker rm -f $(docker ps -aq --filter "name=optimai_crawl4ai" 2>/dev/null) >/dev/null 2>&1 || true
    
    # Dọn dẹp Docker Image bản cũ thông minh (Chỉ xoá bộ gài 8GB phiên bản cũ trên đĩa)
    local tags old_tags t
    tags=$(docker images --format '{{.Tag}}' unclecode/crawl4ai 2>/dev/null | grep -v 'latest' | sort -V | uniq || true)
    if [ $(echo "$tags" | wc -w) -gt 1 ]; then
      old_tags=$(echo "$tags" | head -n -1)
      for t in $old_tags; do
        docker rmi "unclecode/crawl4ai:$t" >/dev/null 2>&1 || true
      done
    fi
  fi
  sleep 1

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
  svc_stop "$WATCHDOG_SERVICE"

  # check_and_login: nếu đã login rồi → bỏ qua, không login lại
  if check_and_login "$email" "$password"; then
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
  svc_start "$WATCHDOG_SERVICE"
  echo
}

# ============================================================
# WATCHDOG (v1.1.20)
# Kiến trúc: Type=simple + while true (từ v1.1.4)
# Phương án A: chỉ check auth khi node DOWN (không gọi mỗi 60s)
# Phương án A: check auth khi node DOWN + do_login không --force
# ============================================================

create_watchdog_script() {
  cat <<'WATCHDOG_EOF' > "$WATCHDOG_SCRIPT"
#!/usr/bin/env bash
# OptimAI Watchdog v1.1.20
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
SLEEP_INTERVAL=15

# ============================================================
# UTILS
# ============================================================

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  echo "$(ts) [watchdog] $*" | tee -a "$RESTART_LOG"
  # Rotate log nếu kích thước tiệm cận 10MB
  if [[ -f "$RESTART_LOG" ]]; then
    local size
    size=$(stat -c%s "$RESTART_LOG" 2>/dev/null || echo 0)
    if [[ "$size" -gt 10485760 ]]; then
      mv "$RESTART_LOG" "${RESTART_LOG}.1" 2>/dev/null || true
    fi
  fi
}

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
    send_telegram "<b>🔴 Watchdog Chết Bất Ngờ</b>%0A'"$SERVER_INFO"'%0AExit: ${code}%0AThời gian: $(date "+%Y-%m-%d %H:%M:%S")%0AKiểm tra: tail -50 /var/log/optimai-watchdog.log"
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
  # Gọi khi auth đã xác nhận expire → login thật, không check lại
  # setsid: tạo session mới → expect tự allocate PTY riêng
  # Cần thiết vì watchdog chạy dưới systemd (không có controlling TTY)
  if ! command -v expect >/dev/null 2>&1; then
    log "WARN: expect chưa cài, bỏ qua auto login"
    return 1
  fi

  local output rc
  output=$(EXPECT_EMAIL="$OPTIMAI_EMAIL" EXPECT_PASSWORD="$OPTIMAI_PASSWORD" \
    setsid expect -c '
      log_user 0
      set email    $env(EXPECT_EMAIL)
      set password $env(EXPECT_PASSWORD)
      spawn '"$CLI_PATH"' auth login --legacy

      # Giai đoạn 1: chờ prompt Email (timeout 30s)
      set timeout 30
      expect {
        -re {(?i)(email|e-mail|username|login)} { send "$email\r" }
        timeout { puts "TIMEOUT_EMAIL"; exit 1 }
        eof     { puts "EOF_EMAIL";    exit 1 }
      }

      # Giai đoạn 2: chờ prompt Password (timeout 30s)
      # after 200: chờ CLI tắt echo terminal xong mới gửi password
      set timeout 30
      expect {
        -re {(?i)(password|pass)} { after 200; send "$password\r" }
        timeout { puts "TIMEOUT_PASSWORD"; exit 1 }
        eof     { puts "EOF_PASSWORD"; exit 1 }
      }

      # Giai đoạn 3: chờ server xử lý (timeout 120s)
      # Timeout và EOF đều KHÔNG phải lỗi — auth status xác nhận sau
      set timeout 120
      expect {
        -re {(?i)(signed in|success|logged in|welcome)} { }
        timeout { }
        eof     { }
      }
    ' 2>&1)
  rc=$?

  if [[ $rc -ne 0 ]]; then
    log "AUTH: expect exit $rc — output: $output"
    return 1
  fi

  # Nguồn sự thật duy nhất: auth status
  local status_out
  status_out=$("$CLI_PATH" auth status 2>&1 || true)
  if echo "$status_out" | grep -qi "Logged in"; then
    log "AUTH: Xác nhận auth status OK"
    return 0
  else
    log "AUTH: Login thất bại — auth status: $status_out"
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
  # Sử dụng tail --pid theo dõi tiến trình (event-driven, zero downtime)
  # ----------------------------------------------------------
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux_pid=$(tmux display-message -t "$TMUX_SESSION" -p '#{pane_pid}' 2>/dev/null || echo "")
    if [[ -n "$tmux_pid" ]] && kill -0 "$tmux_pid" 2>/dev/null; then
      log "NODE: OK - tmux session alive (PID: $tmux_pid). Theo dõi thụ động..."
      tail --pid="$tmux_pid" -f /dev/null
      log "NODE: Tiến trình tmux báo tử/kết thúc. Kích hoạt cứu hộ!"
    else
      log "NODE: tmux báo alive nhưng lỗi gắn process. Chờ dự phòng ${SLEEP_INTERVAL}s..."
      sleep "$SLEEP_INTERVAL"
    fi
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

  # Ép dọn dẹp các session bị treo (deadlock)
  log "NODE: Tiến hành dọn dẹp sạch môi trường chết ngầm trước khi start..."
  timeout 5 tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
  pkill -9 -f "${CLI_PATH} node start" >/dev/null 2>&1 || true
  
  # Xoá dứt điểm thư mục giải nén rác của PyInstaller /tmp/_MEI...
  rm -rf /tmp/_MEI* >/dev/null 2>&1 || true
  
  # Xoá tận gốc toàn bộ Container thuộc dòng OptimAI trước để tránh xung đột chạy đè
  if command -v docker >/dev/null 2>&1; then
    docker rm -f $(docker ps -aq --filter "name=optimai_crawl4ai" 2>/dev/null) >/dev/null 2>&1 || true
    
    # Dọn dẹp Docker Image bản cũ thông minh (Chỉ xoá bộ gài 8GB phiên bản cũ trên đĩa)
    tags=$(docker images --format '{{.Tag}}' unclecode/crawl4ai 2>/dev/null | grep -v 'latest' | sort -V | uniq || true)
    if [ $(echo "$tags" | wc -w) -gt 1 ]; then
      old_tags=$(echo "$tags" | head -n -1)
      for t in $old_tags; do
        docker rmi "unclecode/crawl4ai:$t" >/dev/null 2>&1 || true
      done
    fi
  fi
  sleep 1

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
  case "$INIT_SYSTEM" in
    systemd)
      cat <<EOF > "/etc/systemd/system/$WATCHDOG_SERVICE"
[Unit]
Description=OptimAI Watchdog v1.1.20 - Tuangg (tmux: $TMUX_SESSION)
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
      svc_reload
      ;;

    runit)
      mkdir -p "$WATCHDOG_RUNIT"
      cat <<EOF > "${WATCHDOG_RUNIT}/run"
#!/bin/sh
exec $WATCHDOG_SCRIPT
EOF
      chmod +x "${WATCHDOG_RUNIT}/run"
      ;;

    *)
      # SysVinit — Devuan mặc định
      cat <<EOF > "$WATCHDOG_INITD"
#!/bin/sh
### BEGIN INIT INFO
# Provides:          optimai-watchdog
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: OptimAI Watchdog v1.1.20
### END INIT INFO

DAEMON=$WATCHDOG_SCRIPT
PIDFILE=/var/run/optimai-watchdog.pid
NAME=optimai-watchdog

case "\$1" in
  start)
    echo "Starting \$NAME..."
    start-stop-daemon --start --background --make-pidfile \\
      --pidfile "\$PIDFILE" --exec "\$DAEMON"
    ;;
  stop)
    echo "Stopping \$NAME..."
    start-stop-daemon --stop --pidfile "\$PIDFILE" --retry 10
    rm -f "\$PIDFILE"
    ;;
  restart)
    \$0 stop
    sleep 2
    \$0 start
    ;;
  status)
    if [ -f "\$PIDFILE" ] && kill -0 \$(cat "\$PIDFILE") 2>/dev/null; then
      echo "\$NAME is running (PID \$(cat \$PIDFILE))"
    else
      echo "\$NAME is not running"
    fi
    ;;
  *)
    echo "Usage: \$0 {start|stop|restart|status}"
    exit 1
    ;;
esac
exit 0
EOF
      chmod +x "$WATCHDOG_INITD"
      ;;
  esac
}

# ============================================================
# WATCHDOG MANAGEMENT
# ============================================================

start_watchdog() {
  echo "=== (5) Start Watchdog Service ==="
  create_watchdog_script
  create_watchdog_service
  svc_enable "$WATCHDOG_SERVICE"
  echo "[✓] Watchdog đã start và enable."
  echo "    Xem log live  : $(svc_log_cmd "$WATCHDOG_SERVICE")"
  echo "    Xem log file  : tail -f /var/log/optimai-watchdog.log"
  send_telegram "<b>🛡️ Watchdog Đã Start</b>%0A${SERVER_INFO}%0AKiểm tra node + auth mỗi 60 giây.%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

stop_watchdog() {
  echo "=== (6) Stop Watchdog Service ==="
  svc_stop    "$WATCHDOG_SERVICE"
  svc_disable "$WATCHDOG_SERVICE"
  echo "[✓] Watchdog đã stop & disable."
  send_telegram "<b>🛑 Watchdog Đã Stop</b>%0A${SERVER_INFO}%0AThời gian: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
}

status_watchdog() {
  echo "=== (7) Status Watchdog Service ==="
  echo "[i] Init system: $INIT_SYSTEM"
  echo
  svc_status "$WATCHDOG_SERVICE"
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
  echo "👉 Theo dõi live: $(svc_log_cmd "$WATCHDOG_SERVICE")"
  echo
}

uninstall_watchdog() {
  echo "=== (9) Uninstall Watchdog Service ==="
  svc_stop    "$WATCHDOG_SERVICE"
  svc_disable "$WATCHDOG_SERVICE"
  # Xóa service file tuỳ init system
  case "$INIT_SYSTEM" in
    systemd)  rm -f "/etc/systemd/system/$WATCHDOG_SERVICE" ; svc_reload ;;
    runit)    rm -rf "$WATCHDOG_RUNIT" ;;
    *)        rm -f "$WATCHDOG_INITD" ;;
  esac
  rm -f "$WATCHDOG_SCRIPT"
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
  interactive_prepull

  local email password
  resolve_credentials email password

  if [[ -n "$email" && -n "$password" ]]; then
    echo "[*] Dùng credentials đã có (${email})..."
    # Lưu lại nếu đến từ --email/--password (chưa có trong file)
    if [[ -n "${ARG_EMAIL:-}" ]]; then
      save_credentials "$email" "$password"
      echo "[✓] Đã lưu credentials."
    fi
    # check_and_login: nếu đã login rồi → bỏ qua ngay, không login lại
    if ! check_and_login "$email" "$password"; then
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
  echo "OptimAI CLI All in One - Tuangg - Version 1.1.27"
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
      echo
      echo "============================================================"
      echo "🚀 Cảm ơn bạn đã sử dụng Script Tối ưu OptimAI (v1.1.27) !"
      echo "✨ Các thay đổi mới nhất:"
      echo "   - Watchdog Zero Downtime (Tail PID event-driven)"
      echo "   - Fix lỗi tương thích OS Repo cho Debian/Devuan"
      echo "   - Dọn dẹp rác /tmp/_MEI* triệt để sau crash"
      echo "   - Auto-prune Docker & Log Rotate chống tràn"
      echo "👉 Kết nối với mình tại X/Twitter: https://x.com/tuangg"
      echo "============================================================"
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
