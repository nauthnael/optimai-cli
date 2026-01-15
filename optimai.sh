#!/usr/bin/env bash
set -euo pipefail

# =======================
# OptimAI CLI All in One - Tuangg
# =======================

CLI_PATH="/usr/local/bin/optimai-cli"
TMUX_SESSION="o"

# Ưu tiên tải từ trang chủ, lỗi mới fallback sang GitHub release
OFFICIAL_DL_URL="https://optimai.network/download/cli-node/linux"
GITHUB_RELEASE_API="https://api.github.com/repos/OptimaiNetwork/OptimAI-CLI-Node/releases/latest"

PROMO_NAME="Tuangg"
PROMO_X_URL="https://x.com/tuangg"
PROMO_TEXT="Ae dùng script thấy ok thì follow mình để update bản mới nhé 👉 ${PROMO_X_URL}"

# ===== UI =====
banner() {
  echo
  echo "============================================================"
  echo "  OptimAI CLI All in One - Tuangg"
  echo "============================================================"
  echo
}

# QC: chỉ hiện sau khi cài node thành công
promo_once_after_success() {
  echo
  echo "✅ Cài đặt & start node thành công!"
  echo "${PROMO_TEXT}"
  echo
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

must_be_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[!] Vui lòng chạy bằng root hoặc sudo"
    exit 1
  fi
}

install_curl_if_needed() {
  if need_cmd curl; then return; fi
  echo "[*] Cài curl..."
  if need_cmd apt-get; then
    apt-get update -y
    apt-get install -y curl
  else
    echo "[!] Không tìm thấy apt-get. Vui lòng tự cài curl theo distro của bạn."
    exit 1
  fi
}

# ===== Install deps =====
install_tmux_if_needed() {
  if need_cmd tmux; then
    echo "[✓] tmux đã cài."
    return
  fi
  echo "[*] Cài tmux..."
  if need_cmd apt-get; then
    apt-get update -y
    apt-get install -y tmux
  else
    echo "[!] Không tìm thấy apt-get. Vui lòng tự cài tmux theo distro của bạn."
    exit 1
  fi
}

install_docker_if_needed() {
  if need_cmd docker && docker info >/dev/null 2>&1; then
    echo "[✓] Docker đã sẵn sàng."
    return
  fi

  echo "[*] Cài Docker..."
  install_curl_if_needed

  # ĐÚNG theo lệnh bạn yêu cầu
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh

  if need_cmd systemctl; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker  >/dev/null 2>&1 || true
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "[!] Docker đã cài nhưng chưa chạy được."
    echo "    Thử: systemctl start docker  hoặc reboot VPS rồi chạy lại."
    exit 1
  fi
}

# ===== OptimAI CLI download (Official -> Fallback GitHub Release) =====
download_cli_from_official() {
  echo "[*] Thử tải OptimAI CLI từ trang chủ..."
  install_curl_if_needed
  if curl -fL "$OFFICIAL_DL_URL" -o /tmp/optimai-cli; then
    echo "[✓] Tải từ trang chủ thành công."
    return 0
  fi
  echo "[!] Tải từ trang chủ thất bại (4xx/5xx hoặc network error)."
  return 1
}

get_latest_linux_asset_url_from_github() {
  install_curl_if_needed
  local json
  json="$(curl -fsSL "$GITHUB_RELEASE_API")"

  if need_cmd python3; then
    python3 - <<'PY' "$json"
import json, sys
data = json.loads(sys.argv[1])
assets = data.get("assets", [])

def score(name):
    n = name.lower()
    s = 0
    if "linux" in n: s += 10
    if "amd64" in n or "x86_64" in n: s += 3
    if "arm64" in n or "aarch64" in n: s += 2
    if "cli" in n or "optimai" in n: s += 2
    return s

best, best_s = None, -1
for a in assets:
    name = a.get("name", "")
    url = a.get("browser_download_url", "")
    if not url:
        continue
    s = score(name)
    if s > best_s:
        best, best_s = url, s

if not best:
    sys.exit(2)

print(best)
PY
    return 0
  fi

  echo "$json" \
    | grep -oE '"browser_download_url"\s*:\s*"[^"]+"' \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | grep -i linux \
    | head -n 1
}

