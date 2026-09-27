#!/bin/bash

set -u

INSTALL_DIR="/opt/pg_iplimit"
GO_SRC_FILE="$INSTALL_DIR/main.go"
GO_MOD_FILE="$INSTALL_DIR/go.mod"
BINARY_FILE="$INSTALL_DIR/pg_ip_limit"
CONFIG_FILE="$INSTALL_DIR/config.json"
STATE_FILE="$INSTALL_DIR/.install_state.json"
SERVICE_FILE="/etc/systemd/system/pg_iplimit.service"
BACKUP_DIR="$INSTALL_DIR/backups"
MENU_FILE="/usr/local/bin/teperip"

mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"

# =================================================
# BASIC FUNCTIONS
# =================================================

pause() {
    echo
    read -rp "Press Enter to continue..."
}

die() {
    echo
    echo "[ERROR] $1"
    echo
    pause
    exit 1
}

save_state() {
    STATE_STAGE="$1" \
    PG_PANEL_URL="${PANEL_URL:-}" \
    PG_ADMIN_USER="${ADMIN_USER:-}" \
    PG_ADMIN_PASS="${ADMIN_PASS:-}" \
    PG_CHECK_INTERVAL="${CHECK_INTERVAL:-30}" \
    python3 - <<'PY'
import os
import json

data = {
    "stage": int(os.environ.get("STATE_STAGE", "1")),
    "panel_url": os.environ.get("PG_PANEL_URL", ""),
    "admin_user": os.environ.get("PG_ADMIN_USER", ""),
    "admin_pass": os.environ.get("PG_ADMIN_PASS", ""),
    "check_interval": os.environ.get("PG_CHECK_INTERVAL", "30")
}

with open("/opt/pg_iplimit/.install_state.json", "w") as f:
    json.dump(data, f, indent=4)

os.chmod("/opt/pg_iplimit/.install_state.json", 0o600)
PY

    chmod 600 "$STATE_FILE"
}

load_state() {
    if [ ! -f "$STATE_FILE" ]; then
        return
    fi

    eval "$(
        python3 - <<'PY'
import json

try:
    with open("/opt/pg_iplimit/.install_state.json", "r") as f:
        d = json.load(f)

    def q(v):
        return "'" + str(v).replace("'", "'\"'\"'") + "'"

    print("INSTALL_STAGE=" + q(d.get("stage", 1)))
    print("PANEL_URL=" + q(d.get("panel_url", "")))
    print("ADMIN_USER=" + q(d.get("admin_user", "")))
    print("ADMIN_PASS=" + q(d.get("admin_pass", "")))
    print("CHECK_INTERVAL=" + q(d.get("check_interval", "30")))

except Exception:
    print("INSTALL_STAGE='1'")
PY
)"
}

