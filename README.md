# TeperIP 🚀

**PasarGuard IP Limit & Anti-Abuse Monitor**

مانیتور سبک، خودکار و پیشرفته برای اعمال محدودیت IP و مقابله با سوءاستفاده (Anti-Abuse) در پنل **PasarGuard**.

TeperIP کاربران آنلاین پنل را بررسی می‌کند، تعداد IPهای فعال هر کاربر را با مقدار `hwid_limit` مقایسه کرده و در صورت تخلف، کاربر را جریمه می‌کند.

---

## 🇮🇷 فارسی

### ✨ امکانات

- بررسی خودکار کاربران آنلاین PasarGuard (فقط کاربران فعال برای کاهش مصرف منابع)
- دریافت و محاسبه IPهای فعال و یکتای کاربر روی تمام Nodeها
- مقایسه دقیق تعداد IPها با `hwid_limit`
- **سیستم تلرانس (چشم‌پوشی زمانی):** جلوگیری از قطعی اشتباه کاربران به دلیل تغییر شبکه (مثل جابجایی از وای‌فای به دیتا)
- **سیستم پیشرفته Anti-Abuse:** شناسایی هجوم IPهای جدید و بن کردن موقت متخلفین
- **حفظ وضعیت (State Persistence):** ذخیره وضعیت جریمه‌ها و اخطارها حتی پس از ری‌استارت سرور
- غیرفعال کردن خودکار کاربر متخلف و فعال‌سازی مجدد او پس از پایان زمان جریمه
- استفاده از چندین Worker برای افزایش سرعت بررسی
- اجرای پایدار به صورت systemd service
- منوی مدیریتی تعاملی و قدرتمند با دستور `teperip`
- **سیستم آپدیت‌چکر هوشمند:** امکان آپدیت مستقیم از گیت‌هاب بدون از دست رفتن تنظیمات فعلی
- امکان مشاهده Live Logs، تهیه Backup، و ویرایش تنظیمات
- امکان Uninstall کامل و تمیز

### 📥 نصب

برای نصب فقط این دستور را روی سرور اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh -o /tmp/teperip-install.sh && sed -i 's/\r$//' /tmp/teperip-install.sh && chmod +x /tmp/teperip-install.sh && bash /tmp/teperip-install.sh
```

نصب به صورت مرحله‌به‌مرحله انجام می‌شود و اطلاعات موردنیاز را از شما دریافت می‌کند. (اگر از قبل نصب داشته باشید، تنظیمات شما به صورت خودکار حفظ می‌شود).

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
6. **قانون تلرانس:** در صورت عبور از محدودیت، به کاربر زمان کوتاهی فرصت می‌دهد تا مشکل نشست‌های معلق برطرف شود.
7. در صورت پابرجا بودن تخلف، کاربر را غیرفعال می‌کند.
8. بعد از مدت تعیین‌شده، کاربر را مجدداً فعال می‌کند.
9. در صورت فعال بودن Anti-Abuse، رفتارهای مشکوک کاربر ثبت شده و جریمه‌های سنگین‌تری در نظر گرفته می‌شود.

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
- تنظیمات کانفیگ و Anti-Abuse را ویرایش کنید
- از تنظیمات Backup بگیرید
- آپدیت‌های جدید گیت‌هاب را بررسی کنید
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

فایل حفظ وضعیت:

`/opt/pg_iplimit/runtime_state.json`

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

سپس گزینه **Uninstall** را انتخاب کنید و کلمه `REMOVE` را برای تایید تایپ کنید.

---

## 🇬🇧 English

### ✨ Features

- Automatic PasarGuard online-user monitoring
- Checks active IPs across all nodes
- Counts unique active IP addresses
- Compares IP count with `hwid_limit`
- **Grace Period / Tolerance:** Prevents false positives during network changes
- **Advanced Anti-Abuse Protection:** Detects sudden bursts of new IPs and temporarily bans serial offenders
- **State Persistence:** Preserves user penalties and warnings even after a server reboot
- Automatically disables users exceeding their limits and re-enables them after the penalty period
- Periodic automatic checking with concurrent workers
- Runs as a robust background systemd service
- Interactive management menu via the `teperip` command
- **Smart Update Checker:** Pulls the latest version from GitHub automatically without losing configs
- Live log monitoring, config backups, and full uninstall support

### 📥 Installation

Run this command on your Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh -o /tmp/teperip-install.sh && sed -i 's/\r$//' /tmp/teperip-install.sh && chmod +x /tmp/teperip-install.sh && bash /tmp/teperip-install.sh
```

The installer will guide you through the setup. If an existing installation is detected, your panel credentials and runtime state will be automatically preserved.

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
3. Retrieves active IPs for each online user across all nodes.
4. Counts unique IP addresses.
5. Compares the count with the user's `hwid_limit`.
6. Enforces tolerance rules (giving ghost sessions time to drop) before taking action.
7. Disables users who genuinely exceed limits and re-enables them after the penalty period.
8. Triggers the Anti-Abuse system for suspicious IP hopping behaviors.

> Only currently online users are checked to reduce unnecessary API requests and minimize resource usage.

### 🛠️ Management

After installation, simply type:

```bash
teperip
```

The management menu provides:

- Service Status
- Live Logs
- Restart / Start / Stop Service
- Edit Config & Anti-Abuse Settings
- Backup Configuration
- Check for Updates
- Uninstall

### 📋 Live Logs

```bash
journalctl -u pg_iplimit.service -f
```

### 📁 Installation Paths

Configuration:

`/opt/pg_iplimit/config.json`

Runtime State:

`/opt/pg_iplimit/runtime_state.json`

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

Then select **Uninstall** and confirm by typing `REMOVE`.

---

## 📌 Repository

GitHub:

https://github.com/Jyavaz68/teperip
