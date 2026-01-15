#!/usr/bin/env bash
set -euo pipefail

CLI_PATH="/usr/local/bin/optimai-cli"
TMUX_SESSION="o"

LATEST_JSON_URL="https://cli-node.optimai.network/ubuntu-latest.json"
BASE_DOWNLOAD_URL="https://cli-node.optimai.network"

echo "=============================="
echo " OptimAI CLI Update Checker"
echo "=============================="
echo

# ---- check curl ----
if ! command -v curl >/dev/null 2>&1; then
  echo "[!] curl chưa được cài. Vui lòng cài curl trước."
  exit 1
fi

# ---- check local CLI ----
if [[ ! -x "$CLI_PATH" ]]; then
  echo "[!] Không tìm thấy optimai-cli tại $CLI_PATH"
  exit 1
fi

# ---- get local version (strings -> tmux fallback) ----
if command -v strings >/dev/null 2>&1; then
  LOCAL_VERSION="$(strings "$CLI_PATH" | grep -Eo '0\.[0-9]+\.[0-9]+' | head -n 1 || true)"
else
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    LOCAL_VERSION="$(tmux capture-pane -t "$TMUX_SESSION" -p -S -500 | grep -Eo '0\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  else
    LOCAL_VERSION=""
  fi
fi

[[ -z "$LOCAL_VERSION" ]] && LOCAL_VERSION="unknown"

# ---- get latest version info ----
LATEST_JSON="$(curl -fsSL "$LATEST_JSON_URL")"
REMOTE_VERSION="$(echo "$LATEST_JSON" | grep -Eo '"version"\s*:\s*"[^"]+"' | cut -d'"' -f4)"
REMOTE_PATH="$(echo "$LATEST_JSON" | grep -Eo '"path"\s*:\s*"[^"]+"' | cut -d'"' -f4)"

if [[ -z "$REMOTE_VERSION" || -z "$REMOTE_PATH" ]]; then
  echo "[!] Không lấy được thông tin version từ OptimAI."
  exit 1
fi

REMOTE_URL="${BASE_DOWNLOAD_URL}/${REMOTE_PATH}"

# ---- print info ----
echo "📌 Local version : $LOCAL_VERSION"
echo "📌 Latest version: $REMOTE_VERSION"
echo

# ---- compare ----
if [[ "$LOCAL_VERSION" == "$REMOTE_VERSION" ]]; then
  echo "✅ Bạn đang dùng version mới nhất. Không cần update."
  exit 0
fi

echo "⚠️  Có version mới!"
echo "➡️  $LOCAL_VERSION  →  $REMOTE_VERSION"
echo

read -r -p "Bạn có muốn update OptimAI CLI không? (y/N): " ans

case "${ans:-}" in
  y|Y)
    echo
    echo "[*] Đang tải version mới..."
    echo "URL: $REMOTE_URL"
    curl -fL "$REMOTE_URL" -o /tmp/optimai-cli

    chmod +x /tmp/optimai-cli
    mv /tmp/optimai-cli "$CLI_PATH"

    echo
    echo "✅ Update hoàn tất! CLI hiện tại: $REMOTE_VERSION"
    ;;
  *)
    echo
    echo "[*] Huỷ update. Giữ nguyên version hiện tại."
    exit 0
    ;;
esac

# ---- restart node? ----
echo
read -r -p "Bạn có muốn khởi động lại OptimAI node không? (y/N): " restart_ans

case "${restart_ans:-}" in
  y|Y)
    echo
    echo "[*] Đang khởi động lại node..."

    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      echo "[*] Stop node (kill tmux session)..."
      tmux kill-session -t "$TMUX_SESSION"
      sleep 2
    fi

    echo "[*] Start node trong tmux session '$TMUX_SESSION'..."
    tmux new-session -d -s "$TMUX_SESSION" "$CLI_PATH node start"

    echo
    echo "✅ Node đã được khởi động lại."
    echo "👉 Xem log: tmux attach -t $TMUX_SESSION"
    ;;
  *)
    echo
    echo "[*] Không khởi động lại node."
    echo "👉 Lưu ý: node đang chạy có thể vẫn dùng version cũ cho tới lần restart tiếp theo."
    ;;
esac
