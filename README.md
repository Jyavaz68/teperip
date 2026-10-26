
# TeperIP 🚀

**PasarGuard IP Limit, Anti-Abuse & Instant Node Kick Monitor (v1.4.0)**

مانیتور سبک، خودکار و پیشرفته برای اعمال محدودیت IP، مقابله با سوءاستفاده (Anti-Abuse) و قطع آنی اتصالات فعال روی نودها (Node Agent Kick) در پنل **PasarGuard**.

TeperIP کاربران آنلاین پنل را بررسی می‌کند، تعداد IPهای فعال و پایدار هر کاربر را با مقدار `hwid_limit` مقایسه کرده و در صورت تخلف، علاوه بر غیرفعال‌سازی موقت اکانت در پنل، می‌تواند از طریق ایجنت نودها در همان لحظه سوکت‌های باز کاربر متخلف را قطع و IP او را در لایه کرنل (`nftables`) مسدود کند.

---

## 🇮🇷 فارسی

### ✨ امکانات

- بررسی خودکار کاربران آنلاین PasarGuard؛ فقط کاربران فعال برای کاهش مصرف منابع
- دریافت و محاسبه IPهای فعال و یکتای کاربران روی تمام Nodeها
- مقایسه تعداد IPهای پایدار با `hwid_limit`
- **⚡ سیستم قطع آنی اتصال روی نودها (Node Agent / Kick):** بستن فوری سوکت‌های فعال (`ss -K`) و مسدودسازی موقت IP متخلف در فایروال نود (`nftables` در زنجیره `prerouting` با اولویت `-300` قبل از NAT داکر)
- **IP Stability مبتنی بر سیکل:** جلوگیری از تشخیص اشتباه در اثر تغییرات موقت IP، Reconnect یا طولانی شدن سیکل‌های بررسی
- **Grace Period:** جلوگیری از قطع اشتباه کاربران به دلیل نشست‌های موقت یا تغییر شبکه و پاکسازی خودکار کاربران آفلاین
- **Anti-Abuse پیشرفته:** شناسایی هجوم ناگهانی IPهای جدید و جریمه موقت متخلفین
- **State Persistence:** حفظ وضعیت جریمه‌ها، IP History و اطلاعات Anti-Abuse پس از ری‌استارت
- غیرفعال‌سازی خودکار کاربران متخلف و فعال‌سازی مجدد پس از پایان جریمه
- Rollback خودکار در صورت خطای دیتابیس
- استفاده از چند Worker هم‌زمان (Goroutines)
- اجرای پایدار به‌صورت `systemd service` همراه با مدیریت حجم لاگ‌های `journald`
- منوی مدیریتی تعاملی با دستور `teperip`
- سیستم آپدیت هوشمند از GitHub بدون حذف تنظیمات و دیتابیس
- **SQLite Database:** ذخیره وضعیت Blockهای فعال TeperIP
- مشاهده زنده کاربران مسدودشده و زمان باقی‌مانده جریمه
- مشاهده Live Logs، تهیه Backup، ویرایش تنظیمات و Uninstall کامل

---

### 📥 نصب (سرور مستر / پنل)

