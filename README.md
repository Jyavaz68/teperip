# TeperIP 🚀

**PasarGuard IP Limit, Anti-Abuse & Instant Node Kick Monitor (v1.4.0)**

مانیتور سبک، خودکار و پیشرفته برای اعمال محدودیت IP، مقابله با سوءاستفاده (Anti-Abuse) و قطع آنی اتصالات فعال روی نودها (Node Agent Kick) در پنل **PasarGuard**.

TeperIP کاربران آنلاین پنل را بررسی می‌کند، تعداد IPهای فعال و پایدار هر کاربر را با مقدار `hwid_limit` مقایسه کرده و در صورت تخلف، علاوه بر غیرفعال‌سازی موقت اکانت در پنل، می‌تواند از طریق **ایجنت نودها** در همان لحظه سوکت‌های باز کاربر متخلف را قطع و IP او را در لایه کرنل (`nftables`) مسدود کند.

---

## 🇮🇷 فارسی

### ✨ امکانات

- بررسی خودکار کاربران آنلاین PasarGuard (فقط کاربران فعال برای کاهش مصرف منابع)
- دریافت و محاسبه IPهای فعال و یکتای کاربر روی تمام Nodeها
- مقایسه تعداد IPهای پایدار با `hwid_limit`
- **⚡ سیستم قطع آنی اتصال روی نودها (Node Agent / Kick):** بستن فوری سوکت‌های فعال (`ss -K`) و مسدودسازی موقت IP متخلف در فایروال نود (`nftables` در زنجیره `prerouting` با اولویت `-300` قبل از NAT داکر)
- **سیستم IP Stability مبتنی بر سیکل:** جلوگیری از تشخیص اشتباه در اثر تغییرات موقت IP، Reconnect یا طولانی شدن سیکل‌های بررسی
- **سیستم تلرانس (Grace Period):** جلوگیری از قطع اشتباه کاربران به دلیل نشست‌های موقت یا تغییر شبکه و پاکسازی خودکار کاربران آفلاین
- **سیستم پیشرفته Anti-Abuse:** شناسایی هجوم ناگهانی IPهای جدید (لو رفتن کانفیگ) و جریمه موقت متخلفین
- **حفظ وضعیت (State Persistence):** حفظ وضعیت جریمه‌ها، IP History و اطلاعات Anti-Abuse حتی پس از ری‌استارت سرور
- غیرفعال کردن خودکار کاربر متخلف و فعال‌سازی مجدد او پس از پایان زمان جریمه (به همراه Rollback خودکار در صورت خطای دیتابیس)
- استفاده از چندین Worker هم‌زمان (Goroutines) برای افزایش سرعت بررسی
- اجرای پایدار به صورت `systemd service` همراه با مدیریت حجم لاگ‌های `journald`
- منوی مدیریتی تعاملی و قدرتمند با دستور `teperip`
- **سیستم آپدیت‌چکر هوشمند:** امکان بررسی و دریافت نسخه جدید از GitHub بدون از دست رفتن تنظیمات و دیتابیس
- **SQLite Database:** ذخیره امن Blockهای فعال TeperIP
- امکان مشاهده زنده کاربران مسدودشده و زمان باقی‌مانده جریمه (Active TeperIP Blocks)
- امکان مشاهده Live Logs، تهیه Backup، ویرایش تنظیمات و Uninstall کامل

---

### 📥 نصب (سرور مستر / پنل)

برای نصب روی سرور اصلی (یا سروری که به API پنل دسترسی دارد)، دستور زیر را اجرا کنید:

```bash
curl -fsSL [https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh](https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh) -o /tmp/teperip-install.sh && sed -i 's/\r$//' /tmp/teperip-install.sh && chmod +x /tmp/teperip-install.sh && bash /tmp/teperip-install.sh
```

نصب به صورت مرحله‌به‌مرحله انجام می‌شود و اطلاعات موردنیاز را از شما دریافت می‌کند.
اگر TeperIP از قبل نصب شده باشد، Database، تنظیمات و وضعیت موجود به صورت خودکار حفظ و به نسخه جدید مهاجرت (Migrate) داده می‌شوند.

