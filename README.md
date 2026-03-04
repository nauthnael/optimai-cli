# OptimAI CLI All in One — Tuangg

> Script quản lý node OptimAI toàn diện: cài đặt, watchdog tự động, re-login khi auth hết hạn, thông báo Telegram.
>
> 📢 Thấy script ok thì follow mình để nhận update mới nhé 👉 [https://x.com/tuangg](https://x.com/tuangg)

---

## Mục lục

- [Tính năng nổi bật](#tính-năng-nổi-bật)
- [Yêu cầu hệ thống](#yêu-cầu-hệ-thống)
- [Cài đặt nhanh](#cài-đặt-nhanh)
- [Hướng dẫn sử dụng menu](#hướng-dẫn-sử-dụng-menu)
- [Truyền tham số dòng lệnh](#truyền-tham-số-dòng-lệnh)
- [Lưu credentials bảo mật](#lưu-credentials-bảo-mật)
- [Watchdog — Tự động bảo vệ node](#watchdog--tự-động-bảo-vệ-node)
- [Deploy hàng loạt 50 VPS](#deploy-hàng-loạt-50-vps)
- [Cấu trúc file cấu hình](#cấu-trúc-file-cấu-hình)
- [Xem log & debug](#xem-log--debug)
- [Lịch sử phiên bản](#lịch-sử-phiên-bản)
- [Lưu ý bảo mật](#lưu-ý-bảo-mật)

---

## Tính năng nổi bật

| Tính năng | Chi tiết |
|---|---|
| 🚀 Cài đặt node một lệnh | Tự động cài Docker, tmux, tải CLI, login, start node |
| 🛡️ Watchdog tự động | Kiểm tra node mỗi 60 giây, tự restart khi phát hiện down |
| 🔑 Auto re-login | Phát hiện auth hết hạn qua `auth status`, tự login lại từ credentials đã lưu |
| 🔒 Credentials bảo mật | Lưu email/password tại `/etc/optimai/credentials.conf` (chmod 600, chỉ root đọc được) |
| 📱 Thông báo Telegram | Cảnh báo đầy đủ: node down, restart, re-login, block, watchdog crash |
| ⛔ Chống restart loop | Block tự động nếu restart quá 4 lần trong 10 phút |
| 🔄 Deploy hàng loạt | Script riêng SSH vào 50 VPS song song, login + restart node tự động |

---

## Yêu cầu hệ thống

- **OS:** Ubuntu 24.04 (hoặc Debian tương đương)
- **Quyền:** `root` (hoặc `sudo`)
- **Kết nối:** Internet để tải CLI và gửi Telegram

Các gói phụ thuộc dưới đây script sẽ **tự động cài** nếu chưa có:

- `tmux` — chạy node trong background session
- `docker` — môi trường cho crawl4ai
- `expect` — tự động nhập email/password khi login
- `curl` — tải CLI và gửi Telegram

---

## Cài đặt nhanh

```bash
# Tải script
wget -O optimai.sh https://raw.githubusercontent.com/nauthnael/optimai-cli/main/optimai.sh
chmod +x optimai.sh

# Chạy (bắt buộc root)
sudo ./optimai.sh
```

Sau đó chọn **menu 1** để cài đặt lần đầu.

### Cài đặt có kèm thông tin ngay từ đầu (khuyến nghị)

```bash
# Truyền đủ thông tin, script tự lưu credentials + Telegram và bắt đầu cài
sudo ./optimai.sh \
  --email=you@mail.com \
  --password='MatKhau!@#$' \
  --bot-token=123456:ABC-DEF \
  --chat-id=987654321
```

> ⚠️ **Lưu ý:** Nếu password có ký tự đặc biệt (`!`, `@`, `#`, `$`, ...) bắt buộc phải dùng **single quotes** `'...'` khi truyền tham số. Xem thêm [mục lưu ý](#password-có-ký-tự-đặc-biệt).

---

## Hướng dẫn sử dụng menu

Sau khi chạy `sudo ./optimai.sh`, bạn sẽ thấy menu:

```
OptimAI CLI All in One - Tuangg - Version 1.1.12
1)  Cài đặt node lần đầu (tự động watchdog + Telegram)
2)  Xem log node (tmux attach)
3)  Cập nhật node
4)  Kiểm tra rewards
5)  Start Watchdog Service
6)  Stop Watchdog Service
7)  Status Watchdog + Auth + Log
8)  Cấu hình Telegram
9)  Uninstall Watchdog Service
10) Reinstall optimai-cli
11) Re-login node (thủ công)
12) Lưu/cập nhật credentials
0)  Thoát
```

### Menu 1 — Cài đặt node lần đầu

Thực hiện toàn bộ quy trình từ đầu:

1. Tải và cài `optimai-cli`
2. Cài Docker (nếu chưa có)
3. Cài tmux (nếu chưa có)
4. Prefetch Docker image `crawl4ai`
5. Login OptimAI (tự động nếu có credentials, hỏi tay nếu không)
6. Start node trong tmux session `o`
7. Tự động bật Watchdog Service

> Nếu chưa có credentials, sau khi login tay script sẽ hỏi có muốn lưu lại không — nên chọn **Y** để watchdog tự re-login sau này.

### Menu 2 — Xem log node

Attach vào tmux session đang chạy node. Thoát khỏi tmux bằng `Ctrl+B` rồi `D` (detach, không dừng node).

### Menu 3 — Cập nhật node

Chạy `optimai-cli update`. Nếu lỗi thì dùng menu 10 để reinstall toàn bộ CLI.

### Menu 4 — Kiểm tra rewards

Hiển thị số dư rewards của account đang đăng nhập.

### Menu 5 / 6 — Start / Stop Watchdog

- **Start:** Tạo lại watchdog script + systemd service rồi enable và chạy
- **Stop:** Dừng watchdog, node vẫn tiếp tục chạy bình thường

### Menu 7 — Status Watchdog + Auth + Log

Hiển thị 3 thông tin cùng lúc:
- Trạng thái systemd service
- Kết quả `auth status` hiện tại (đã login hay chưa)
- 25 dòng log watchdog gần nhất

### Menu 8 — Cấu hình Telegram

Nhập Bot Token và Chat ID. Script gửi test message ngay để xác nhận. Sau khi lưu, watchdog sẽ tự động dùng cấu hình này.

**Cách lấy Bot Token và Chat ID:**
- Tạo bot: nhắn `/newbot` cho [@BotFather](https://t.me/BotFather) trên Telegram
- Lấy Chat ID: nhắn bất kỳ gì cho bot rồi truy cập `https://api.telegram.org/bot<TOKEN>/getUpdates`

### Menu 9 — Uninstall Watchdog

Dừng, disable và xóa hoàn toàn watchdog service + script. Node vẫn chạy, chỉ bỏ chức năng tự động bảo vệ.

### Menu 10 — Reinstall optimai-cli

Dùng khi CLI bị lỗi hoặc cần cập nhật lên bản mới nhất:
1. Dừng node (kill tmux session)
2. Backup CLI cũ
3. Tải và cài lại từ đầu

### Menu 11 — Re-login thủ công

Dùng khi auth hết hạn và muốn login lại ngay mà không cần chờ watchdog:
1. Tạm dừng watchdog
2. Login (tự động từ credentials hoặc hỏi tay)
3. Restart node
4. Khởi động lại watchdog

### Menu 12 — Lưu/cập nhật credentials

Lưu email và password vào `/etc/optimai/credentials.conf` (chmod 600). Script test login ngay sau khi lưu để xác nhận thông tin đúng.

> Đây là bước cần thiết để watchdog có thể **tự re-login** khi auth hết hạn.

---

## Truyền tham số dòng lệnh

Script hỗ trợ truyền thông tin qua tham số để tự động hóa, không cần chọn menu:

```bash
sudo ./optimai.sh [OPTIONS]

Options:
  --email=EMAIL          Email OptimAI
  --password=PASSWORD    Password OptimAI
  --bot-token=TOKEN      Telegram Bot Token
  --chat-id=CHAT_ID      Telegram Chat ID
```

Khi truyền `--email` và `--password`, script **tự động lưu** vào credentials.conf mà không cần vào menu 12.

### Password có ký tự đặc biệt

Bash sẽ báo lỗi `event not found` nếu password chứa `!` mà không được bảo vệ đúng cách:

```bash
# ❌ SAI — bash interpret dấu ! trước khi script nhận
sudo ./optimai.sh --password=Pass!@#2024

# ✅ ĐÚNG — single quotes bảo vệ toàn bộ ký tự đặc biệt
sudo ./optimai.sh --password='Pass!@#2024'

# Các ký tự cần dùng single quotes: ! @ # $ & * ( ) | \ ` "
```

---

## Lưu credentials bảo mật

### Cách lưu

**Cách 1 — Qua menu 12 (khuyến nghị):**
```bash
sudo ./optimai.sh
# Chọn 12, nhập email + password
# Script test login ngay để xác nhận
```

**Cách 2 — Qua tham số dòng lệnh:**
```bash
sudo ./optimai.sh --email=you@mail.com --password='YourPass!@#'
# Credentials tự động lưu khi script khởi động
```

### Nơi lưu trữ

```
/etc/optimai/credentials.conf   ← email + password (chmod 600)
/etc/optimai/telegram.conf      ← bot token + chat ID (chmod 600)
```

### Bảo mật

- Chỉ `root` mới đọc được (`chmod 600`, `root:root`)
- Password được lưu với `printf '%q'` — escape an toàn mọi ký tự đặc biệt
- Khi truyền vào `expect`, dùng biến môi trường (`$env(EXPECT_PASSWORD)`) thay vì nhúng trực tiếp vào chuỗi — tránh lỗi với `!`, `"`, `\`, backtick

---

## Watchdog — Tự động bảo vệ node

Watchdog là một `systemd service` chạy ngầm, kiểm tra mỗi 60 giây theo flow sau:

```
┌─────────────────────────────────────────────┐
│            Mỗi 60 giây                      │
│                                             │
│  Bước 1: optimai-cli auth status            │
│  ├─ "Logged in" → tiếp tục                  │
│  └─ "Not authenticated"                     │
│      ├─ Có credentials → auto re-login      │
│      │   ├─ OK  → reset restart counter     │
│      │   └─ FAIL → Telegram cảnh báo, skip  │
│      └─ Không có credentials                │
│          → Telegram cảnh báo, skip          │
│                                             │
│  Bước 2: tmux has-session                   │
│  ├─ Alive → OK, ngủ 60s                     │
│  └─ Not found → xuống Bước 3               │
│                                             │
│  Bước 3: Restart node                       │
│  ├─ count < 4 → restart + Telegram          │
│  └─ count ≥ 4 → BLOCK + Telegram cảnh báo  │
└─────────────────────────────────────────────┘
```

### Các thông báo Telegram từ watchdog

| Emoji | Tình huống |
|---|---|
| 🛡️ | Watchdog khởi động |
| 🔑 | Phát hiện auth hết hạn, đang re-login |
| ✅ | Re-login thành công |
| ❌ | Re-login thất bại (sai credentials) |
| ⚠️ | Auth hết hạn nhưng chưa có credentials |
| 🟠 | Node down, đang restart |
| 🟢 | Restart thành công |
| 🔴 | Restart thất bại |
| ⛔ | Block vì restart quá nhiều (4 lần/10 phút) |
| 🔴 | Watchdog chết bất ngờ |

### Quản lý watchdog service

```bash
# Xem trạng thái
systemctl status optimai-watchdog.service

# Xem log realtime
journalctl -u optimai-watchdog.service -f

# Xem log file
tail -f /var/log/optimai-watchdog.log

# Restart watchdog (khi cập nhật script)
systemctl restart optimai-watchdog.service
```

### Block logic

Nếu node crash liên tục (≥ 4 lần trong 10 phút), watchdog sẽ **tạm dừng restart** và gửi cảnh báo Telegram. Sau khi cửa sổ 10 phút trôi qua, watchdog tự động mở khóa và thử lại.

Lý do: tránh trường hợp node bị lỗi cấu hình khiến watchdog restart vô tận, tiêu tốn tài nguyên.

---

## Deploy hàng loạt 50 VPS

File `deploy-login.sh` giúp SSH vào từng VPS trong danh sách và thực hiện login + restart node **song song**, không cần thao tác thủ công từng máy.

### Chuẩn bị

**Bước 1** — Sửa thông tin trong file `deploy-login.sh`:

```bash
OPTIMAI_EMAIL="your@email.com"
OPTIMAI_PASSWORD='YourPass!@#'   # Dùng single quotes nếu có ký tự đặc biệt

SSH_USER="root"
SSH_KEY="$HOME/.ssh/id_rsa"      # Để trống nếu dùng SSH password
SSH_PASSWORD=""                   # Điền nếu không dùng SSH key

PARALLEL=5                        # Số VPS chạy song song
```

**Bước 2** — Tạo file `vps-list.txt`:

```
# Format: IP[:PORT] [ssh_password_rieng]
1.2.3.4
5.6.7.8:2222
9.10.11.12
13.14.15.16:2222 pass_rieng_vps_nay
```

**Bước 3** — Chạy:

```bash
chmod +x deploy-login.sh
./deploy-login.sh
```

### Kết quả

Script in bảng tổng kết sau khi xong:

```
============================================================
  KẾT QUẢ  (thời gian: 187s)
============================================================
  ✅ Thành công  : 48
  ❌ Lỗi SSH     : 1
  ❌ Lỗi Login   : 1
  ❌ Lỗi Timeout : 0
  ⚠️  Node fail   : 0
============================================================
```

Chi tiết các VPS thất bại và lý do được lưu vào `deploy-result.txt` và `deploy-login-YYYYMMDD-HHMMSS.log`.

### Yêu cầu trên máy local

```bash
# Ubuntu/Debian
apt-get install -y ssh expect sshpass

# macOS
brew install expect sshpass
```

---

## Cấu trúc file cấu hình

```
/etc/optimai/
├── credentials.conf    # Email + password OptimAI (chmod 600)
└── telegram.conf       # Bot token + chat ID (chmod 600)

/usr/local/bin/
├── optimai-cli         # OptimAI CLI binary
└── optimai-watchdog    # Watchdog script (tự sinh khi chọn menu 5)

/etc/systemd/system/
└── optimai-watchdog.service   # Systemd unit

/var/log/
└── optimai-watchdog.log       # Log watchdog (persistent)

/tmp/
├── optimai-blocked.state      # Trạng thái block restart
└── optimai-restarts.log       # (không dùng, đã chuyển sang /var/log)
```

---

## Xem log & debug

### Log watchdog realtime

```bash
# Qua journalctl (đầy đủ nhất)
journalctl -u optimai-watchdog.service -f

# Qua file log
tail -f /var/log/optimai-watchdog.log

# 50 dòng cuối
tail -n 50 /var/log/optimai-watchdog.log
```

### Log node (tmux)

```bash
# Attach vào session đang chạy node
tmux attach -t o

# Thoát mà không dừng node: Ctrl+B rồi D

# Xem 100 dòng log gần nhất mà không attach
tmux capture-pane -t o -p -S -100
```

### Kiểm tra thủ công

```bash
# Trạng thái đăng nhập
optimai-cli auth status

# Trạng thái node
optimai-cli node status

# Rewards
optimai-cli rewards balance

# Trạng thái watchdog service
systemctl status optimai-watchdog.service
```

### Các lỗi thường gặp

| Lỗi | Nguyên nhân | Cách xử lý |
|---|---|---|
| `event not found` | Password có `!` không dùng single quotes | Dùng `--password='...'` |
| Node tắt liên tục | Auth hết hạn | Chạy menu 11 hoặc lưu credentials (menu 12) |
| Watchdog bị BLOCK | Restart > 4 lần/10 phút | Chờ 10 phút hoặc kiểm tra lỗi node qua `tmux attach -t o` |
| Login timeout | CLI không hiện prompt | Thử `optimai-cli auth login --legacy` thủ công |
| `optimai-cli không chạy được` | Sai arch hoặc thiếu thư viện | Chọn menu 10 để reinstall |

---

## Lịch sử phiên bản

| Version | Thay đổi chính |
|---|---|
| **v1.1.12** | Credentials bảo mật, watchdog auto re-login qua `auth status` |
| **v1.1.11** | `auto_login` dùng expect, menu re-login thủ công |
| **v1.1.10** | Watchdog kiến trúc `Type=simple + while true`, check node bằng `tmux has-session` |
| **v1.1.9** | Fix heredoc EOF expand trong `create_watchdog_script` |
| **v1.1.8** | Fix watchdog `set -euo pipefail`, strip ANSI, tăng verify timeout |
| **v1.1.7** | Fix start node dùng `bash -lc` trong tmux |
| **v1.1.4** | Kiến trúc watchdog ổn định, block logic, trap EXIT |

---

## Lưu ý bảo mật

1. **Chỉ chạy với quyền root** — script cần cài package và tạo systemd service
2. **Credentials lưu plaintext** (chmod 600) — phù hợp cho VPS cá nhân nơi root là bạn. Không dùng trên server chia sẻ nhiều người
3. **Không commit credentials** vào git — file `credentials.conf` nằm trong `/etc/optimai/`, không trong thư mục project
4. **SSH key tốt hơn SSH password** — khi dùng `deploy-login.sh` với nhiều VPS, nên dùng SSH key thay vì password để tránh lộ thông tin qua lịch sử lệnh
5. **Kiểm tra bot Telegram** — chỉ add bot vào group/channel của bạn, không share bot token với ai

---

*Script được phát triển bởi [Tuangg](https://x.com/tuangg) — follow để nhận update mới nhất* 🚀
