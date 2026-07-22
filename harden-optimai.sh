#!/usr/bin/env bash
# =============================================================================
#  harden-optimai.sh  —  Bịt đường vào crawl4ai để cài lại OptimAI KHÔNG dính miner
#
#  Nguyên nhân gốc: container crawl4ai của OptimAI publish API ra 0.0.0.0:11235
#  (không xác thực) -> bot Internet gọi API -> thả XMRig vào container.
#
#  Script này KHÔNG sửa OptimAI (sẽ bị ghi đè khi cài lại). Nó khoá ở tầng HOST:
#   Lớp 1: Docker mặc định bind cổng vào 127.0.0.1  (/etc/docker/daemon.json)
#   Lớp 2: DROP cổng crawl4ai đi vào từ WAN trong chain DOCKER-USER (firewalld)
#   Lớp 3: xoá container nhiễm + kéo image sạch từ upstream
#
#  CÁCH DÙNG:
#     sudo bash harden-optimai.sh          # DRY-RUN: chỉ in, không đổi gì
#     sudo bash harden-optimai.sh --apply  # THỰC THI (sẽ restart docker 1 lần)
#
#  LƯU Ý: Lớp 1 làm MỌI container publish cổng không ghi IP sẽ chỉ nghe
#  localhost. Nếu bạn có container KHÁC cần phơi công khai thật sự, container đó
#  phải ghi rõ  -p 0.0.0.0:PORT:PORT  thì mới ra ngoài. crawl4ai/OptimAI không cần.
# =============================================================================
set -uo pipefail
APPLY=0; [[ "${1:-}" == "--apply" ]] && APPLY=1
TS="$(date +%Y%m%d-%H%M%S)"; BK="/root/harden-optimai-$TS"; LOG="$BK/log.txt"
mkdir -p "$BK"
c(){ printf '%s\n' "$*" | tee -a "$LOG"; }
run(){ if [[ $APPLY -eq 1 ]]; then c "  [RUN ] $*"; eval "$@"; else c "  [SKIP] $*"; fi; }
[[ $EUID -ne 0 ]] && { echo "Phải chạy bằng root."; exit 1; }

# Cổng crawl4ai cần khoá (thêm cổng khác nếu OptimAI dùng port khác)
PORTS=(11235 21731)
# Tự dò card mạng WAN (theo default route)
WAN_IF="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
[[ -z "$WAN_IF" ]] && WAN_IF="eth0"
# Tự dò IP công khai của chính VPS này (chỉ dùng để in ví dụ kiểm tra cuối script)
VPS_IP="$(curl -s -m3 ifconfig.me 2>/dev/null || curl -s -m3 icanhazip.com 2>/dev/null || echo 'VPS_IP_CUA_BAN')"

c "==================================================================="
c " HARDEN-OPTIMAI  |  mode=$([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
c " WAN interface = $WAN_IF   ports khoá = ${PORTS[*]}   backup = $BK"
c "==================================================================="