### 🔑 موارد موردنیاز

- سرور Linux با دسترسی `root`
- پنل PasarGuard (آدرس پنل، نام کاربری و رمز عبور Admin)
- دسترسی اینترنت

---

### ⚡ آموزش راه‌اندازی سیستم قطع آنی روی نودها (Node Agent / Kick)

در حالت عادی، وقتی کاربری در پنل غیرفعال (Disable) می‌شود، اتصالات قبلی او (به‌ویژه در پروتکل‌های WebSocket و gRPC) ممکن است تا زمان قطع شدن کامل سشن همچنان باز بمانند و ترافیک مصرف کنند.
با فعال‌سازی قابلیت **Kick**، سرویس مستر به محض مسدود کردن کاربر، لیست IPهای فعال او را به صورت موازی و رمزنگاری‌شده (HTTPS + امضای HMAC-SHA256) برای ایجنتِ نصب‌شده روی نودها ارسال می‌کند تا:
1. **در فایروال (`nftables`):** آی‌پی متخلف در جدول `inet teperip` (با اولویت `-300` قبل از داکر) دقیقاً به مدت زمان جریمه مسدود شود و پس از اتمام جریمه، خودکار توسط کرنل آزاد گردد.
2. **در سطح سوکت (`ss -K`):** تمام سوکت‌ها و کانکشن‌های بازِ آن آی‌پی در همان ثانیه بسته شوند.

> **محافظت هوشمند:** ایجنت هرگز آی‌پی‌های خصوصی (Private/Loopback)، آی‌پی سرور مستر و آی‌پی‌های خودِ سرور نود را مسدود نمی‌کند.

#### مراحل راه‌اندازی گام‌به‌گام:

**گام اول: دریافت دستور نصب از سرور مستر**
1. روی سرور مستر دستور `teperip` را بزنید و گزینه **`12) Kick Settings (node agents)`** را انتخاب کنید.
2. گزینه **`2) Show node install command`** را بزنید.
3. اسکریپت آی‌پی عمومی سرور مستر شما را تشخیص می‌دهد؛ دکمه `Enter` را بزنید تا تایید شود.
4. یک دستور کامل حاوی توکن اختصاصی و آی‌پی مستر به شما نمایش داده می‌شود:

```bash
curl -fsSL [https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-agent-install.sh](https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-agent-install.sh) | sudo bash -s -- --token <YOUR_TOKEN> --master-ip <MASTER_IP> --port 8765
```

**گام دوم: نصب ایجنت روی سرورهای نود (Node)**
- دستور دریافت‌شده در گام قبل را کپی کرده و در ترمینال **تک‌تک سرورهای نود** خود (با دسترسی `root`) اجرا کنید.
- *نکته برای سرورهای با رم پایین (زیر ۱ گیگابایت):* اسکریپت به صورت خودکار رم پایین را تشخیص می‌دهد، اما می‌توانید فلگ `--prebuilt` را نیز به انتهای دستور اضافه کنید.
- *نکته برای نود لوکال روی سرور پنل:* اگر روی خودِ سرور پنل هم نود فعال دارید، دستور بالا را روی سرور پنل نیز اجرا کنید و سپس در منوی Kick گزینه **`8) Add extra agent URL`** را زده و آدرس `https://127.0.0.1:8765` را اضافه نمایید.

**گام سوم: تست اتصال و فعال‌سازی**
1. پس از نصب ایجنت روی نودها، در منوی `Kick Settings` سرور مستر، گزینه **`3) Test agents (health check)`** را بزنید تا جلوی آدرس نودهای خود عبارت `OK` را مشاهده کنید:
   ```text
   OK    [https://node1.example.com:8765](https://node1.example.com:8765)  {"nft":true,"ok":true,"ss":true,"version":"1.0.0"}
   ```
2. در نهایت گزینه **`1) Enable / Disable kick`** را بزنید تا وضعیت `Mode` به `agents` تغییر کند و سیستم فعال شود.