download_cli_from_github() {
  echo "[*] Fallback: tải OptimAI CLI từ GitHub Releases..."
  local url
  url="$(get_latest_linux_asset_url_from_github || true)"

  if [[ -z "${url:-}" ]]; then
    echo "[!] Không lấy được asset Linux từ GitHub Releases."
    exit 1
  fi

  echo "[*] Asset URL: $url"
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
  # return codes:
  # 0 = started new session
  # 1 = session already exists
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[!] tmux session '$TMUX_SESSION' đã tồn tại (node có thể đang chạy)."
    return 1
  fi

  echo "[*] Start node trong tmux session '$TMUX_SESSION'..."
  tmux new-session -d -s "$TMUX_SESSION" "$CLI_PATH node start"
  return 0
}

print_log_instructions() {
  echo
  echo "📌 Xem log node:"
  echo "  tmux attach -t ${TMUX_SESSION}"
  echo
  echo "📌 Thoát màn hình log (node vẫn chạy nền):"
  echo "  Nhấn Ctrl + b  rồi bấm d"
  echo
}

ask_and_maybe_open_logs() {
  local ans
  read -r -p "Bạn có muốn xem log không? (y/N): " ans
  case "${ans:-}" in
    y|Y)
      echo
      echo "👉 Thoát log: Ctrl + b rồi bấm d"
      echo "📺 Mở log sau 3 giây..."
      for i in 3 2 1; do
        echo -ne "Mở log sau ${i}s...\r"
        sleep 1
      done
      echo
      tmux attach -t "$TMUX_SESSION"
      ;;
    *)
      echo "[*] OK. Bạn có thể xem log sau bằng: tmux attach -t ${TMUX_SESSION}"
      ;;
  esac
}

view_logs_menu() {
  if ! need_cmd tmux; then
    echo "[!] Chưa có tmux. Hãy chạy mục (1) để auto cài tmux trước."
    return 1
  fi

  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[!] Chưa có tmux session '$TMUX_SESSION'. Node chưa chạy?"
    echo "    Hãy chạy mục (1) để cài & start node."
    return 1
  fi

  print_log_instructions
  tmux attach -t "$TMUX_SESSION"
}

# ===== Menu actions =====
install_first_time() {
  echo "=== (1) Cài node lần đầu ==="
  ensure_cli
  install_docker_if_needed
  install_tmux_if_needed

  echo
  echo "[*] Login OptimAI (nhập email & password):"
  "$CLI_PATH" auth login

  echo
  local started=0
  if start_node_in_tmux; then
    started=1
  else
    started=0
  fi

  # Chỉ coi là "cài đặt node thành công" nếu tạo được session mới
  if [[ "$started" -eq 1 ]]; then
    promo_once_after_success
  else
    echo
    echo "[*] Node có thể đã chạy sẵn. Không hiển thị QC."
    echo
  fi

  print_log_instructions
  ask_and_maybe_open_logs
}

update_node() {
  echo "=== (3) Cập nhật node ==="
  ensure_cli
  echo "[*] Running: optimai-cli update"
  "$CLI_PATH" update
  echo "[✓] Update xong."
}

check_rewards() {
  echo "=== (4) Kiểm tra rewards ==="
  ensure_cli
  echo "[*] Running: optimai-cli rewards balance"
  "$CLI_PATH" rewards balance
}

# ===== Menu =====
menu() {
  echo
  echo "OptimAI CLI All in One - Tuangg"
  echo "1) Cài đặt node lần đầu (auto Docker + tmux, login, start)"
  echo "2) Xem log node"
  echo "3) Cập nhật node"
  echo "4) Kiểm tra rewards"
  echo "0) Thoát"
  echo
  read -r -p "Chọn [0-4]: " choice

  case "${choice:-}" in
    1) install_first_time ;;
    2) view_logs_menu ;;
    3) update_node ;;
    4) check_rewards ;;
    0) exit 0 ;;
    *) echo "[!] Lựa chọn không hợp lệ." ;;
  esac
}

# ===== main =====
banner
must_be_root
menu