دستور زیر را روی سرور اصلی یا سروری که به API پنل دسترسی دارد، با دسترسی `root` اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh -o /tmp/teperip-install.sh && sed -i 's/\r$//' /tmp/teperip-install.sh && chmod +x /tmp/teperip-install.sh && bash /tmp/teperip-install.sh
```

نصب به‌صورت مرحله‌به‌مرحله انجام می‌شود و اطلاعات موردنیاز را دریافت می‌کند.

اگر TeperIP از قبل نصب شده باشد، دیتابیس، تنظیمات و وضعیت موجود باید طبق منطق مهاجرت اسکریپت حفظ شوند؛ قبل از آپدیت، تهیه Backup توصیه می‌شود.

### 🔑 موارد موردنیاز

- سرور Linux با دسترسی `root`
- پنل PasarGuard و اطلاعات دسترسی Admin
- دسترسی اینترنت

---

### ⚡ راه‌اندازی سیستم قطع آنی روی نودها (Node Agent / Kick)

در حالت عادی، وقتی کاربری در پنل غیرفعال می‌شود، اتصالات قبلی او، به‌ویژه در پروتکل‌های WebSocket و gRPC، ممکن است تا زمان بسته‌شدن سشن همچنان باز بمانند.

با فعال‌سازی قابلیت Kick، سرویس مستر دستورهای احراز هویت‌شده را از طریق HTTPS و امضای HMAC-SHA256 برای ایجنت‌های نصب‌شده روی نودها ارسال می‌کند.

1. **مسدودسازی در فایروال:** IP متخلف در جدول `inet teperip` با اولویت `-300` مسدود می‌شود و قانون دارای Timeout پس از پایان جریمه منقضی می‌شود.
2. **قطع سوکت‌ها:** سوکت‌های TCP فعال مربوط به IP متخلف با `ss -K` بسته می‌شوند.

> **محافظت هوشمند:** ایجنت باید از مسدودسازی IPهای خصوصی، Loopback، IP سرور مستر و IPهای خود نود جلوگیری کند.

#### گام اول: دریافت دستور نصب از سرور مستر

1. روی سرور مستر دستور `teperip` را اجرا کنید.
2. گزینه `12) Kick Settings (node agents)` را انتخاب کنید.
3. گزینه `2) Show node install command` را انتخاب کنید.
4. IP عمومی سرور مستر را تأیید کنید.
5. دستور نصب اختصاصی نمایش‌داده‌شده را کپی کنید.

#### گام دوم: نصب روی سرورهای نود

دستور تولیدشده روی سرور مستر شبیه نمونه زیر است. مقادیر Token و IP باید با اطلاعات واقعی خودتان جایگزین شوند:

```bash
curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-agent-install.sh | sudo bash -s -- --token YOUR_TOKEN --master-ip MASTER_IP --port 8765
```

**مهم:** دستور واقعی تولیدشده از پنل مستر را اجرا کنید؛ از مقادیر نمونه بالا استفاده نکنید.

این دستور را روی تک‌تک سرورهای Node با دسترسی `root` اجرا کنید.

برای نودهای دارای RAM کمتر از 1GB، در صورت نیاز می‌توانید از گزینه `--prebuilt` مطابق پشتیبانی اسکریپت نصب استفاده کنید.

**نود لوکال روی سرور پنل:** اگر روی خود سرور پنل نیز Node فعال دارید، ایجنت را روی همان سرور نصب کنید و در منوی Kick، گزینه `8) Add extra agent URL` را انتخاب کرده و آدرس زیر را اضافه کنید:

```text
https://127.0.0.1:8765
```

#### گام سوم: تست اتصال و فعال‌سازی

1. در سرور مستر وارد منوی `teperip` شوید.
2. گزینه `12) Kick Settings (node agents)` را انتخاب کنید.
3. گزینه `3) Test agents (health check)` را اجرا کنید.
4. مطمئن شوید آدرس هر ایجنت با وضعیت `OK` نمایش داده می‌شود.
5. گزینه `1) Enable / Disable kick` را انتخاب کنید تا حالت `Mode` روی `agents` قرار بگیرد.

نمونه خروجی مورد انتظار:

```text
OK  https://node1.example.com:8765  {"nft":true,"ok":true,"ss":true,"version":"1.0.0"}
```

#### دستورات مدیریتی ایجنت

روی هر سرور Node:

```bash
teperip-agent status
teperip-agent list
teperip-agent logs
teperip-agent unblock-all
teperip-agent restart
teperip-agent uninstall
```

- `status`: مشاهده وضعیت سرویس و قوانین nftables
- `list`: مشاهده IPهای مسدودشده
- `logs`: مشاهده لاگ زنده
- `unblock-all`: آزادسازی تمام IPهای مسدودشده
- `restart`: راه‌اندازی مجدد ایجنت
- `uninstall`: حذف ایجنت و قوانین مرتبط

---

### 💾 Database

مسیر دیتابیس SQLite:

```text
/opt/pg_iplimit/teperip.db
```

اطلاعاتی که دیتابیس برای نگهداری وضعیت Blockها استفاده می‌کند، می‌تواند شامل موارد زیر باشد:

- Username و User ID کاربران غیرفعال‌شده توسط TeperIP
- دلیل غیرفعال‌سازی (`ip_limit` یا `anti_abuse`)
- زمان شروع Block و مدت جریمه

پس از پایان جریمه و فعال‌سازی مجدد کاربر، رکورد مربوطه طبق منطق برنامه پاک می‌شود.

---

### 🧠 IP Stability

برای جلوگیری از تشخیص اشتباه هنگام تغییر شبکه، IP جدید باید در چند سیکل بررسی متوالی مشاهده شود تا به‌عنوان IP پایدار در نظر گرفته شود.

مقادیر پیش‌فرض:

```text
Stable Checks Required = 2
Penalty Duration = 300s (5 minutes)
Tolerance (Grace Period) = 60s
```

شمارنده پایداری بر اساس شماره سیکل بررسی عمل می‌کند تا تأخیر در اجرای یک سیکل به‌تنهایی باعث Reset شدن شمارنده نشود.

---

### ♾️ کاربران Unlimited و 🚨 Anti-Abuse

کاربرانی که `hwid_limit <= 0` دارند، در محدودیت IP عادی Unlimited محسوب می‌شوند؛ بااین‌حال، در صورت فعال‌بودن Anti-Abuse ممکن است رفتار آن‌ها همچنان بررسی شود.

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

نحوه عملکرد مورد انتظار:

```text
20 IP جدید در 60 ثانیه  →  1 Strike
3 Strike در 30 دقیقه    →  Temporary Disable
مدت جریمه                →  1 ساعت
پایان جریمه              →  Auto Re-enable
```

---

### 🛠️ مدیریت سرور مستر

برای باز کردن منوی مدیریت:

```bash
teperip
```

گزینه‌های منو:

1. Status
2. Live Logs
3. Restart Service
4. Start Service
5. Stop Service
6. Edit Config
7. Anti-Abuse Settings
8. Backup Config
9. Uninstall
10. Check for Updates
11. Active TeperIP Blocks
12. Kick Settings (node agents)

برای حذف کامل، دستورالعمل منو را دنبال کنید و فقط در صورت اطمینان تأیید نهایی را انجام دهید.

---

### 📁 مسیر فایل‌ها

**سرور مستر:**

```text
/opt/pg_iplimit/
/opt/pg_iplimit/config.json
/opt/pg_iplimit/teperip.db
/opt/pg_iplimit/runtime_state.json
/opt/pg_iplimit/pg_ip_limit
/etc/systemd/system/pg_iplimit.service
/usr/local/bin/teperip
```

**سرور Node Agent:**

```text
/opt/teperip-agent/
/etc/teperip-agent/
/etc/systemd/system/teperip-agent.service
/usr/local/bin/teperip-agent
```

---

## 🇬🇧 English

### ✨ Features

- Automatic PasarGuard online-user monitoring
- Unique active IP tracking across all nodes
- Stable IP comparison against `hwid_limit`
- Instant node kick using `ss -K` and temporary `nftables` blocking
- Cycle-based IP stability
- Grace period for temporary network changes
- Anti-abuse detection for sudden bursts of new IP addresses
- Persistent block and runtime state
- Automatic re-enable after penalties, subject to application logic
- Concurrent workers using Goroutines
- `systemd` service integration and journal log management
- Interactive management menu through `teperip`
- GitHub update checker
- SQLite database for persistent block records
- Live block inspection, logs, backups, configuration editing, and uninstall

---

### 📥 Installation (Master / Panel Server)

Run the following command as `root` on the master server:

```bash
curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh -o /tmp/teperip-install.sh && sed -i 's/\r$//' /tmp/teperip-install.sh && chmod +x /tmp/teperip-install.sh && bash /tmp/teperip-install.sh
```

The installer runs interactively and requests the required configuration.

Back up your existing configuration and database before updating an existing installation.

### ⚡ Node Agent / Instant Kick

The Node Agent can receive authenticated commands from the master server over HTTPS using HMAC-SHA256 authentication.

It can:

1. Add temporary IPv4/IPv6 blocking rules to `table inet teperip`.
2. Terminate matching active TCP sockets using `ss -K`.

The agent should protect private and loopback addresses, the master's IP, and the node's own IP addresses from accidental blocking.

#### Install the agent

Generate the actual installation command on the master server:

1. Run `teperip`.
2. Select `12) Kick Settings (node agents)`.
3. Select `2) Show node install command`.
4. Confirm the master's public IP.
5. Copy the generated command and run it as `root` on each node.

The generated command follows this format:

```bash
curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-agent-install.sh | sudo bash -s -- --token YOUR_TOKEN --master-ip MASTER_IP --port 8765
```

Use the real token and master IP from the generated command. Do not use the example values.

#### Verify the agent

From the master menu, select:

- `12) Kick Settings (node agents)`
- `3) Test agents (health check)`
- `1) Enable / Disable kick`

Verify that the agents report `OK` before enabling kick mode.

#### Agent CLI

```bash
teperip-agent status
teperip-agent list
teperip-agent logs
teperip-agent unblock-all
teperip-agent restart
teperip-agent uninstall
```

### 🧠 IP Stability Defaults

```text
Stable Checks Required = 2
Penalty Duration = 300 seconds
Grace Period = 60 seconds
```

### 🚨 Anti-Abuse Defaults

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

### 🛠️ Management Menu

Run:

```bash
teperip
```

Menu options:

1. Status
2. Live Logs
3. Restart Service
4. Start Service
5. Stop Service
6. Edit Config
7. Anti-Abuse Settings
8. Backup Config
9. Uninstall
10. Check for Updates
11. Active TeperIP Blocks
12. Kick Settings (node agents)

### 📁 Installation Paths

**Master Server:**

```text
/opt/pg_iplimit/
/opt/pg_iplimit/config.json
/opt/pg_iplimit/teperip.db
/opt/pg_iplimit/runtime_state.json
/opt/pg_iplimit/pg_ip_limit
/etc/systemd/system/pg_iplimit.service
/usr/local/bin/teperip
```

**Node Agent:**

```text
/opt/teperip-agent/
/etc/teperip-agent/
/etc/systemd/system/teperip-agent.service
/usr/local/bin/teperip-agent
```

---

## 📌 Repository

GitHub: https://github.com/Jyavaz68/teperip