#### دستورات مدیریتی ایجنت روی سرورهای نود:

روی هر سرور نود می‌توانید با دستور `teperip-agent` وضعیت ایجنت و آی‌پی‌های مسدودشده را مدیریت کنید:

```bash
teperip-agent status        # مشاهده وضعیت سرویس و قوانین جدول nftables
teperip-agent list          # مشاهده لیست IPهای مسدودشده فعلی (IPv4 و IPv6)
teperip-agent logs          # مشاهده لاگ زنده ایجنت روی نود
teperip-agent unblock-all   # آزادسازی فوری تمام IPهای مسدودشده روی نود
teperip-agent restart       # ری‌استارت سرویس ایجنت
teperip-agent uninstall     # حذف کامل ایجنت، قوانین nftables و پورت فایروال
```

---

### 💾 Database

TeperIP از یک **SQLite Database سبک** در مسیر زیر برای نگهداری اطلاعات مهم استفاده می‌کند:

`/opt/pg_iplimit/teperip.db`

این دیتابیس موارد زیر را نگهداری می‌کند:
- Username و User ID کاربران غیرفعال‌شده توسط TeperIP
- دلیل غیرفعال شدن کاربر (`ip_limit` یا `anti_abuse`)
- زمان شروع Block و مدت زمان جریمه

> TeperIP فقط Blockهای فعال را در Database نگهداری می‌کند. پس از پایان جریمه و فعال‌سازی مجدد کاربر، رکورد مربوطه به صورت خودکار پاک می‌شود. در هنگام Update نیز دیتابیس و تنظیمات کاملاً حفظ می‌شوند.

---

### 🧠 IP Stability

برای جلوگیری از تشخیص اشتباه هنگام تغییر شبکه (مثلاً جابه‌جایی بین Wi-Fi و دیتای موبایل)، یک IP جدید بلافاصله به عنوان IP پایدار شمارش نمی‌شود و باید در چند سیکل بررسی متوالی حضور داشته باشد.

به صورت پیش‌فرض:
```text
Stable Checks Required = 2
Penalty Duration = 300s (5 minutes)
Tolerance (Grace Period) = 60s
```

شمارنده پایداری بر اساس **شماره سیکل متوالی (Cycle Counter)** کار می‌کند؛ بنابراین اگر به دلیل شلوغی سرور یک سیکل بررسی کمی طولانی‌تر شود، شمارنده ریست نمی‌شود و دقت سیستم حفظ می‌گردد. همچنین به محض آفلاین شدن کاربر، شمارنده‌ها و مهلت‌های قبلی او پاک می‌شوند.

---

### ♾️ کاربران Unlimited و 🚨 Anti-Abuse

کاربرانی که مقدار `hwid_limit <= 0` داشته باشند، **Unlimited** محسوب شده و مشمول IP Limit عادی نمی‌شوند، اما در صورت فعال بودن **Anti-Abuse**، رفتار آن‌ها برای کشف لو رفتن کانفیگ یا حملات بررسی می‌شود.

