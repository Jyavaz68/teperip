# TeperIP 🚀

**PasarGuard IP Limit & Anti-Abuse Monitor**

مانیتور سبک، خودکار و پیشرفته برای اعمال محدودیت IP و مقابله با سوءاستفاده (Anti-Abuse) در پنل **PasarGuard**.

TeperIP کاربران آنلاین پنل را بررسی می‌کند، تعداد IPهای فعال و پایدار هر کاربر را با مقدار `hwid_limit` مقایسه کرده و در صورت تخلف، کاربر را به‌صورت موقت جریمه می‌کند.

---

## 🇮🇷 فارسی

### ✨ امکانات

- بررسی خودکار کاربران آنلاین PasarGuard (فقط کاربران فعال برای کاهش مصرف منابع)
- دریافت و محاسبه IPهای فعال و یکتای کاربر روی تمام Nodeها
- مقایسه تعداد IPهای پایدار با `hwid_limit`
- **سیستم IP Stability:** جلوگیری از تشخیص اشتباه در اثر تغییرات موقت IP و Reconnect
- **سیستم تلرانس (Grace Period):** جلوگیری از قطع اشتباه کاربران به دلیل نشست‌های موقت یا تغییر شبکه
- **سیستم پیشرفته Anti-Abuse:** شناسایی هجوم ناگهانی IPهای جدید و جریمه موقت متخلفین
- **حفظ وضعیت (State Persistence):** حفظ وضعیت جریمه‌ها، IP History و اطلاعات Anti-Abuse حتی پس از ری‌استارت سرور
- غیرفعال کردن خودکار کاربر متخلف و فعال‌سازی مجدد او پس از پایان زمان جریمه
- استفاده از چندین Worker برای افزایش سرعت بررسی
- اجرای پایدار به صورت `systemd service`
- منوی مدیریتی تعاملی و قدرتمند با دستور `teperip`
- **سیستم آپدیت‌چکر هوشمند:** امکان بررسی و دریافت نسخه جدید از GitHub بدون از دست رفتن تنظیمات
- **SQLite Database:** ذخیره اطلاعات اتصال پنل و Blockهای فعال TeperIP
- امکان مشاهده کاربران فعلاً غیرفعال‌شده توسط TeperIP
- امکان مشاهده Live Logs
- تهیه Backup
- ویرایش تنظیمات
- امکان Uninstall کامل و تمیز

### 📥 نصب

برای نصب فقط این دستور را روی سرور اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh -o /tmp/teperip-install.sh && sed -i 's/\r$//' /tmp/teperip-install.sh && chmod +x /tmp/teperip-install.sh && bash /tmp/teperip-install.sh
```

نصب به صورت مرحله‌به‌مرحله انجام می‌شود و اطلاعات موردنیاز را از شما دریافت می‌کند.

اگر TeperIP از قبل نصب شده باشد، Database، تنظیمات و وضعیت موجود به صورت خودکار حفظ می‌شوند.

### 🔑 موارد موردنیاز

قبل از نصب موارد زیر را آماده داشته باشید:

- سرور Linux
- پنل PasarGuard
- آدرس پنل PasarGuard
- نام کاربری Admin
- رمز عبور Admin
- دسترسی Root به سرور
- دسترسی اینترنت

### 💾 Database

TeperIP از یک **SQLite Database سبک** برای نگهداری اطلاعات مهم استفاده می‌کند.

مسیر Database:

`/opt/pg_iplimit/teperip.db`

Database برای نگهداری موارد زیر استفاده می‌شود:

- اطلاعات اتصال به پنل PasarGuard
- Username و User ID کاربران غیرفعال‌شده توسط TeperIP
- دلیل غیرفعال شدن کاربر
- زمان شروع Block
- مدت زمان جریمه
- وضعیت Blockهای فعال TeperIP

TeperIP فقط Blockهای فعال خود را در Database نگهداری می‌کند.

پس از فعال‌سازی موفق کاربر، رکورد Block مربوط به آن کاربر از Database حذف می‌شود.

Database به عنوان تاریخچه دائمی Blockها استفاده نمی‌شود.

### 🔄 حفظ Database هنگام Update

در هنگام Update، Database حذف یا بازسازی نمی‌شود.

اطلاعات موجود در:

`/opt/pg_iplimit/teperip.db`

حفظ شده و نسخه جدید TeperIP از همان Database استفاده می‌کند.

بنابراین هنگام Update:

- اطلاعات پنل حفظ می‌شود
- Blockهای فعال حفظ می‌شوند
- اطلاعات Database از بین نمی‌رود
- نیازی به وارد کردن مجدد اطلاعات پنل نیست

### 🧠 IP Stability

TeperIP برای جلوگیری از تشخیص اشتباه هنگام تغییر IP از سیستم **IP Stability** استفاده می‌کند.

یک IP جدید بلافاصله به عنوان IP پایدار در نظر گرفته نمی‌شود و باید در چند بررسی متوالی مشاهده شود.

به صورت پیش‌فرض:

```text
Stable Checks Required = 2
```

برای مثال با بررسی هر ۳۰ ثانیه:

```text
00:00 → IP A
00:30 → IP A
```

IP A به عنوان IP پایدار شناخته می‌شود.

اما در شرایطی مانند:

```text
00:00 → IP A
00:30 → IP B
```

تغییر IP به تنهایی نباید باعث عبور فوری از محدودیت شود.

هدف این سیستم کاهش False Positive ناشی از تغییر شبکه، Reconnect و تغییرات موقت IP است.

### ♾️ کاربران Unlimited

کاربرانی که مقدار زیر را داشته باشند:

```text
hwid_limit <= 0
```

Unlimited محسوب می‌شوند.

این کاربران تحت IP Limit معمولی قرار نمی‌گیرند.

در صورت فعال بودن Anti-Abuse، رفتار IPهای جدید این کاربران به صورت جداگانه بررسی می‌شود.

### 🚨 Anti-Abuse

Anti-Abuse برای شناسایی **هجوم ناگهانی IPهای جدید** طراحی شده است.

Anti-Abuse تعداد کل IPهای کاربر را ملاک قرار نمی‌دهد، بلکه IPهای جدیدی را که در یک بازه کوتاه ظاهر می‌شوند بررسی می‌کند.

تنظیمات پیش‌فرض:

```json
{
  "enabled": true,
  "new_ip_threshold": 20,
  "new_ip_window_seconds": 60,
  "strike_threshold": 3,
  "strike_window_seconds": 1800,
  "ban_seconds": 3600
}
```

نحوه عملکرد پیش‌فرض:

```text
20 IP جدید در 60 ثانیه
        ↓
