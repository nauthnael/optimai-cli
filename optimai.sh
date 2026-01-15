#!/usr/bin/env bash
set -euo pipefail

CLI_PATH="/usr/local/bin/optimai-cli"
DL_LINUX="https://optimai.network/download/cli-node/linux"
TMUX_SESSION="o"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

must_be_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[!] Please run as root (or with sudo): sudo $0"
    exit 1
  fi
}

install_tmux_if_needed() {
  if need_cmd tmux; then
    echo "[✓] tmux already installed."
    return
  fi

  echo "[*] Installing tmux..."
  if need_cmd apt-get; then
    apt-get update -y
    apt-get install -y tmux
  else
    echo "[!] apt-get not found. Please install tmux manually for your distro."
    exit 1
  fi
  echo "[✓] tmux installed."
}

install_docker_if_needed() {
  if need_cmd docker && docker info >/dev/null 2>&1; then
    echo "[✓] Docker already installed & running."
    return
  fi

  echo "[*] Installing Docker (get.docker.com)..."
  if ! need_cmd curl; then
    echo "[*] curl not found, installing curl..."
    if need_cmd apt-get; then
      apt-get update -y
      apt-get install -y curl
    else
      echo "[!] apt-get not found. Please install curl manually."
      exit 1
    fi
  fi

  # theo đúng lệnh bạn đưa
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh

  # đảm bảo docker chạy
  if need_cmd systemctl; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
  fi

  # test
  if ! docker info >/dev/null 2>&1; then
    echo "[!] Docker installed but not usable yet."
    echo "    Try: systemctl start docker"
    echo "    Or reboot the server."
    exit 1
  fi

  echo "[✓] Docker installed & running."
}

download_cli() {
  echo "[*] Downloading OptimAI CLI..."
  if need_cmd curl; then
    curl -fsSL "$DL_LINUX" -o /tmp/optimai-cli
  elif need_cmd wget; then
    wget -qO /tmp/optimai-cli "$DL_LINUX"
  else
    echo "[!] Need curl or wget. Install one of them first."
    exit 1
  fi

  chmod +x /tmp/optimai-cli
  mv /tmp/optimai-cli "$CLI_PATH"
  echo "[✓] Installed: $CLI_PATH"
}

ensure_cli() {
  if [[ ! -x "$CLI_PATH" ]]; then
    download_cli
  else
    echo "[✓] OptimAI CLI already exists: $CLI_PATH"
  fi
}

start_node_in_tmux() {
  # nếu session đã tồn tại thì không tạo lại
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "[!] tmux session '$TMUX_SESSION' already exists."
    echo "    Attach: tmux attach -t $TMUX_SESSION"
    echo "    Kill:   tmux kill-session -t $TMUX_SESSION"
    return
  fi

  echo "[*] Starting node inside tmux session '$TMUX_SESSION'..."
  tmux new-session -d -s "$TMUX_SESSION" "$CLI_PATH node start"
  echo "[✓] Node started in tmux."
  echo "    View logs: tmux attach -t $TMUX_SESSION"
  echo "    Detach:    Ctrl+b then d"
}

install_first_time() {
  echo "=== (1) First-time install: check deps + login + start node (tmux) ==="
  ensure_cli
  install_docker_if_needed
  install_tmux_if_needed

  echo
  echo "[*] Sign in (enter email & password manually):"
  "$CLI_PATH" auth login

  echo
  start_node_in_tmux
}

update_node() {
  echo "=== (2) Update node ==="
  ensure_cli
  echo "[*] Running: optimai-cli update"
  "$CLI_PATH" update
  echo "[✓] Update done."
}

check_rewards() {
  echo "=== (3) Check rewards ==="
  ensure_cli
  echo "[*] Running: optimai-cli rewards balance"
  "$CLI_PATH" rewards balance
}

menu() {
  echo
  echo "OptimAI CLI Node - Menu"
  echo "1) Cài đặt node lần đầu (auto cài Docker + tmux, login, start trong tmux session '$TMUX_SESSION')"
  echo "2) Cập nhật node"
  echo "3) Kiểm tra rewards"
  echo "0) Thoát"
  echo
  read -r -p "Chọn [0-3]: " choice

  case "${choice:-}" in
    1) install_first_time ;;
    2) update_node ;;
    3) check_rewards ;;
    0) exit 0 ;;
    *) echo "[!] Lựa chọn không hợp lệ." ; exit 1 ;;
  esac
}

must_be_root
menu