تنظیمات پیش‌فرض Anti-Abuse:
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
20 IP جدید در 60 ثانیه  ←  1 Strike
3 Strike در 30 دقیقه    ←  Temporary Disable (مدت جریمه: 1 ساعت) + Kick روی نودها
پایان 1 ساعت            ←  Auto Re-enable
```

---

### 🛠️ مدیریت (سرور مستر)

برای باز کردن منوی مدیریت روی سرور اصلی، دستور زیر را وارد کنید:

```bash
teperip
```

گزینه‌های منوی مدیریت:
1. **Status:** مشاهده نسخه، وضعیت سرویس، پنل، Anti-Abuse، وضعیت Kick و تعداد کاربران مسدودشده
2. **Live Logs:** مشاهده زنده لاگ‌های سرویس (`journalctl -u pg_iplimit.service -f`)
3. **Restart Service:** راه‌اندازی مجدد سرویس
4. **Start Service:** روشن کردن سرویس
5. **Stop Service:** متوقف کردن سرویس
6. **Edit Config:** ویرایش مستقیم فایل `config.json` و ری‌استارت خودکار
7. **Anti-Abuse Settings:** منوی اختصاصی تغییر پارامترهای Anti-Abuse
8. **Backup Config:** تهیه نسخه پشتیبان از تنظیمات
9. **Uninstall:** حذف کامل سرویس و فایل‌ها (با تایپ عبارت `REMOVE`)
10. **Check for Updates:** بررسی و نصب خودکار نسخه جدید از GitHub بدون حذف دیتابیس و تنظیمات
11. **Active TeperIP Blocks:** مشاهده لیست کاربران مسدودشده در لحظه، دلیل مسدودیت و ثانیه‌های باقی‌مانده
12. **Kick Settings (node agents):** مدیریت کامل ایجنت نودها، دریافت دستور نصب، تست سلامت نودها و تنظیمات مسدودسازی

---

### 📁 مسیر فایل‌ها

**سرور مستر (پنل):**
- پوشه اصلی: `/opt/pg_iplimit/`
- فایل تنظیمات: `/opt/pg_iplimit/config.json`
- دیتابیس SQLite: `/opt/pg_iplimit/teperip.db`
- وضعیت زمان اجرا: `/opt/pg_iplimit/runtime_state.json`
- باینری اصلی: `/opt/pg_iplimit/pg_ip_limit`
- سرویس systemd: `/etc/systemd/system/pg_iplimit.service`
- دستور منو: `/usr/local/bin/teperip`

**سرور نود (Node Agent):**
- پوشه باینری و سورس: `/opt/teperip-agent/`
- پوشه تنظیمات و گواهی TLS: `/etc/teperip-agent/`
- سرویس systemd: `/etc/systemd/system/teperip-agent.service`
- دستور خط فرمان: `/usr/local/bin/teperip-agent`

---
---

## 🇬🇧 English

### ✨ Features

- Automatic PasarGuard online-user monitoring (checks only online users to minimize resource usage)
- Retrieves and counts unique active IPs across all PasarGuard nodes
- Compares stable IP count with `hwid_limit`
- **⚡ Instant Node Kick System (Node Agent):** Immediately terminates established sockets (`ss -K`) and blocks offending IPs at the kernel firewall level (`nftables` in `prerouting` hook at priority `-300`, before Docker NAT)
- **Cycle-Based IP Stability:** Prevents false positives caused by temporary IP changes, reconnects, or slow API cycles
- **Grace Period / Tolerance:** Prevents unnecessary user disabling during temporary network handoffs and automatically cleans up offline users
- **Advanced Anti-Abuse Protection:** Detects sudden bursts of new IP addresses (e.g., leaked configs) and applies temporary bans
- **State & SQLite Persistence:** Preserves active blocks, IP history, and Anti-Abuse state across restarts and updates (with automatic rollback if database write fails)
- Concurrent workers (Goroutines) for fast, non-blocking cycle checks
- Runs as a stable `systemd` service with pre-configured `journald` log rotation
- Interactive management menu via the `teperip` command
- **Smart Update Checker:** Seamlessly updates from GitHub while migrating existing configurations and active blocks

---

### 📥 Installation (Master / Panel Server)

Run this command as `root` on your panel/master server:

```bash
curl -fsSL [https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh](https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh) -o /tmp/teperip-install.sh && sed -i 's/\r$//' /tmp/teperip-install.sh && chmod +x /tmp/teperip-install.sh && bash /tmp/teperip-install.sh
```

If TeperIP is already installed, your existing SQLite database, panel credentials, configuration, and runtime state are automatically backed up and migrated.

---

### ⚡ Node Agent / Instant Kick System (Optional)

When PasarGuard disables a user via API, already-established connections (such as long-lived WebSocket or gRPC streams) may remain open on the nodes.
The **TeperIP Node Agent** solves this by listening for authenticated commands (HTTPS + HMAC-SHA256 + timestamp/nonce replay protection) from the Master server to:
1. **Block in `nftables`:** Adds the offending IPv4/IPv6 addresses to `table inet teperip` (`prerouting` priority `-300`, acting before Docker NAT) with a kernel-enforced timeout matching the user's penalty duration.
2. **Kill Active Sockets (`ss -K`):** Immediately destroys established TCP sockets to those IPs so active connections drop instantly.

> **Safety Guards:** The agent automatically refuses to block private/loopback addresses, the master server's IP, or any IP assigned to the node itself.

#### Step-by-Step Setup:

1. **Generate the Install Command on Master:**
   Run `teperip` on your master server, select **`12) Kick Settings (node agents)`**, and then select **`2) Show node install command`**. Confirm your master server's public IP when prompted. It will output a ready-to-run command:
   ```bash
   curl -fsSL [https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-agent-install.sh](https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-agent-install.sh) | sudo bash -s -- --token <YOUR_TOKEN> --master-ip <MASTER_IP> --port 8765
   ```
2. **Install on Every Node Server:**
   Run the generated command as `root` on each of your PasarGuard node servers.
   - *Low-RAM Nodes (<1GB RAM):* The installer automatically tries prebuilt binaries on low-memory systems without swap, or you can pass `--prebuilt`.
   - *Shared Panel + Node Server:* If your master server also acts as a node, run the agent installer on the master server as well and add `https://127.0.0.1:8765` via option **`8) Add extra agent URL`**.