1 Strike

3 Strike در 30 دقیقه
        ↓
Temporary Disable

مدت جریمه: 1 ساعت
        ↓
Auto Re-enable
```

جریمه‌های Anti-Abuse دائمی نیستند.

### ⚙️ نحوه عملکرد

TeperIP به صورت خودکار:

1. به API پنل PasarGuard متصل می‌شود.
2. کاربران آنلاین را دریافت می‌کند.
3. IPهای فعال هر کاربر را از تمام Nodeها دریافت می‌کند.
4. IPهای تکراری را حذف می‌کند.
5. IPهای پایدار را با سیستم IP Stability مشخص می‌کند.
6. تعداد IPهای پایدار را با `hwid_limit` مقایسه می‌کند.
7. در صورت عبور از محدودیت، Grace Period را شروع می‌کند.
8. در صورت پابرجا بودن تخلف، کاربر را موقتاً غیرفعال می‌کند.
9. بعد از مدت تعیین‌شده، کاربر را مجدداً فعال می‌کند.
10. اگر مشکل همچنان وجود داشته باشد، فرآیند دوباره آغاز می‌شود.
11. در صورت فعال بودن Anti-Abuse، رفتار IPهای جدید کاربران Unlimited را بررسی می‌کند.

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
- تنظیمات IP Limit را ویرایش کنید
- تنظیمات Anti-Abuse را ویرایش کنید
- کاربران فعلاً غیرفعال‌شده توسط TeperIP را مشاهده کنید
- از اطلاعات و تنظیمات Backup بگیرید
- آپدیت‌های جدید GitHub را بررسی کنید
- TeperIP را Uninstall کنید

### 📋 مشاهده لاگ

برای مشاهده لاگ زنده سرویس:

```bash
journalctl -u pg_iplimit.service -f
```

### 📁 مسیر فایل‌ها

فایل‌های TeperIP در این مسیر قرار می‌گیرند:

`/opt/pg_iplimit/`

Database:

`/opt/pg_iplimit/teperip.db`

فایل حفظ وضعیت:

`/opt/pg_iplimit/runtime_state.json`

باینری:

`/opt/pg_iplimit/pg_ip_limit`

سرویس:

`/etc/systemd/system/pg_iplimit.service`

منوی مدیریت:

`/usr/local/bin/teperip`

### 🔄 Update

TeperIP دارای سیستم Update است.

در هنگام Update:

- Database حذف نمی‌شود
- اطلاعات اتصال پنل حفظ می‌شود
- Blockهای فعال حفظ می‌شوند
- Runtime State حفظ می‌شود
- تنظیمات موجود حفظ می‌شوند
- نسخه جدید نصب می‌شود
- سرویس مجدداً راه‌اندازی می‌شود

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
- Checks active IPs across all PasarGuard nodes
- Counts unique active IP addresses
- Compares stable IP count with `hwid_limit`
- **IP Stability:** Reduces false positives caused by temporary IP changes and reconnects
- **Grace Period / Tolerance:** Prevents unnecessary user disabling during temporary network changes
- **Advanced Anti-Abuse Protection:** Detects sudden bursts of new IP addresses
- **State Persistence:** Preserves penalties, IP history, and Anti-Abuse state after server restarts
- Automatically disables users exceeding their limits
- Automatically re-enables users after the penalty period
- Concurrent workers for faster monitoring
- Runs as a stable systemd service
- Interactive management menu via the `teperip` command
- **Smart Update Checker:** Updates from GitHub without losing existing configuration
- **SQLite Database:** Stores panel connection information and active TeperIP blocks
- Active TeperIP Block viewer
- Live log monitoring
- Configuration backups
- Full uninstall support

### 📥 Installation

Run this command on your Linux server:

```bash
curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh -o /tmp/teperip-install.sh && sed -i 's/\r$//' /tmp/teperip-install.sh && chmod +x /tmp/teperip-install.sh && bash /tmp/teperip-install.sh
```

The installer will guide you through the setup.

If TeperIP is already installed, the existing Database, configuration, and runtime state will be preserved automatically.

### 🔑 Requirements

- Linux server
- PasarGuard panel
- PasarGuard panel URL
- PasarGuard Admin username
- PasarGuard Admin password
- Root access
- Internet access

### 💾 SQLite Database

TeperIP uses a lightweight **SQLite Database** to store important persistent information.

Database path:

`/opt/pg_iplimit/teperip.db`

The Database stores:

- PasarGuard panel connection information
- User ID and username for users disabled by TeperIP
- Block reason
- Block start time
- Penalty duration
- Currently active TeperIP blocks

Only active TeperIP blocks are stored.

After a successful re-enable, the corresponding active block record is removed from the Database.

The Database is not used as a permanent block history.

### 🔄 Database During Updates

The existing SQLite Database is preserved during updates.

The following data remains available:

- Panel connection information
- Active TeperIP blocks
- Existing Database data
- Persistent configuration

Users do not need to re-enter their panel credentials after an update.

### 🧠 IP Stability

TeperIP uses an **IP Stability** mechanism to reduce false positives caused by temporary IP changes.

A newly detected IP must be seen during multiple consecutive checks before it is considered stable.

Default:

```text
Stable Checks Required = 2
```

Example with a 30-second check interval:

```text
00:00 → IP A
00:30 → IP A
```

IP A becomes stable.

A temporary change such as:

```text
00:00 → IP A
00:30 → IP B
```

does not immediately trigger an IP-limit violation.

The goal is to reduce false positives caused by network changes, reconnects, and temporary IP changes.

### ♾️ Unlimited Users

Users with:

```text
hwid_limit <= 0
```

are treated as Unlimited.

Unlimited users are excluded from the normal IP Limit system.

When Anti-Abuse is enabled, their new-IP behavior is monitored separately.

### 🚨 Anti-Abuse

Anti-Abuse is designed to detect **sudden bursts of new IP addresses**.

It does not simply count the total number of IPs. Instead, it monitors newly observed IPs within a configurable time window.

Default configuration:

```json
{
  "enabled": true,
  "new_ip_threshold": 20,
  "new_ip_window_seconds": 60,
  "strike_threshold": 3,
  "strike_window_seconds": 1800,
  "ban_seconds": 3600
}
```

Default behavior:

```text
20 new IPs within 60 seconds
        ↓
