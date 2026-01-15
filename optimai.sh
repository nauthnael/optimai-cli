#!/usr/bin/env bash
set -euo pipefail

CLI_PATH="/usr/local/bin/optimai-cli"
DL_LINUX="https://github.com/OptimaiNetwork/OptimAI-CLI-Node/releases/latest/download/optimai-cli-linux"
TMUX_SESSION="o"

PROMO_NAME="Tuangg"
PROMO_X_URL="http://x.com/tuangg"
PROMO_TEXT="Ae dùng script thấy ok thì follow mình để update bản mới nhé 👉 ${PROMO_X_URL}"

# ===== UI =====
banner() {
  echo
  echo "============================================================"
  echo "  OptimAI CLI All in One - Tuangg"
  echo "  Author: ${PROMO_NAME}"
  echo "  ${PROMO_TEXT}"
  echo "============================================================"
  echo
}

promo_after_step() {
  echo
  echo "---- ${1} xong ✅ ----"
  echo "${PROMO_TEXT}"
  echo
}

# ===== Utils =====
need_cmd() { command -v "$1" >/dev/null 2>&1; }

must_be_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[!] Vui lòng chạy bằng root hoặc sudo"
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
  if command -v apt-get >/dev/null 2>&1; then
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
  if ! need_cmd curl; then
    echo "[*] Cài curl..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y curl
    else
      echo "[!] Không tìm thấy apt-get. Vui lòng tự cài curl."
      exit 1
    fi
  fi

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

# ===== OptimAI CLI =====
download_cli() {
  echo "[*] Tải OptimAI CLI..."
  if need_cmd curl; then
    curl -fL "$DL_LINUX" -o /tmp/optimai-cli
  elif need_cmd wget; then
    wget -qO /tmp/optimai-cli "$DL_LINUX"
  else
    echo "[!] Cần curl hoặc wget."
    exit 1
  fi

  chmod +x /tmp/optimai-cli
  mv /tmp/optimai-cli "$CLI_PATH"
  echo "[✓] Đã cài: $CLI_PATH"
}

ensure_cli() {
  if [[ ! -x "$CLI_PATH" ]]; then
    download_cli
    promo_after_step "Cài OptimAI CLI"
  else
    echo "[✓] OptimAI CLI đã tồn tại."
  fi
}

# ===== Node control =====
start_node_in_tmux() {
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[!] tmux session '$TMUX_SESSION' đã tồn tại."
    echo "    Xem log: tmux attach -t $TMUX_SESSION"
    echo "    Kill session: tmux kill-session -t $TMUX_SESSION"
    return 0
  fi

  echo "[*] Start node trong tmux session '$TMUX_SESSION'..."
  tmux new-session -d -s "$TMUX_SESSION" "$CLI_PATH node start"
}

view_logs() {
  if ! need_cmd tmux; then
    echo "[!] Chưa có tmux. Hãy chạy mục (1) để auto cài tmux trước."
    return 1
  fi

  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[!] Chưa có tmux session '$TMUX_SESSION'. Node chưa chạy?"
    echo "    Hãy chạy mục (1) để cài & start node."
    return 1
  fi

  echo
  echo "📺 Mở log node..."
  echo "👉 Thoát log: nhấn Ctrl+b rồi bấm d"
  echo
  tmux attach -t "$TMUX_SESSION"
}

view_logs_after_start() {
  echo
  echo "📌 Sẽ tự mở log sau 5 giây..."
  echo "👉 Thoát log: nhấn Ctrl+b rồi bấm d"
  echo

  for i in 5 4 3 2 1; do
    echo -ne "Mở log sau ${i}s...\r"
    sleep 1
  done
  echo
  tmux attach -t "$TMUX_SESSION"
}

# ===== Menu actions =====
install_first_time() {
  echo "=== (1) Cài node lần đầu ==="
  ensure_cli

  install_docker_if_needed
  promo_after_step "Cài/kiểm tra Docker"

  install_tmux_if_needed
  promo_after_step "Cài/kiểm tra tmux"

  echo "[*] Login OptimAI (nhập email & password):"
  "$CLI_PATH" auth login
  promo_after_step "Đăng nhập"

  start_node_in_tmux
  promo_after_step "Start node"

  view_logs_after_start
}

update_node() {
  echo "=== (3) Cập nhật node ==="
  ensure_cli
  echo "[*] Running: optimai-cli update"
  "$CLI_PATH" update
  promo_after_step "Cập nhật node"
}

check_rewards() {
  echo "=== (4) Kiểm tra rewards ==="
  ensure_cli
  echo "[*] Running: optimai-cli rewards balance"
  "$CLI_PATH" rewards balance
  promo_after_step "Kiểm tra rewards"
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
    2) view_logs ;;
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

echo
echo "✅ Done!"
echo "${PROMO_TEXT}"
echo