3. **Test & Enable:**
   Back in the master's `Kick Settings` menu, select **`3) Test agents (health check)`** to verify connectivity (`OK`), then select **`1) Enable / Disable kick`** to set the mode to `agents`.

#### Node Agent CLI Commands:

On any node server, use `teperip-agent`:

```bash
teperip-agent status        # Service status and nftables ruleset
teperip-agent list          # List currently blocked IPv4/IPv6 addresses
teperip-agent logs          # Follow live agent logs
teperip-agent unblock-all   # Flush all blocked IPs immediately
teperip-agent restart       # Restart the agent service
teperip-agent uninstall     # Cleanly remove service, nft table, and firewall rules
```

---

### 🧠 IP Stability & Grace Period

A newly detected IP must appear in multiple consecutive monitoring cycles before counting toward `hwid_limit`:

- **Stable Checks Required:** `2` cycles (default)
- **Tolerance (Grace Period):** `60` seconds (default)
- **IP Limit Penalty Duration:** `300` seconds / 5 minutes (default for new installations)

---

### 🚨 Anti-Abuse (Unlimited Users)

Users with `hwid_limit <= 0` are treated as Unlimited and monitored by the Anti-Abuse engine for sudden bursts of new IPs:

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

---

### 🛠️ Management Menu (`teperip`)

Run `teperip` on the master server to access:

1. **Status**
2. **Live Logs** (`journalctl -u pg_iplimit.service -f`)
3. **Restart Service**
4. **Start Service**
5. **Stop Service**
6. **Edit Config**
7. **Anti-Abuse Settings**
8. **Backup Config**
9. **Uninstall** (confirm with `REMOVE`)
10. **Check for Updates**
11. **Active TeperIP Blocks** (view currently disabled users and remaining penalty time)
12. **Kick Settings (node agents)**

---

### 📁 Installation Paths

**Master Server:**
- Directory: `/opt/pg_iplimit/`
- Config: `/opt/pg_iplimit/config.json`
- SQLite Database: `/opt/pg_iplimit/teperip.db`
- Runtime State: `/opt/pg_iplimit/runtime_state.json`
- Binary: `/opt/pg_iplimit/pg_ip_limit`
- Service: `/etc/systemd/system/pg_iplimit.service`
- Menu Command: `/usr/local/bin/teperip`

**Node Server (Agent):**
- Directory: `/opt/teperip-agent/`
- Config & TLS Certs: `/etc/teperip-agent/`
- Service: `/etc/systemd/system/teperip-agent.service`
- CLI Command: `/usr/local/bin/teperip-agent`

---

## 📌 Repository

GitHub: [https://github.com/Jyavaz68/teperip](https://github.com/Jyavaz68/teperip)