1 Strike

3 Strikes within 30 minutes
        ↓
Temporary Disable

Penalty: 1 hour
        ↓
Automatic Re-enable
```

Anti-Abuse penalties are temporary and are not permanent bans.

### ⚙️ How It Works

TeperIP:

1. Connects to the PasarGuard API.
2. Retrieves currently online users.
3. Retrieves active IPs for each user across all nodes.
4. Removes duplicate IP addresses.
5. Applies IP Stability checks.
6. Counts stable IP addresses.
7. Compares the stable IP count with the user's `hwid_limit`.
8. Starts a Grace Period when the limit is exceeded.
9. Temporarily disables users who remain above the limit.
10. Automatically re-enables users after the penalty period.
11. Re-checks the user after re-enabling.
12. Runs the Anti-Abuse system for Unlimited users when enabled.

> Only currently online users are checked to reduce unnecessary API requests and resource usage.

### 🛠️ Management

After installation, simply type:

```bash
teperip
```

The management menu provides:

- Service Status
- Live Logs
- Restart Service
- Start Service
- Stop Service
- Edit IP Limit Settings
- Edit Anti-Abuse Settings
- View Active TeperIP Blocks
- Backup Configuration
- Check for Updates
- Uninstall

### 📋 Live Logs

```bash
journalctl -u pg_iplimit.service -f
```

### 📁 Installation Paths

TeperIP directory:

`/opt/pg_iplimit/`

SQLite Database:

`/opt/pg_iplimit/teperip.db`

Runtime State:

`/opt/pg_iplimit/runtime_state.json`

Binary:

`/opt/pg_iplimit/pg_ip_limit`

Systemd service:

`/etc/systemd/system/pg_iplimit.service`

Management command:

`/usr/local/bin/teperip`

### 🔄 Update

TeperIP supports automatic updates.

During an update:

- The SQLite Database is preserved
- Panel connection information is preserved
- Active TeperIP blocks are preserved
- Runtime State is preserved
- Existing configuration is preserved
- The new version is installed
- The systemd service is restarted

### 🗑️ Uninstall

Run:

```bash
teperip
```

Then select **Uninstall** and confirm by typing:

```text
REMOVE
```

---

## 📌 Repository

GitHub:

https://github.com/Jyavaz68/teperip
