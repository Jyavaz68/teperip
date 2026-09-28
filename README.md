# TeperIP 🚀

**PasarGuard IP Limit Monitor**

مانیتور سبک و خودکار محدودیت IP برای پنل **PasarGuard**.

TeperIP کاربران آنلاین پنل را بررسی می‌کند و تعداد IPهای فعال هر کاربر را با مقدار `hwid_limit` مقایسه می‌کند.

---

## 🇮🇷 فارسی

### ✨ امکانات

- بررسی خودکار کاربران آنلاین PasarGuard
- بررسی IPهای فعال کاربر روی تمام Nodeها
- محاسبه IPهای یکتا
- مقایسه تعداد IPها با `hwid_limit`
- غیرفعال کردن خودکار کاربر در صورت عبور از محدودیت
- فعال‌سازی مجدد کاربر بعد از مدت مشخص
- بررسی دوره‌ای و خودکار
- استفاده از چند Worker برای کاهش زمان بررسی
- بررسی فقط کاربران آنلاین برای کاهش مصرف منابع
- اجرای دائمی به صورت systemd service
- منوی مدیریتی با دستور `teperip`
- امکان مشاهده Live Logs
- امکان Backup تنظیمات
- امکان Restart / Start / Stop سرویس
- امکان Uninstall کامل

### 📥 نصب

برای نصب فقط این دستور را روی سرور اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh -o /tmp/teperip-install.sh && sed -i 's/\r$//' /tmp/teperip-install.sh && chmod +x /tmp/teperip-install.sh && bash /tmp/teperip-install.sh
```

نصب به صورت مرحله‌به‌مرحله انجام می‌شود و اطلاعات موردنیاز را از شما دریافت می‌کند.

### 🔑 موارد موردنیاز

قبل از نصب موارد زیر را آماده داشته باشید:

- سرور Linux
- پنل PasarGuard
- آدرس پنل PasarGuard
- نام کاربری Admin
- رمز عبور Admin
- دسترسی Root به سرور
- دسترسی اینترنت

### ⚙️ نحوه عملکرد

TeperIP به صورت خودکار:

1. به API پنل PasarGuard متصل می‌شود.
2. کاربران آنلاین را دریافت می‌کند.
3. IPهای فعال هر کاربر را از Nodeها دریافت می‌کند.
4. IPهای یکتا را محاسبه می‌کند.
5. تعداد IPها را با `hwid_limit` مقایسه می‌کند.
6. در صورت عبور از محدودیت، کاربر را غیرفعال می‌کند.
7. بعد از مدت تعیین‌شده، کاربر را مجدداً فعال می‌کند.
8. این فرآیند را به صورت دوره‌ای تکرار می‌کند.

> فقط کاربران آنلاین بررسی می‌شوند تا تعداد درخواست‌های API و مصرف منابع کاهش پیدا کند.

### 🛠️ مدیریت

بعد از نصب برای باز کردن منوی مدیریت:

```bash
teperip
```

از داخل منو می‌توانید:

- وضعیت سرویس را مشاهده کنید
- Live Logs را ببینید
- سرویس را Restart کنید
- سرویس را Start کنید
- سرویس را Stop کنید
- تنظیمات را ویرایش کنید
- از تنظیمات Backup بگیرید
- TeperIP را Uninstall کنید

### 📋 مشاهده لاگ

برای مشاهده لاگ زنده سرویس:

```bash
journalctl -u pg_iplimit.service -f
```

### 📁 مسیر فایل‌ها

فایل‌های TeperIP در این مسیر قرار می‌گیرند:

`/opt/pg_iplimit/`

فایل تنظیمات:

`/opt/pg_iplimit/config.json`

باینری:

`/opt/pg_iplimit/pg_ip_limit`

سرویس:

`/etc/systemd/system/pg_iplimit.service`

منوی مدیریت:

`/usr/local/bin/teperip`

### 🗑️ حذف

برای حذف TeperIP کافی است وارد منوی مدیریت شوید:

```bash
teperip
```

سپس گزینه **Uninstall** را انتخاب کنید.

---

## 🇬🇧 English

### ✨ Features

- Automatic PasarGuard online-user monitoring
- Checks active IPs across all nodes
- Counts unique active IP addresses
- Compares IP count with `hwid_limit`
- Automatically disables users exceeding their IP limit
- Automatically re-enables users after the configured penalty period
- Periodic automatic checking
- Concurrent workers for faster checks
- Checks only currently online users
- Runs as a systemd service
- Management menu with `teperip`
- Live log monitoring
- Configuration backup
- Start / Stop / Restart controls
- Full uninstall support

### 📥 Installation

Run this command on your Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh -o /tmp/teperip-install.sh && sed -i 's/\r$//' /tmp/teperip-install.sh && chmod +x /tmp/teperip-install.sh && bash /tmp/teperip-install.sh
```

The installer will guide you through the setup step by step and ask for the required information.

### 🔑 Requirements

- Linux server
- PasarGuard panel
- PasarGuard Admin credentials
- Root access
- Internet access

### ⚙️ How It Works

TeperIP:

1. Connects to the PasarGuard API.
2. Retrieves currently online users.
3. Retrieves active IPs for each online user.
4. Counts unique IP addresses.
5. Compares the count with `hwid_limit`.
6. Disables users who exceed their configured limit.
7. Re-enables users after the configured penalty period.
8. Repeats the process automatically.

> Only currently online users are checked to reduce unnecessary API requests and resource usage.

### 🛠️ Management

After installation:

```bash
teperip
```

The management menu provides:

- Service Status
- Live Logs
- Restart Service
- Start Service
- Stop Service
- Edit Configuration
- Backup Configuration
- Uninstall

### 📋 Live Logs

```bash
journalctl -u pg_iplimit.service -f
```

### 📁 Installation Paths

Configuration:

`/opt/pg_iplimit/config.json`

Binary:

`/opt/pg_iplimit/pg_ip_limit`

Systemd service:

`/etc/systemd/system/pg_iplimit.service`

Management command:

`/usr/local/bin/teperip`

### 🗑️ Uninstall

Run:

```bash
teperip
```

Then select **Uninstall**.

---

## 📌 Repository

GitHub:

https://github.com/Jyavaz68/teperip

## ⚠️ Disclaimer

این پروژه برای مدیریت و کنترل محدودیت IP کاربران PasarGuard طراحی شده است.

قبل از استفاده در محیط Production، ابتدا آن را روی یک سرور تست کنید.

**Use at your own risk.**
