# OptimAI CLI All in One – Tuangg (v0.2)

Script **All-in-One** giúp cài đặt, vận hành và quản lý **OptimAI CLI Node** nhanh gọn trên Linux chỉ với **1 lệnh**.

> Phù hợp cho anh em chạy node / DePIN / VPS fresh install.

---

## 🚀 Tính năng chính (v0.2)

### 1) Cài đặt node lần đầu (One-Click)
- Tự động **kiểm tra & cài Docker** (theo script `get.docker.com`)
- Tự động **cài tmux**
- Tải **OptimAI CLI**
  - ✅ Ưu tiên tải từ **trang chủ OptimAI**
  - 🔁 Tự động **fallback sang GitHub Releases** nếu link chính lỗi (4xx / 5xx)
- Đăng nhập OptimAI (**nhập email & password thủ công – không lưu thông tin**)
- Khởi động node trong **tmux session `o`**
- **Tự mở log sau 5 giây** để theo dõi node

---

### 2) Xem log node (bất cứ lúc nào)
- Attach vào tmux session `o`
- Hướng dẫn thoát log (node vẫn chạy nền):

```
Ctrl + b  →  d
```

---

### 3) Cập nhật node
- Update OptimAI CLI lên bản mới nhất
- Không ảnh hưởng dữ liệu / config
- Giữ nguyên tmux session nếu đang chạy

---

### 4) Kiểm tra rewards
- Xem rewards trực tiếp từ OptimAI CLI
- Không cần nhớ lệnh phức tạp

---

## 🧠 Điểm mạnh
- ❌ Không hardcode email / password
- ✅ Ưu tiên nguồn **official OptimAI**
- 🔁 Có **cơ chế fallback** khi link official lỗi
- 🧼 Output gọn gàng, dễ hiểu
- 🧩 Menu tiếng Việt – thân thiện
- 🖥️ Phù hợp VPS Ubuntu / Debian

---

## 📦 Yêu cầu hệ thống
- Linux (Ubuntu / Debian khuyến nghị)
- Quyền `root` hoặc `sudo`
- VPS / Server có kết nối Internet

---

## ⚡ Chạy nhanh (1 lệnh)


```bash
wget -O optimai.sh https://raw.githubusercontent.com/nauthnael/optimai-cli/main/optimai.sh \
&& chmod +x optimai.sh \
&& sudo ./optimai.sh
```

---

## 📋 Menu sử dụng

Khi chạy script, bạn sẽ thấy:

```
OptimAI CLI All in One - Tuangg
1) Cài đặt node lần đầu (auto Docker + tmux, login, start)
2) Xem log node
3) Cập nhật node
4) Kiểm tra rewards
0) Thoát
```

---

## 🖥️ Quản lý tmux thủ công (nếu cần)

```bash
# Xem log node
tmux attach -t o

# Thoát log (node vẫn chạy)
# Ctrl + b rồi bấm d

# Kill session node
tmux kill-session -t o
```

---

## 🔒 Bảo mật
- Script **KHÔNG lưu** email / password
- Login trực tiếp qua CLI của OptimAI
- Không gửi dữ liệu ra bên thứ ba

---

## 👤 Tác giả
**Tuangg**

Ae dùng script thấy ok thì follow mình để update bản mới nhé 👉 https://x.com/tuangg

---

## 🤝 Đóng góp
- PR / Issue luôn welcome
- Góp ý cải tiến để script ngày càng gọn & mạnh hơn cho cộng đồng OptimAI / DePIN