normalize_url() {
    local url="$1"

    url="${url//[[:space:]]/}"

    if [[ "$url" == http//* ]]; then
        url="http://$url"
    elif [[ "$url" == https//* ]]; then
        url="https://$url"
    elif [[ "$url" != http://* && "$url" != https://* ]]; then
        url="https://$url"
    fi

    url="${url%/}"
    url="${url%/kavpar}"

    echo "$url"
}

valid_url() {
    local url="$1"
    [[ "$url" =~ ^https?://[^/[:space:]]+(:[0-9]+)?$ ]]
}

valid_interval() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]
}

# =================================================
# ROOT CHECK
# =================================================

if [ "$(id -u)" != "0" ]; then
    echo "[ERROR] Run this installer as root."
    exit 1
fi

# =================================================
# INITIAL VARIABLES
# =================================================

INSTALL_STAGE=1
PANEL_URL=""
ADMIN_USER=""
ADMIN_PASS=""
CHECK_INTERVAL="30"

# =================================================
# LOAD PREVIOUS STATE
# =================================================

load_state

if [ "${INSTALL_STAGE:-1}" -gt 1 ]; then
    echo
    echo "=============================================="
    echo " Previous installation progress detected"
    echo "=============================================="
    echo
    echo "Installer will continue from stage: $INSTALL_STAGE"
    echo
    read -rp "Press Enter to continue..."
fi

clear

echo "=============================================="
echo "    TeperIP - PasarGuard IP Limit"
echo "=============================================="
echo
echo "[*] Installation directory:"
echo "    $INSTALL_DIR"
echo

# =================================================
# PACKAGES
# =================================================

echo "=============================================="
echo " Preparing required packages"
echo "=============================================="
echo

apt-get update -y || die "apt-get update failed."

apt-get install -y \
    python3 \
    golang-go \
    curl \
    nano \
    ca-certificates \
    || die "Required packages could not be installed."

GO_BIN="$(command -v go)"

if [ -z "$GO_BIN" ]; then
    die "Go toolchain could not be found."
fi

GO_VERSION_FULL="$(go version | awk '{print $3}')"
GO_VERSION_NUM="${GO_VERSION_FULL#go}"
GO_MOD_VERSION="$(echo "$GO_VERSION_NUM" | cut -d. -f1,2)"

if [ -z "$GO_MOD_VERSION" ]; then
    GO_MOD_VERSION="1.18"
fi

echo "[OK] Required packages are ready."
echo "[*] Go version: $(go version)"
echo

# =================================================
# STAGE 1 - PANEL CONFIGURATION
# =================================================

if [ "${INSTALL_STAGE:-1}" -le 1 ]; then

    while true; do

        clear

        echo "=============================================="
        echo " Stage 1/7 - Panel configuration"
        echo "=============================================="
        echo
        echo "Example:"
        echo "https://panel.example.com:2096"
        echo

        read -rp "Panel URL: " INPUT_PANEL_URL

        PANEL_URL="$(normalize_url "$INPUT_PANEL_URL")"

        if ! valid_url "$PANEL_URL"; then
            echo
            echo "[ERROR] Invalid Panel URL format."
            echo
            echo "Example:"
            echo "https://panel.example.com:2096"
            echo
            continue
        fi

        read -rp "Admin Username: " ADMIN_USER

        read -rsp "Admin Password: " ADMIN_PASS
        echo

        read -rp "Check interval in seconds [30]: " INPUT_INTERVAL

        if [ -z "$INPUT_INTERVAL" ]; then
            CHECK_INTERVAL="30"
        else
            CHECK_INTERVAL="$INPUT_INTERVAL"
        fi

        if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
            echo
            echo "[ERROR] Username and Password cannot be empty."
            echo
            continue
        fi

        if ! valid_interval "$CHECK_INTERVAL"; then
            echo
            echo "[ERROR] Check interval must be a positive integer."
            echo
            continue
        fi

        save_state 2
        INSTALL_STAGE=2

        break
    done
fi

# =================================================
# STAGE 2 - API TEST
# =================================================

if [ "${INSTALL_STAGE:-1}" -le 2 ]; then

    while true; do

        clear

        echo "=============================================="
        echo " Stage 2/7 - Testing PasarGuard API"
        echo "=============================================="
        echo

        TOKEN="$(
            PG_PANEL_URL="$PANEL_URL" \
            PG_ADMIN_USER="$ADMIN_USER" \
            PG_ADMIN_PASS="$ADMIN_PASS" \
            python3 - <<'PY'
import json
import os
import sys
import urllib.request
import urllib.parse

url = os.environ["PG_PANEL_URL"].rstrip("/") + "/api/admin/token"

data = urllib.parse.urlencode({
    "username": os.environ["PG_ADMIN_USER"],
    "password": os.environ["PG_ADMIN_PASS"]
}).encode()

req = urllib.request.Request(
    url,
    data=data,
    headers={
        "Content-Type": "application/x-www-form-urlencoded"
    },
    method="POST"
)

try:
    with urllib.request.urlopen(req, timeout=10) as resp:

        if resp.status != 200:
            sys.exit(1)

        body = json.loads(resp.read().decode())
        token = body.get("access_token", "")

        if not token:
            sys.exit(1)

        print(token)

except Exception:
    sys.exit(1)
PY
        )"

        if [ -n "$TOKEN" ]; then

            echo "[OK] PasarGuard API login successful."

            ONLINE_COUNT="$(
                PG_PANEL_URL="$PANEL_URL" \
                PG_TOKEN="$TOKEN" \
                python3 - <<'PY'
import json
import os
import sys
import urllib.request
import urllib.parse

base_url = os.environ["PG_PANEL_URL"].rstrip("/")
url = base_url + "/api/users?" + urllib.parse.urlencode({
    "online": "true"
})

req = urllib.request.Request(
    url,
    headers={
        "Authorization": "Bearer " + os.environ["PG_TOKEN"]
    }
)

try:
    with urllib.request.urlopen(req, timeout=10) as resp:

        if resp.status != 200:
            sys.exit(1)

        data = json.loads(resp.read().decode())
        users = data.get("users", [])

        print(len(users))

except Exception:
    sys.exit(1)
PY
            )"

            if [ -n "$ONLINE_COUNT" ]; then

                echo "[OK] Online users API is working."
                echo "[*] Current online users: $ONLINE_COUNT"

                save_state 3
                INSTALL_STAGE=3

                break

            else

                echo
                echo "[ERROR] /api/users?online=true test failed."
                echo
                read -rp "Try again? [Y/n]: " retry

                if [[ "$retry" =~ ^[Nn]$ ]]; then
                    exit 1
                fi

            fi

        else

            echo
            echo "[ERROR] PasarGuard API login failed."
            echo
            echo "Please check:"
            echo "  - Panel URL"
            echo "  - Admin username"
            echo "  - Admin password"
            echo

            read -rp "Return to Stage 1? [Y/n]: " retry

            if [[ "$retry" =~ ^[Nn]$ ]]; then
                exit 1
            fi

            save_state 1
            TMP_INSTALLER="/tmp/teperip-install.sh"
curl -fsSL "https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh" -o "$TMP_INSTALLER" || {
    echo "[ERROR] Failed to download installer again."
    exit 1
}
chmod +x "$TMP_INSTALLER"
exec bash "$TMP_INSTALLER"

        fi

    done
fi

# =================================================
# STAGE 3 - SAVE CONFIG
# =================================================

if [ "${INSTALL_STAGE:-1}" -le 3 ]; then

    clear

    echo "=============================================="
    echo " Stage 3/7 - Creating configuration"
    echo "=============================================="
    echo

    PG_PANEL_URL="$PANEL_URL" \
    PG_ADMIN_USER="$ADMIN_USER" \
    PG_ADMIN_PASS="$ADMIN_PASS" \
    PG_CHECK_INTERVAL="$CHECK_INTERVAL" \
    python3 - <<'PY'
import os
import json

data = {
    "panel_url": os.environ["PG_PANEL_URL"],
    "admin_user": os.environ["PG_ADMIN_USER"],
    "admin_pass": os.environ["PG_ADMIN_PASS"],
    "check_interval": int(os.environ["PG_CHECK_INTERVAL"]),
    "penalty_seconds": 60,
    "request_timeout": 10,
    "max_workers": 5,
    "verbose": False
}

with open("/opt/pg_iplimit/config.json", "w") as f:
    json.dump(data, f, indent=4)

os.chmod("/opt/pg_iplimit/config.json", 0o600)
PY

    echo "[OK] Config created."

    save_state 4
    INSTALL_STAGE=4
fi

# =================================================
# STAGE 4 - GO MONITOR
# =================================================

if [ "${INSTALL_STAGE:-1}" -le 4 ]; then

    clear

    echo "=============================================="
    echo " Stage 4/7 - Building Go monitor"
    echo "=============================================="
    echo

    cat > "$GO_MOD_FILE" <<GOMOD
module teperip

go $GO_MOD_VERSION
GOMOD

    cat > "$GO_SRC_FILE" <<'GO_SOURCE'
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

const configFile = "/opt/pg_iplimit/config.json"

type Config struct {
	PanelURL       string `json:"panel_url"`
	AdminUser      string `json:"admin_user"`
	AdminPass      string `json:"admin_pass"`
	CheckInterval  int    `json:"check_interval"`
	PenaltySeconds int    `json:"penalty_seconds"`
	RequestTimeout int    `json:"request_timeout"`
	MaxWorkers     int    `json:"max_workers"`
	Verbose        bool   `json:"verbose"`
}

type User struct {
	ID       int
	Username string
	Limit    int
}

type CheckResult struct {
	User      User
	ActiveIPs map[string]struct{}
}

var (
	cfg          Config
	httpClient   *http.Client

	tokenMu      sync.Mutex
	currentToken string

	blockedMu    sync.Mutex
	blockedUsers = make(map[int]time.Time)
)

func loadConfig() Config {

	data, err := os.ReadFile(configFile)

	if err != nil {
		log.Fatalf("[ERROR] Cannot read config: %v", err)
	}

	var c Config

	if err := json.Unmarshal(data, &c); err != nil {
		log.Fatalf("[ERROR] Cannot parse config: %v", err)
	}

	if c.CheckInterval <= 0 {
		c.CheckInterval = 30
	}

	if c.PenaltySeconds <= 0 {
		c.PenaltySeconds = 60
	}

	if c.RequestTimeout <= 0 {
		c.RequestTimeout = 10
	}

	if c.MaxWorkers <= 0 {
		c.MaxWorkers = 5
	}

	c.PanelURL = strings.TrimRight(c.PanelURL, "/")

	return c
}

func logMsg(format string, args ...interface{}) {
	fmt.Printf(format+"\n", args...)
}

func fetchToken() string {

	form := url.Values{}

	form.Set("username", cfg.AdminUser)
	form.Set("password", cfg.AdminPass)

	req, err := http.NewRequest(
		"POST",
		cfg.PanelURL+"/api/admin/token",
		strings.NewReader(form.Encode()),
	)

	if err != nil {
		return ""
	}

	req.Header.Set(
		"Content-Type",
		"application/x-www-form-urlencoded",
	)

	resp, err := httpClient.Do(req)

	if err != nil {
		return ""
	}

	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return ""
	}

	var data struct {
		AccessToken string `json:"access_token"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return ""
	}

	return data.AccessToken
}

func getToken(forceRefresh bool) string {

	tokenMu.Lock()
	defer tokenMu.Unlock()

	if currentToken == "" || forceRefresh {
		currentToken = fetchToken()
	}

	return currentToken
}

func doAuthed(
	buildReq func(token string) (*http.Request, error),
) (*http.Response, error) {

	token := getToken(false)

	if token == "" {
		return nil, fmt.Errorf("could not obtain API token")
	}

	req, err := buildReq(token)

	if err != nil {
		return nil, err
	}

	resp, err := httpClient.Do(req)

	if err != nil {
		return nil, err
	}

	if resp.StatusCode == http.StatusUnauthorized {

		resp.Body.Close()

		token = getToken(true)

		if token == "" {
			return nil, fmt.Errorf("token refresh failed")
		}

		req, err = buildReq(token)

		if err != nil {
			return nil, err
		}

		resp, err = httpClient.Do(req)
	}

	return resp, err
}

func getOnlineUsers() ([]User, error) {

	resp, err := doAuthed(func(token string) (*http.Request, error) {

		req, err := http.NewRequest(
			"GET",
			cfg.PanelURL+"/api/users?online=true",
			nil,
		)

		if err != nil {
			return nil, err
		}

		req.Header.Set(
			"Authorization",
			"Bearer "+token,
		)

		return req, nil
	})

	if err != nil {
		return nil, err
	}

	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {

		return nil, fmt.Errorf(
			"online users API returned HTTP %d",
			resp.StatusCode,
		)
	}

	var data struct {

		Users []struct {
			ID       int         `json:"id"`
			Username string      `json:"username"`
			Limit    interface{} `json:"hwid_limit"`
			Status   string      `json:"status"`
		} `json:"users"`

	}

	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}

	validUsers := make(
		[]User,
		0,
		len(data.Users),
	)

	for _, u := range data.Users {

		if u.ID == 0 {
			continue
		}

		if u.Status == "disabled" {
			continue
		}

		if u.Limit == nil {
			continue
		}

		var limit int

		switch v := u.Limit.(type) {

		case float64:
			limit = int(v)

		case int:
			limit = v

		case string:

			var parsed int

			if _, err := fmt.Sscanf(v, "%d", &parsed); err != nil {
				continue
			}

			limit = parsed

		default:
			continue
		}

		if limit <= 0 {
			continue
		}

		username := u.Username

		if username == "" {
			username = fmt.Sprintf("%d", u.ID)
		}

		validUsers = append(
			validUsers,
			User{
				ID:       u.ID,
				Username: username,
				Limit:    limit,
			},
		)
	}

	return validUsers, nil
}

func getOnlineIPs(userID int) (map[string]struct{}, error) {

	resp, err := doAuthed(func(token string) (*http.Request, error) {

		endpoint := fmt.Sprintf(
			"%s/api/node/online_stats/%d/ip",
			cfg.PanelURL,
			userID,
		)

		req, err := http.NewRequest(
			"GET",
			endpoint,
			nil,
		)

		if err != nil {
			return nil, err
		}

		req.Header.Set(
			"Authorization",
			"Bearer "+token,
		)

		return req, nil
	})

	if err != nil {
		return nil, err
	}

	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {

		return nil, fmt.Errorf(
			"HTTP %d",
			resp.StatusCode,
		)
	}

	var data struct {

		Nodes map[string]struct {
			IPs map[string]interface{} `json:"ips"`
		} `json:"nodes"`

	}

	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}

	ips := make(map[string]struct{})

	for _, node := range data.Nodes {

		for ip := range node.IPs {

			if ip != "" {
				ips[ip] = struct{}{}
			}
		}
	}

	return ips, nil
}

func setUserDisabled(
	userID int,
	disabled bool,
) bool {

	body, err := json.Marshal(
		map[string]bool{
			"disabled": disabled,
		},
	)

	if err != nil {
		return false
	}

	resp, err := doAuthed(func(token string) (*http.Request, error) {

		endpoint := fmt.Sprintf(
			"%s/api/user/by-id/%d/disabled",
			cfg.PanelURL,
			userID,
		)

		req, err := http.NewRequest(
			"PUT",
			endpoint,
			bytes.NewReader(body),
		)

		if err != nil {
			return nil, err
		}

		req.Header.Set(
			"Authorization",
			"Bearer "+token,
		)

		req.Header.Set(
			"Content-Type",
			"application/json",
		)

		return req, nil
	})

	if err != nil {

		logMsg(
			"[ERROR] User %d update failed: %v",
			userID,
			err,
		)

		return false
	}

	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {

		logMsg(
			"[ERROR] User %d update failed: HTTP %d",
			userID,
			resp.StatusCode,
		)

		return false
	}

	return true
}

func isBlocked(userID int) bool {

	blockedMu.Lock()
	defer blockedMu.Unlock()

	_, ok := blockedUsers[userID]

	return ok
}

func checkUsers(users []User) []CheckResult {

	sem := make(
		chan struct{},
		cfg.MaxWorkers,
	)

	resultsCh := make(
		chan CheckResult,
		len(users),
	)

	var wg sync.WaitGroup

	for _, user := range users {

		if isBlocked(user.ID) {
			continue
		}

		wg.Add(1)

		go func(u User) {

			defer wg.Done()

			sem <- struct{}{}

			defer func() {
				<-sem
			}()

			ips, err := getOnlineIPs(u.ID)

			if err != nil {

				logMsg(
					"[ERROR] IP check failed for %s (%d): %v",
					u.Username,
					u.ID,
					err,
				)

				return
			}

			resultsCh <- CheckResult{
				User:      u,
				ActiveIPs: ips,
			}

		}(user)
	}

	wg.Wait()

	close(resultsCh)

	results := make(
		[]CheckResult,
		0,
		len(resultsCh),
	)

	for result := range resultsCh {
		results = append(
			results,
			result,
		)
	}

	return results
}

func handlePenaltyExpiry(now time.Time) {

	blockedMu.Lock()

	users := make(
		map[int]time.Time,
		len(blockedUsers),
	)

	for userID, blockedAt := range blockedUsers {
		users[userID] = blockedAt
	}

	blockedMu.Unlock()

	for userID, blockedAt := range users {

		if now.Sub(blockedAt) <
			time.Duration(cfg.PenaltySeconds)*time.Second {
			continue
		}

		logMsg(
			"[+] Penalty expired for user %d -> enabling...",
			userID,
		)

		if setUserDisabled(userID, false) {

			blockedMu.Lock()
			delete(blockedUsers, userID)
			blockedMu.Unlock()

			logMsg(
				"[OK] User %d enabled again.",
				userID,
			)
		}
	}
}

func runCycle() {

	cycleStart := time.Now()

	if getToken(false) == "" {

		logMsg(
			"[ERROR] Could not obtain API token.",
		)

		return
	}

	users, err := getOnlineUsers()

	if err != nil {

		logMsg(
			"[ERROR] Could not get online users: %v",
			err,
		)

		return
	}

	now := time.Now()

	handlePenaltyExpiry(now)

	logMsg(
		"[*] Online users returned by API: %d",
		len(users),
	)

	if len(users) == 0 {

		logMsg(
			"[*] No online users with IP limits found.",
		)

		return
	}

	logMsg(
		"[*] Checking %d ONLINE users with IP limits...",
		len(users),
	)

	results := checkUsers(users)

	exceeded := 0

	for _, result := range results {

		ipCount := len(result.ActiveIPs)

		if cfg.Verbose {

			logMsg(
				"[*] User %s (%d) -> IPs: %d / Limit: %d",
				result.User.Username,
				result.User.ID,
				ipCount,
				result.User.Limit,
			)
		}

		if ipCount <= result.User.Limit {
			continue
		}

		exceeded++

		logMsg("")
		logMsg(
			"[!] LIMIT EXCEEDED: %s (%d)",
			result.User.Username,
			result.User.ID,
		)

		logMsg(
			"[!] IPs: %d > Limit: %d",
			ipCount,
			result.User.Limit,
		)

		logMsg(
			"[!] Disabling user for %d seconds...",
			cfg.PenaltySeconds,
		)

		if setUserDisabled(
			result.User.ID,
			true,
		) {

			blockedMu.Lock()
			blockedUsers[result.User.ID] = now
			blockedMu.Unlock()

			logMsg(
				"[OK] User %s (%d) disabled.",
				result.User.Username,
				result.User.ID,
			)

		} else {

			logMsg(
				"[ERROR] Could not disable user %s (%d).",
				result.User.Username,
				result.User.ID,
			)
		}

		logMsg("")
	}

	logMsg(
		"[*] Cycle done in %.2fs | Checked: %d | Over limit: %d",
		time.Since(cycleStart).Seconds(),
		len(results),
		exceeded,
	)
}

func main() {

	cfg = loadConfig()

	httpClient = &http.Client{

		Timeout: time.Duration(
			cfg.RequestTimeout,
		) * time.Second,

		Transport: &http.Transport{

			MaxIdleConns:
				cfg.MaxWorkers * 2,

			MaxIdleConnsPerHost:
				cfg.MaxWorkers * 2,

			IdleConnTimeout:
				90 * time.Second,
		},
	}

	logMsg("")
	logMsg("==============================================")
	logMsg("      PasarGuard TeperIP Monitor Started")
	logMsg("==============================================")

	logMsg(
		"[*] Check interval: %ds | Penalty: %ds | Workers: %d",
		cfg.CheckInterval,
		cfg.PenaltySeconds,
		cfg.MaxWorkers,
	)

	sigCh := make(
		chan os.Signal,
		1,
	)

	signal.Notify(
		sigCh,
		os.Interrupt,
		syscall.SIGTERM,
	)

	ticker := time.NewTicker(
		time.Duration(
			cfg.CheckInterval,
		) * time.Second,
	)

	defer ticker.Stop()

	runCycle()

	for {

		select {

		case <-sigCh:

			logMsg("")
			logMsg("[*] TeperIP stopped.")

			return

		case <-ticker.C:

			runCycle()
		}
	}
}
GO_SOURCE

    echo "[*] Building Go monitor..."

    (
        cd "$INSTALL_DIR" &&
        HOME="${HOME:-/root}" \
        go build \
            -trimpath \
            -ldflags="-s -w" \
            -o "$BINARY_FILE" \
            "$GO_SRC_FILE"
    ) || die "Go build failed."

    chmod 755 "$BINARY_FILE"

    echo "[OK] Go monitor built successfully."
    echo

    save_state 5
    INSTALL_STAGE=5
fi

# =================================================
# STAGE 5 - SYSTEMD
# =================================================

if [ "${INSTALL_STAGE:-1}" -le 5 ]; then

    clear

    echo "=============================================="
    echo " Stage 5/7 - Installing systemd service"
    echo "=============================================="
    echo

    cat > "$SERVICE_FILE" <<SERVICE_FILE
[Unit]
Description=PasarGuard IP Limit Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BINARY_FILE
WorkingDirectory=$INSTALL_DIR

Restart=always
RestartSec=5

User=root

[Install]
WantedBy=multi-user.target
SERVICE_FILE

    chmod 644 "$SERVICE_FILE"

    systemctl daemon-reload

    systemctl enable pg_iplimit.service \
        >/dev/null 2>&1 \
        || die "Could not enable systemd service."

    echo "[OK] systemd service installed."

    save_state 6
    INSTALL_STAGE=6
fi

# =================================================
# STAGE 6 - MENU
# =================================================

if [ "${INSTALL_STAGE:-1}" -le 6 ]; then

    clear

    echo "=============================================="
    echo " Stage 6/7 - Installing TeperIP menu"
    echo "=============================================="
    echo

    cat > "$MENU_FILE" <<'MENU_BASH'
#!/bin/bash

INSTALL_DIR="/opt/pg_iplimit"
CONFIG_FILE="$INSTALL_DIR/config.json"
SERVICE="pg_iplimit.service"

while true; do

    clear

    echo "=============================================="
    echo "             TeperIP Control Panel"
    echo "=============================================="
    echo "  1) Status"
    echo "  2) Live Logs"
    echo "  3) Restart Service"
    echo "  4) Start Service"
    echo "  5) Stop Service"
    echo "  6) Edit Config"
    echo "  7) Backup Config"
    echo "  8) Uninstall"
    echo "  0) Exit"
    echo "=============================================="

    read -rp "Select: " c

    case "$c" in

        1)
            systemctl status "$SERVICE" --no-pager
            read -rp "Press Enter..."
            ;;

        2)
            journalctl -u "$SERVICE" -f
            ;;

        3)
            systemctl restart "$SERVICE"

            if systemctl is-active --quiet "$SERVICE"; then
                echo "[OK] Service restarted."
            else
                echo "[ERROR] Service failed to start."
            fi

            read -rp "Press Enter..."
            ;;

        4)
            systemctl start "$SERVICE"

            if systemctl is-active --quiet "$SERVICE"; then
                echo "[OK] Service started."
            else
                echo "[ERROR] Service failed to start."
            fi

            read -rp "Press Enter..."
            ;;

        5)
            systemctl stop "$SERVICE"
            echo "[OK] Service stopped."
            read -rp "Press Enter..."
            ;;

        6)
            nano "$CONFIG_FILE"
            systemctl restart "$SERVICE"
            ;;

        7)
            mkdir -p "$INSTALL_DIR/backups"

            BACKUP_FILE="$INSTALL_DIR/backups/config-$(date +%Y%m%d-%H%M%S).json"

            cp "$CONFIG_FILE" "$BACKUP_FILE"
            chmod 600 "$BACKUP_FILE"

            echo
            echo "[OK] Backup created:"
            echo "$BACKUP_FILE"

            read -rp "Press Enter..."
            ;;

        8)
            echo
            read -rp "Are you sure you want to uninstall? [y/N]: " confirm

            if [[ "$confirm" =~ ^[Yy]$ ]]; then

                systemctl disable --now "$SERVICE" \
                    >/dev/null 2>&1 || true

                rm -f "/etc/systemd/system/$SERVICE"

                systemctl daemon-reload

                rm -f "$MENU_FILE"

                rm -rf "$INSTALL_DIR"

                echo
                echo "TeperIP uninstalled."

                exit 0
            fi
            ;;

        0)
            exit 0
            ;;

        *)
            echo "Invalid option."
            sleep 1
            ;;

    esac

done
MENU_BASH

    chmod 755 "$MENU_FILE"

    echo "[OK] TeperIP menu installed."

    save_state 7
    INSTALL_STAGE=7
fi

# =================================================
# STAGE 7 - START SERVICE
# =================================================

if [ "${INSTALL_STAGE:-1}" -le 7 ]; then

    clear

    echo "=============================================="
    echo " Stage 7/7 - Starting TeperIP"
    echo "=============================================="
    echo

    systemctl daemon-reload

    systemctl restart pg_iplimit.service \
        || die "Could not start TeperIP service."

    sleep 2

    if ! systemctl is-active --quiet pg_iplimit.service; then

        echo
        echo "[ERROR] TeperIP service is not running."
        echo
        echo "Last logs:"
        echo

        journalctl \
            -u pg_iplimit.service \
            -n 30 \
            --no-pager

        echo
        pause
        exit 1
    fi

    rm -f "$STATE_FILE"

    echo
    echo "=============================================="
    echo "       TeperIP Installation Completed"
    echo "=============================================="
    echo
    echo "[OK] Service is running."
    echo
    echo "Use:"
    echo
    echo "    teperip"
    echo
    echo "Live logs:"
    echo
    echo "    journalctl -u pg_iplimit.service -f"
    echo
fi
