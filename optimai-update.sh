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

# ---- requirements ----
if ! command -v curl >/dev/null 2>&1; then
  echo "[!] curl chưa được cài. Vui lòng cài curl trước."
  exit 1
fi

if [[ ! -x "$CLI_PATH" ]]; then
  echo "[!] Không tìm thấy optimai-cli tại $CLI_PATH"
  exit 1
fi

# ---- get local version: --version -> strings -> tmux fallback ----
get_local_version() {
  local v=""

  # 1) Primary: optimai-cli --version
  if "$CLI_PATH" --version >/dev/null 2>&1; then
    v="$("$CLI_PATH" --version | grep -Eo '0\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  fi

  # 2) Fallback: strings (binutils)
  if [[ -z "$v" ]] && command -v strings >/dev/null 2>&1; then
    v="$(strings "$CLI_PATH" | grep -Eo '0\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  fi

  # 3) Fallback: tmux log (if node running)
  if [[ -z "$v" ]] && command -v tmux >/dev/null 2>&1 && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    v="$(tmux capture-pane -t "$TMUX_SESSION" -p -S -500 | grep -Eo '0\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  fi

  [[ -z "$v" ]] && v="unknown"
  echo "$v"
}

LOCAL_VERSION="$(get_local_version)"

# ---- get remote version/path from official json ----
LATEST_JSON="$(curl -fsSL "$LATEST_JSON_URL")"
REMOTE_VERSION="$(echo "$LATEST_JSON" | grep -Eo '"version"\s*:\s*"[^"]+"' | cut -d'"' -f4)"
REMOTE_PATH="$(echo "$LATEST_JSON" | grep -Eo '"path"\s*:\s*"[^"]+"' | cut -d'"' -f4)"

if [[ -z "${REMOTE_VERSION:-}" || -z "${REMOTE_PATH:-}" ]]; then
  echo "[!] Không lấy được thông tin version từ OptimAI (ubuntu-latest.json)."
  exit 1
fi

REMOTE_URL="${BASE_DOWNLOAD_URL}/${REMOTE_PATH}"

echo "📌 Local version : $LOCAL_VERSION"
echo "📌 Latest version: $REMOTE_VERSION"
echo

# ---- if already latest ----
if [[ "$LOCAL_VERSION" == "$REMOTE_VERSION" ]]; then
  echo "✅ Bạn đang dùng version mới nhất. Không cần update."
  exit 0
fi

echo "⚠️  Có version mới!"
echo "➡️  $LOCAL_VERSION  →  $REMOTE_VERSION"
echo

read -r -p "Bạn có muốn update OptimAI CLI không? (y/N): " ans
case "${ans:-}" in
  y|Y) ;;
  *) echo "[*] Huỷ update."; exit 0 ;;
esac

# ---- backup current binary ----
BACKUP_PATH="${CLI_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
cp -a "$CLI_PATH" "$BACKUP_PATH"
echo "[*] Backup binary hiện tại: $BACKUP_PATH"

# ---- download and replace ----
echo "[*] Đang tải version mới..."
echo "URL: $REMOTE_URL"
curl -fL "$REMOTE_URL" -o /tmp/optimai-cli

chmod +x /tmp/optimai-cli
mv /tmp/optimai-cli "$CLI_PATH"

echo
echo "✅ Update hoàn tất! CLI hiện tại: $REMOTE_VERSION"
echo

# ---- ask restart node ----
read -r -p "Bạn có muốn khởi động lại OptimAI node không? (y/N): " restart_ans
case "${restart_ans:-}" in
  y|Y)
    if ! command -v tmux >/dev/null 2>&1; then
      echo "[!] Không có tmux nên không thể restart node theo session '$TMUX_SESSION'."
      echo "    Bạn có thể tự restart bằng lệnh: $CLI_PATH node start"
      exit 0
    fi

    echo
    echo "[*] Đang khởi động lại node..."

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      echo "[*] Stop node (kill tmux session '$TMUX_SESSION')..."
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
    echo "[*] Không khởi động lại node."
    echo "👉 Lưu ý: node đang chạy có thể vẫn dùng version cũ cho tới lần restart tiếp theo."
    ;;
esac