# ---------------------------------------------------------------------------
c ""; c "### LỚP 3a — XOÁ CONTAINER crawl4ai HIỆN TẠI (miner nằm trong overlay) ###"
mapfile -t CR < <(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null | grep -i crawl4ai | cut -f1)
if [[ ${#CR[@]} -eq 0 ]]; then c "  (không thấy container crawl4ai nào)"; else
  for n in "${CR[@]}"; do
    c "  [!] container: $n"
    docker inspect "$n" --format '{{json .Config.Labels}}' 2>/dev/null | tr ',' '\n' | grep -i 'compose.project\|compose.config' | sed 's/^/       label: /' | tee -a "$LOG"
    run "docker rm -f '$n'"
  done
fi

# ---------------------------------------------------------------------------
c ""; c "### LỚP 1 — DOCKER MẶC ĐỊNH BIND 127.0.0.1 (/etc/docker/daemon.json) ###"
DJ="/etc/docker/daemon.json"
[[ -f "$DJ" ]] && { cp -a "$DJ" "$BK/daemon.json.bak"; c "  backup daemon.json -> $BK/daemon.json.bak"; }
c "  daemon.json hiện tại:"; [[ -f "$DJ" ]] && sed 's/^/       /' "$DJ" | tee -a "$LOG" || c "       (chưa có)"
NEWJSON="$(python3 - "$DJ" <<'PY'
import json,sys,os
p=sys.argv[1]; d={}
if os.path.exists(p) and os.path.getsize(p)>0:
    try: d=json.load(open(p))
    except Exception: d={}
d["ip"]="127.0.0.1"
print(json.dumps(d,indent=2))
PY
)"
c "  daemon.json MỚI sẽ là:"; sed 's/^/       /' <<<"$NEWJSON" | tee -a "$LOG"
if [[ $APPLY -eq 1 ]]; then
  mkdir -p /etc/docker; printf '%s\n' "$NEWJSON" > "$DJ"
  c "  [RUN ] đã ghi $DJ"
else c "  [SKIP] sẽ ghi $DJ"; fi

# ---------------------------------------------------------------------------
c ""; c "### restart docker để nạp cấu hình (làm gián đoạn container ~vài giây) ###"
run "systemctl restart docker"

# ---------------------------------------------------------------------------
c ""; c "### LỚP 2 — DROP cổng crawl4ai vào từ WAN trong DOCKER-USER (firewalld) ###"
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  for p in "${PORTS[@]}"; do
    RULE="ipv4 filter DOCKER-USER 0 -i $WAN_IF -p tcp --dport $p -j DROP"
    if firewall-cmd --permanent --direct --query-rule $RULE >/dev/null 2>&1; then
      c "  [ok] luật đã tồn tại cho cổng $p"
    else
      run "firewall-cmd --permanent --direct --add-rule $RULE"
    fi
  done
  run "firewall-cmd --reload"
else
  c "  firewalld không chạy -> dùng iptables trực tiếp (nhớ lưu để bền reboot):"
  for p in "${PORTS[@]}"; do
    run "iptables -I DOCKER-USER -i $WAN_IF -p tcp --dport $p -j DROP"
  done
  c "  (cài iptables-persistent hoặc netfilter-persistent để giữ qua reboot)"
fi

# ---------------------------------------------------------------------------
c ""; c "### LỚP 3b — KÉO IMAGE crawl4ai SẠCH TỪ UPSTREAM ###"
run "docker pull unclecode/crawl4ai:0.7.8"

# ---------------------------------------------------------------------------
c ""; c "### KIỂM TRA lại HOST không còn tàn dư (cron/backdoor/file miner) ###"
grep -rIlE 'defunct-kernel|SEED PRNG|base64 -d ?\| ?(ba)?sh' /var/spool/cron /etc/cron* 2>/dev/null \
  | sed 's/^/  [!] cron nghi vấn còn: /' | tee -a "$LOG"
for host_path in /app/.kworker /tmp/python3.12 /tmp/.cfg; do
  [[ -e "$host_path" ]] && c "  [!] còn trên host: $host_path (cần xử lý riêng)"
done
c "  (nếu không có dòng [!] nào ở trên thì host sạch)"

# ---------------------------------------------------------------------------
c ""; c "### XÁC MINH ###"
c "  -- Docker default bind IP (mong đợi 127.0.0.1) --"
docker info 2>/dev/null | grep -i 'Default Address Pool\|Insecure' >/dev/null; grep -o '"ip"[^,}]*' "$DJ" 2>/dev/null | sed 's/^/       daemon.json: /' | tee -a "$LOG"
c "  -- Luật DOCKER-USER --"
{ iptables -S DOCKER-USER 2>/dev/null | grep -E "$(IFS='|'; echo "${PORTS[*]}")" || echo "       (chưa có / dry-run)"; } | sed 's/^/       /' | tee -a "$LOG"
c ""
c "==================================================================="
c " XONG ($([[ $APPLY -eq 1 ]] && echo 'ĐÃ THỰC THI' || echo 'DRY-RUN — chạy lại với --apply'))."
c ""
c " BÂY GIỜ mới cài lại OptimAI. Sau khi cài xong, KIỂM TRA từ chính VPS:"
c "   docker ps --format '{{.Names}}  {{.Ports}}' | grep -i crawl4ai"
c "     -> phải thấy 127.0.0.1:11235->...  (KHÔNG được là 0.0.0.0)"
c "   curl -s -m3 http://${VPS_IP}:11235/ ; echo   # từ MÁY KHÁC: phải timeout/refused"
c "   curl -s -m3 http://127.0.0.1:11235/     ; echo   # từ VPS: phải có phản hồi"
c "==================================================================="
