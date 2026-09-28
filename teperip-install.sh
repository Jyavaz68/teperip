#!/usr/bin/env bash
set -euo pipefail

CURRENT_VERSION="1.3.1"

INSTALL_DIR="/opt/pg_iplimit"
CONFIG_FILE="$INSTALL_DIR/config.json"
STATE_FILE="$INSTALL_DIR/runtime_state.json"
GO_SRC_FILE="$INSTALL_DIR/main.go"
GO_MOD_FILE="$INSTALL_DIR/go.mod"
BINARY_FILE="$INSTALL_DIR/pg_ip_limit"

SERVICE_NAME="pg_iplimit.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
MENU_FILE="/usr/local/bin/teperip"

BACKUP_DIR="$INSTALL_DIR/backups"
INSTALL_STATE_FILE="$INSTALL_DIR/.install_state.json"

INSTALLER_URL="https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh"
GITHUB_RELEASES_URL="https://api.github.com/repos/Jyavaz68/teperip/releases/latest"
EXAMPLE_PANEL_URL="https://panel.example.com:8000"

GO_MIN_MAJOR=1
GO_MIN_MINOR=18

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        err "این اسکریپت باید با root اجرا شود."
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

pause_menu() {
    echo
    read -r -p "برای ادامه Enter بزنید... " _
}

normalize_url() {
    echo "${1%/}"
}

is_valid_url() {
    [[ "$1" =~ ^https?://[^[:space:]]+$ ]]
}

ensure_dependencies() {
    local missing=()
    local cmd

    for cmd in curl jq systemctl awk sed grep tar; do
        command_exists "$cmd" || missing+=("$cmd")
    done

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    log "وابستگی‌های موردنیاز نصب می‌شوند: ${missing[*]}"

    if command_exists apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl jq systemd coreutils tar ca-certificates
    elif command_exists dnf; then
        dnf install -y curl jq systemd coreutils tar ca-certificates
    elif command_exists yum; then
        yum install -y curl jq systemd coreutils tar ca-certificates
    else
        err "مدیر بسته پشتیبانی‌شده پیدا نشد."
        exit 1
    fi
}

go_version_string() {
    go version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || true
}

go_version_ok() {
    local version major minor

    version="$(go_version_string)"
    [[ -n "$version" ]] || return 1

    major="${version%%.*}"

    local rest="${version#*.}"
    minor="${rest%%.*}"

    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    [[ "$minor" =~ ^[0-9]+$ ]] || return 1

    if (( major > GO_MIN_MAJOR )); then
        return 0
    fi

    (( major == GO_MIN_MAJOR && minor >= GO_MIN_MINOR ))
}

install_latest_go_official() {
    local arch latest_go tarball tmp_dir url

    case "$(uname -m)" in
        x86_64|amd64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            err "معماری $(uname -m) برای نصب خودکار Go پشتیبانی نمی‌شود."
            return 1
            ;;
    esac

    if ! command_exists jq; then
        err "jq برای دریافت نسخه پایدار Go لازم است."
        return 1
    fi

    log "در حال دریافت آخرین نسخه پایدار Go برای Linux/$arch ..."

    latest_go="$(
        curl -fsSL \
            --max-time 15 \
            'https://go.dev/dl/?mode=json' |
            jq -r '[.[] | select(.stable == true)][0].version // empty'
    )" || true

    [[ -n "$latest_go" && "$latest_go" != "null" ]] || {
        err "نسخه Go از go.dev دریافت نشد."
        return 1
    }

    url="https://go.dev/dl/${latest_go}.linux-${arch}.tar.gz"

    tarball="$(mktemp /tmp/go.XXXXXX.tar.gz)"
    tmp_dir="$(mktemp -d /tmp/go-install.XXXXXX)"

    cleanup_go_tmp() {
        rm -f "$tarball"
        rm -rf "$tmp_dir"
    }

    trap cleanup_go_tmp RETURN

    log "دانلود $latest_go ..."

    curl -fL \
        --retry 3 \
        --connect-timeout 10 \
        --max-time 120 \
        "$url" \
        -o "$tarball"

    tar -xzf "$tarball" -C "$tmp_dir"

    [[ -x "$tmp_dir/go/bin/go" ]] || {
        err "فایل Go معتبر نیست."
        return 1
    }

    if [[ -d /usr/local/go ]]; then
        mv /usr/local/go "/usr/local/go.backup.$(date +%Y%m%d%H%M%S)"
    fi

    rm -rf /usr/local/go

    mv "$tmp_dir/go" /usr/local/go

    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

    export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"
    hash -r 2>/dev/null || true

    if ! go_version_ok; then
        err "Go نصب شد اما نسخه آن حداقل 1.18 نیست: $(go_version_string)"
        return 1
    fi

    ok "Go آماده است: $(go version)"
}

ensure_go() {
    export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"

    if command_exists go && go_version_ok; then
        ok "Go موجود است: $(go version)"
        return 0
    fi

    if command_exists go; then
        warn "نسخه Go فعلی قدیمی است: $(go version 2>/dev/null || true)"
    else
        warn "Go روی سیستم نصب نیست."
    fi

    if command_exists apt-get; then
        log "تلاش برای نصب Go از مخزن سیستم..."
        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y golang-go >/dev/null 2>&1 || true

        export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"
        hash -r 2>/dev/null || true

    elif command_exists dnf; then

        dnf install -y golang >/dev/null 2>&1 || true

        export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"
        hash -r 2>/dev/null || true

    elif command_exists yum; then

        yum install -y golang >/dev/null 2>&1 || true

        export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"
        hash -r 2>/dev/null || true
    fi

    if command_exists go && go_version_ok; then
        ok "Go آماده است: $(go version)"
        return 0
    fi

    install_latest_go_official
}

create_directories() {
    mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"

    chmod 700 "$INSTALL_DIR"
    chmod 700 "$BACKUP_DIR"
}

config_is_valid() {
    [[ -s "$CONFIG_FILE" ]] || return 1

    jq empty "$CONFIG_FILE" >/dev/null 2>&1 || return 1

    local panel_url panel_user panel_pass

    panel_url="$(
        jq -r '.panel_url // empty' "$CONFIG_FILE" 2>/dev/null || true
    )"

    panel_user="$(
        jq -r '.panel_user // empty' "$CONFIG_FILE" 2>/dev/null || true
    )"

    panel_pass="$(
        jq -r '.panel_pass // empty' "$CONFIG_FILE" 2>/dev/null || true
    )"

    [[ -n "$panel_url" && -n "$panel_user" && -n "$panel_pass" ]]
}

backup_existing() {
    local stamp backup_file files

    if [[ ! -f "$CONFIG_FILE" &&
          ! -f "$STATE_FILE" &&
          ! -f "$BINARY_FILE" ]]; then
        return 0
    fi

    stamp="$(date +%Y%m%d_%H%M%S)"
    backup_file="$BACKUP_DIR/teperip_$stamp.tar.gz"

    files=()

    for f in \
        config.json \
        runtime_state.json \
        main.go \
        go.mod \
        .install_state.json
    do
        [[ -e "$INSTALL_DIR/$f" ]] && files+=("$f")
    done

    if ((${#files[@]} > 0)); then
        tar -czf "$backup_file" \
            -C "$INSTALL_DIR" \
            "${files[@]}" \
            2>/dev/null || true

        chmod 600 "$backup_file" 2>/dev/null || true

        ok "نسخه قبلی در backup ذخیره شد: $backup_file"
    fi
}

migrate_config() {
    local tmp_file

    [[ -f "$CONFIG_FILE" ]] || return 0

    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        warn "config.json خراب است؛ برای ساخت تنظیمات جدید از شما اطلاعات پنل گرفته می‌شود."
        return 0
    fi

    tmp_file="$(mktemp)"

    jq \
        --arg version "$CURRENT_VERSION" \
        '
        .version = $version |

        .panel_url = (.panel_url // "") |
        .panel_user = (.panel_user // "") |
        .panel_pass = (.panel_pass // "") |

        .check_interval = (.check_interval // 30) |
        .tolerance_seconds = (.tolerance_seconds // 60) |
        .penalty_seconds = (.penalty_seconds // 60) |

        .request_timeout = (.request_timeout // 15) |
        .max_workers = (.max_workers // 5) |
        .verbose = (.verbose // false) |

        .anti_abuse = ((.anti_abuse // {}) + {
            enabled: ((.anti_abuse.enabled // true)),
            new_ip_threshold: ((.anti_abuse.new_ip_threshold // 20)),
            new_ip_window_seconds: ((.anti_abuse.new_ip_window_seconds // 60)),
            strike_threshold: ((.anti_abuse.strike_threshold // 3)),
            strike_window_seconds: ((.anti_abuse.strike_window_seconds // 1800)),
            ban_seconds: ((.anti_abuse.ban_seconds // 3600)),
            log_retention_seconds: ((.anti_abuse.log_retention_seconds // 86400)),
            max_events_per_user: ((.anti_abuse.max_events_per_user // 1000))
        }) |

        .journal_max_size = (.journal_max_size // "50M") |
        .journal_max_file_size = (.journal_max_file_size // "10M")
        ' \
        "$CONFIG_FILE" > "$tmp_file"

    chmod 600 "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
}

prompt_config() {
    local panel_url panel_user panel_pass
    local check_interval tolerance penalty timeout workers
    local input

    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "تنظیم اتصال PasarGuard"
    echo "مثال عمومی: $EXAMPLE_PANEL_URL"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    panel_url="$(
        jq -r '.panel_url // empty' "$CONFIG_FILE" 2>/dev/null || true
    )

    panel_user="$(
        jq -r '.panel_user // empty' "$CONFIG_FILE" 2>/dev/null || true
    )

    panel_pass="$(
        jq -r '.panel_pass // empty' "$CONFIG_FILE" 2>/dev/null || true
    )

    if [[ -z "$panel_url" ]]; then
        read -r -p "آدرس پنل: " panel_url
    else
        read -r -p "آدرس پنل [$panel_url]: " input
        panel_url="${input:-$panel_url}"
    fi

    panel_url="$(normalize_url "$panel_url")"

    if ! is_valid_url "$panel_url"; then
        err "آدرس پنل معتبر نیست."
        exit 1
    fi

    if [[ -z "$panel_user" ]]; then
        read -r -p "نام کاربری ادمین: " panel_user
    else
        read -r -p "نام کاربری ادمین [$panel_user]: " input
        panel_user="${input:-$panel_user}"
    fi

    if [[ -z "$panel_pass" ]]; then
        read -r -s -p "رمز عبور ادمین: " panel_pass
        echo
    else
        read -r -s -p "رمز عبور ادمین (برای حفظ قبلی Enter): " input
        echo
        panel_pass="${input:-$panel_pass}"
    fi

    check_interval="$(
        jq -r '.check_interval // 30' "$CONFIG_FILE" 2>/dev/null || echo 30
    )

    tolerance="$(
        jq -r '.tolerance_seconds // 60' "$CONFIG_FILE" 2>/dev/null || echo 60
    )

    penalty="$(
        jq -r '.penalty_seconds // 60' "$CONFIG_FILE" 2>/dev/null || echo 60
    )

    timeout="$(
        jq -r '.request_timeout // 15' "$CONFIG_FILE" 2>/dev/null || echo 15
    )

    workers="$(
        jq -r '.max_workers // 5' "$CONFIG_FILE" 2>/dev/null || echo 5
    )

    read -r -p "فاصله بررسی (ثانیه) [$check_interval]: " input
    check_interval="${input:-$check_interval}"

    read -r -p "زمان تحمل IP Limit (ثانیه) [$tolerance]: " input
    tolerance="${input:-$tolerance}"

    read -r -p "مدت Disable برای IP Limit (ثانیه) [$penalty]: " input
    penalty="${input:-$penalty}"

    read -r -p "Timeout درخواست API (ثانیه) [$timeout]: " input
    timeout="${input:-$timeout}"

    read -r -p "تعداد Worker [$workers]: " input
    workers="${input:-$workers}"

    jq -n \
        --arg version "$CURRENT_VERSION" \
        --arg panel_url "$panel_url" \
        --arg panel_user "$panel_user" \
        --arg panel_pass "$panel_pass" \
        --argjson check_interval "$check_interval" \
        --argjson tolerance_seconds "$tolerance" \
        --argjson penalty_seconds "$penalty" \
        --argjson request_timeout "$timeout" \
        --argjson max_workers "$workers" \
        '{
            version: $version,
            panel_url: $panel_url,
            panel_user: $panel_user,
            panel_pass: $panel_pass,

            check_interval: $check_interval,
            tolerance_seconds: $tolerance_seconds,
            penalty_seconds: $penalty_seconds,

            request_timeout: $request_timeout,
            max_workers: $max_workers,
            verbose: false,

            anti_abuse: {
                enabled: true,
                new_ip_threshold: 20,
                new_ip_window_seconds: 60,
                strike_threshold: 3,
                strike_window_seconds: 1800,
                ban_seconds: 3600,
                log_retention_seconds: 86400,
                max_events_per_user: 1000
            },

            journal_max_size: "50M",
            journal_max_file_size: "10M"
        }' > "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE"
}

create_initial_state() {
    if [[ ! -s "$STATE_FILE" ]] ||
       ! jq empty "$STATE_FILE" >/dev/null 2>&1
    then
        cat > "$STATE_FILE" <<'JSON'
{
  "blocked_users": {},
  "abuse": {},
  "ip_history": {}
}
JSON

        chmod 600 "$STATE_FILE"
    fi
}

write_go_source() {
cat > "$GO_SRC_FILE" <<'GO'
package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Config struct {
	Version            string          `json:"version"`
	PanelURL           string          `json:"panel_url"`
	PanelUser          string          `json:"panel_user"`
	PanelPass          string          `json:"panel_pass"`
	CheckInterval      int             `json:"check_interval"`
	ToleranceSeconds   int             `json:"tolerance_seconds"`
	PenaltySeconds     int             `json:"penalty_seconds"`
	RequestTimeout     int             `json:"request_timeout"`
	MaxWorkers         int             `json:"max_workers"`
	Verbose            bool            `json:"verbose"`
	AntiAbuse          AntiAbuseConfig `json:"anti_abuse"`
	JournalMaxSize     string          `json:"journal_max_size"`
	JournalMaxFileSize string          `json:"journal_max_file_size"`
}

type AntiAbuseConfig struct {
	Enabled             bool `json:"enabled"`
	NewIPThreshold      int  `json:"new_ip_threshold"`
	NewIPWindowSeconds  int  `json:"new_ip_window_seconds"`
	StrikeThreshold     int  `json:"strike_threshold"`
	StrikeWindowSeconds int  `json:"strike_window_seconds"`
	BanSeconds          int  `json:"ban_seconds"`
	LogRetentionSeconds int  `json:"log_retention_seconds"`
	MaxEventsPerUser    int  `json:"max_events_per_user"`
}

type User struct {
	ID        interface{} `json:"id"`
	Username  string      `json:"username"`
	HWIDLimit int         `json:"hwid_limit"`
	Disabled  bool        `json:"disabled"`
}

type AbuseEvent struct {
	IP   string `json:"ip,omitempty"`
	Time int64  `json:"time"`
}

type IPSeen struct {
	FirstSeen int64 `json:"first_seen"`
	LastSeen  int64 `json:"last_seen"`
}

type UserAbuseState struct {
	NewIPs  []AbuseEvent `json:"new_ips"`
	Strikes []AbuseEvent `json:"strikes"`
}

type BlockedUser struct {
	BlockedAt int64 `json:"blocked_at"`
	Duration  int64 `json:"duration_seconds"`
	AbuseBan  bool  `json:"abuse_ban"`
}

type RuntimeState struct {
	BlockedUsers map[string]BlockedUser      `json:"blocked_users"`
	Abuse        map[string]UserAbuseState   `json:"abuse"`
	IPHistory    map[string]map[string]IPSeen `json:"ip_history"`
}

type APIClient struct {
	BaseURL  string
	Username string
	Password string
	Client   *http.Client

	Token   string
	tokenMu sync.RWMutex
	loginMu sync.Mutex

	Verbose bool
}

var (
	configPath = "/opt/pg_iplimit/config.json"
	statePath  = "/opt/pg_iplimit/runtime_state.json"

	stateMu = sync.Mutex{}

	logger = log.New(os.Stdout, "", log.LstdFlags)
)

func main() {
	cfg, err := loadConfig(configPath)
	if err != nil {
		logger.Fatalf("config error: %v", err)
	}

	normalizeConfig(&cfg)

	state, err := loadState(statePath)
	if err != nil {
		logger.Fatalf("state error: %v", err)
	}

	ensureStateMaps(&state)

	client, err := newAPIClient(cfg)
	if err != nil {
		logger.Fatalf("API client error: %v", err)
	}

	logger.Printf(
		"TeperIP %s started | interval=%ds workers=%d anti_abuse=%t",
		cfg.Version,
		cfg.CheckInterval,
		cfg.MaxWorkers,
		cfg.AntiAbuse.Enabled,
	)

	if err := client.login(); err != nil {
		logger.Printf("initial login failed: %v", err)
	} else {
		logger.Printf("API authentication successful")
	}

	ctxDone := make(chan os.Signal, 1)
	signal.Notify(ctxDone, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(ctxDone)

	ticker := time.NewTicker(time.Duration(cfg.CheckInterval) * time.Second)
	defer ticker.Stop()

	runCycle(client, &cfg, &state)

	for {
		select {
		case <-ticker.C:
			runCycle(client, &cfg, &state)

		case sig := <-ctxDone:
			logger.Printf(
				"received signal %s; saving state and exiting",
				sig,
			)

			if err := saveState(&state); err != nil {
				logger.Printf("state save failed: %v", err)
			}

			return
		}
	}
}

func normalizeConfig(cfg *Config) {
	if cfg.CheckInterval < 5 {
		cfg.CheckInterval = 30
	}

	if cfg.ToleranceSeconds < 0 {
		cfg.ToleranceSeconds = 60
	}

	if cfg.PenaltySeconds < 1 {
		cfg.PenaltySeconds = 60
	}

	if cfg.RequestTimeout < 1 {
		cfg.RequestTimeout = 15
	}

	if cfg.MaxWorkers < 1 {
		cfg.MaxWorkers = 5
	}

	if cfg.AntiAbuse.NewIPThreshold < 1 {
		cfg.AntiAbuse.NewIPThreshold = 20
	}

	if cfg.AntiAbuse.NewIPWindowSeconds < 1 {
		cfg.AntiAbuse.NewIPWindowSeconds = 60
	}

	if cfg.AntiAbuse.StrikeThreshold < 1 {
		cfg.AntiAbuse.StrikeThreshold = 3
	}

	if cfg.AntiAbuse.StrikeWindowSeconds < 1 {
		cfg.AntiAbuse.StrikeWindowSeconds = 1800
	}

	if cfg.AntiAbuse.BanSeconds < 1 {
		cfg.AntiAbuse.BanSeconds = 3600
	}

	if cfg.AntiAbuse.LogRetentionSeconds < 1 {
		cfg.AntiAbuse.LogRetentionSeconds = 86400
	}

	if cfg.AntiAbuse.MaxEventsPerUser < 10 {
		cfg.AntiAbuse.MaxEventsPerUser = 1000
	}
}

func loadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}

	var cfg Config

	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, err
	}

	if strings.TrimSpace(cfg.PanelURL) == "" ||
		strings.TrimSpace(cfg.PanelUser) == "" ||
		cfg.PanelPass == "" {
		return Config{}, errors.New(
			"panel_url, panel_user and panel_pass are required",
		)
	}

	cfg.PanelURL = strings.TrimRight(
		strings.TrimSpace(cfg.PanelURL),
		"/",
	)

	return cfg, nil
}

func loadState(path string) (RuntimeState, error) {
	data, err := os.ReadFile(path)

	if os.IsNotExist(err) {
		return RuntimeState{}, nil
	}

	if err != nil {
		return RuntimeState{}, err
	}

	var state RuntimeState

	if len(bytes.TrimSpace(data)) == 0 {
		return RuntimeState{}, nil
	}

	if err := json.Unmarshal(data, &state); err != nil {
		return RuntimeState{}, err
	}

	return state, nil
}

func ensureStateMaps(state *RuntimeState) {
	if state.BlockedUsers == nil {
		state.BlockedUsers = make(map[string]BlockedUser)
	}

	if state.Abuse == nil {
		state.Abuse = make(map[string]UserAbuseState)
	}

	if state.IPHistory == nil {
		state.IPHistory = make(map[string]map[string]IPSeen)
	}
}

func saveState(state *RuntimeState) error {
	stateMu.Lock()
	defer stateMu.Unlock()

	return saveStateLocked(state)
}

func saveStateLocked(state *RuntimeState) error {
	ensureStateMaps(state)

	data, err := json.MarshalIndent(
		state,
		"",
		"  ",
	)

	if err != nil {
		return err
	}

	dir := filepath.Dir(statePath)

	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}

	tmp, err := os.CreateTemp(
		dir,
		".runtime_state_*.tmp",
	)

	if err != nil {
		return err
	}

	tmpName := tmp.Name()

	defer os.Remove(tmpName)

	if err := tmp.Chmod(0600); err != nil {
		tmp.Close()
		return err
	}

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}

	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}

	if err := tmp.Close(); err != nil {
		return err
	}

	return os.Rename(
		tmpName,
		statePath,
	)
}

func newAPIClient(cfg Config) (*APIClient, error) {
	base := strings.TrimRight(
		strings.TrimSpace(cfg.PanelURL),
		"/",
	)

	if base == "" {
		return nil, errors.New("empty panel URL")
	}

	timeout := time.Duration(
		cfg.RequestTimeout,
	) * time.Second

	transport := &http.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true,
		},
		Proxy: http.ProxyFromEnvironment,
	}

	return &APIClient{
		BaseURL:  base,
		Username: cfg.PanelUser,
		Password: cfg.PanelPass,

		Client: &http.Client{
			Timeout:   timeout,
			Transport: transport,
		},

		Verbose: cfg.Verbose,
	}, nil
}

func (a *APIClient) getToken() string {
	a.tokenMu.RLock()
	defer a.tokenMu.RUnlock()

	return a.Token
}

func (a *APIClient) setToken(token string) {
	a.tokenMu.Lock()
	a.Token = token
	a.tokenMu.Unlock()
}

func (a *APIClient) login() error {
	a.loginMu.Lock()
	defer a.loginMu.Unlock()

	form := url.Values{}

	form.Set(
		"username",
		a.Username,
	)

	form.Set(
		"password",
		a.Password,
	)

	req, err := http.NewRequest(
		http.MethodPost,
		a.BaseURL+"/api/admin/token",
		strings.NewReader(form.Encode()),
	)

	if err != nil {
		return err
	}

	req.Header.Set(
		"Content-Type",
		"application/x-www-form-urlencoded",
	)

	req.Header.Set(
		"Accept",
		"application/json",
	)

	resp, err := a.Client.Do(req)

	if err != nil {
		return err
	}

	defer resp.Body.Close()

	body, _ := io.ReadAll(
		io.LimitReader(
			resp.Body,
			2<<20,
		),
	)

	if resp.StatusCode < 200 ||
		resp.StatusCode >= 300 {
		return fmt.Errorf(
			"login HTTP %d: %s",
			resp.StatusCode,
			trimBody(body),
		)
	}

	var result struct {
		AccessToken string `json:"access_token"`
		Token       string `json:"token"`
	}

	if err := json.Unmarshal(
		body,
		&result,
	); err != nil {
		return fmt.Errorf(
			"invalid login response: %w",
			err,
		)
	}

	token := result.AccessToken

	if token == "" {
		token = result.Token
	}

	if token == "" {
		return errors.New(
			"login response did not contain an access token",
		)
	}

	a.setToken(token)

	return nil
}

func (a *APIClient) do(
	method string,
	path string,
	body io.Reader,
	contentType string,
) (*http.Response, error) {

	var payload []byte
	var err error

	if body != nil {
		payload, err = io.ReadAll(body)

		if err != nil {
			return nil, err
		}
	}

	makeRequest := func() (*http.Request, error) {
		var reader io.Reader

		if payload != nil {
			reader = bytes.NewReader(payload)
		}

		req, err := http.NewRequest(
			method,
			a.BaseURL+path,
			reader,
		)

		if err != nil {
			return nil, err
		}

		req.Header.Set(
			"Accept",
			"application/json",
		)

		if contentType != "" {
			req.Header.Set(
				"Content-Type",
				contentType,
			)
		}

		if token := a.getToken(); token != "" {
			req.Header.Set(
				"Authorization",
				"Bearer "+token,
			)
		}

		return req, nil
	}

	req, err := makeRequest()

	if err != nil {
		return nil, err
	}

	resp, err := a.Client.Do(req)

	if err != nil {
		return nil, err
	}

	if resp.StatusCode != http.StatusUnauthorized {
		return resp, nil
	}

	resp.Body.Close()

	if err := a.login(); err != nil {
		return nil, err
	}

	req, err = makeRequest()

	if err != nil {
		return nil, err
	}

	return a.Client.Do(req)
}

func (a *APIClient) getJSON(
	path string,
	target interface{},
) error {

	resp, err := a.do(
		http.MethodGet,
		path,
		nil,
		"",
	)

	if err != nil {
		return err
	}

	defer resp.Body.Close()

	body, _ := io.ReadAll(
		io.LimitReader(
			resp.Body,
			10<<20,
		),
	)

	if resp.StatusCode < 200 ||
		resp.StatusCode >= 300 {
		return fmt.Errorf(
			"GET %s HTTP %d: %s",
			path,
			resp.StatusCode,
			trimBody(body),
		)
	}

	if err := json.Unmarshal(
		body,
		target,
	); err != nil {
		return fmt.Errorf(
			"decode %s: %w",
			path,
			err,
		)
	}

	return nil
}

func (a *APIClient) getOnlineUsers() ([]User, error) {
	var users []User

	if err := a.getJSON(
		"/api/users?online=true",
		&users,
	); err != nil {
		return nil, err
	}

	return users, nil
}

func (a *APIClient) getUserIPs(
	userID string,
) (map[string]struct{}, error) {

	var data struct {
		Nodes map[string]struct {
			IPs map[string]interface{} `json:"ips"`
		} `json:"nodes"`
	}

	if err := a.getJSON(
		"/api/node/online_stats/"+
			url.PathEscape(userID)+
			"/ip",
		&data,
	); err != nil {
		return nil, err
	}

	result := make(map[string]struct{})

	for _, node := range data.Nodes {
		for ip := range node.IPs {
			ip = strings.TrimSpace(ip)

			if ip != "" {
				result[ip] = struct{}{}
			}
		}
	}

	return result, nil
}

func (a *APIClient) setDisabled(
	userID string,
	disabled bool,
) error {

	payload := []byte(
		fmt.Sprintf(
			`{"disabled":%t}`,
			disabled,
		),
	)

	resp, err := a.do(
		http.MethodPut,
		"/api/user/by-id/"+
			url.PathEscape(userID)+
			"/disabled",
		bytes.NewReader(payload),
		"application/json",
	)

	if err != nil {
		return err
	}

	defer resp.Body.Close()

	body, _ := io.ReadAll(
		io.LimitReader(
			resp.Body,
			2<<20,
		),
	)

	if resp.StatusCode < 200 ||
		resp.StatusCode >= 300 {
		return fmt.Errorf(
			"disable=%t HTTP %d: %s",
			disabled,
			resp.StatusCode,
			trimBody(body),
		)
	}

	return nil
}

func runCycle(
	client *APIClient,
	cfg *Config,
	state *RuntimeState,
) {
	processExpiredBlocks(
		client,
		state,
	)

	users, err := client.getOnlineUsers()

	if err != nil {
		logger.Printf(
			"online users failed: %v",
			err,
		)
		return
	}

	sem := make(
		chan struct{},
		cfg.MaxWorkers,
	)

	var wg sync.WaitGroup

	for _, user := range users {
		user := user

		wg.Add(1)

		go func() {
			defer wg.Done()

			sem <- struct{}{}
			defer func() {
				<-sem
			}()

			processUser(
				client,
				cfg,
				state,
				user,
			)
		}()
	}

	wg.Wait()

	pruneState(
		cfg,
		state,
	)

	if err := saveState(state); err != nil {
		logger.Printf(
			"state save failed: %v",
			err,
		)
	}
}

func processUser(
	client *APIClient,
	cfg *Config,
	state *RuntimeState,
	user User,
) {
	userID := stringifyID(user.ID)

	if userID == "" {
		return
	}

	ips, err := client.getUserIPs(userID)

	if err != nil {
		if cfg.Verbose {
			logger.Printf(
				"user=%s IP lookup failed: %v",
				userID,
				err,
			)
		}
		return
	}

	if user.HWIDLimit > 0 {
		processIPLimit(
			client,
			cfg,
			state,
			user,
			userID,
			len(ips),
		)
		return
	}

	if cfg.AntiAbuse.Enabled {
		processAntiAbuse(
			client,
			cfg,
			state,
			user,
			userID,
			ips,
		)
	}
}

func processIPLimit(
	client *APIClient,
	cfg *Config,
	state *RuntimeState,
	user User,
	userID string,
	ipCount int,
) {
	if ipCount <= user.HWIDLimit {
		clearGrace(
			state,
			userID,
		)
		return
	}

	now := time.Now().Unix()

	stateMu.Lock()

	_, isBlocked := state.BlockedUsers[userID]

	stateMu.Unlock()

	if isBlocked {
		return
	}

	graceStart := getGraceStart(
		state,
		userID,
	)

	if graceStart == 0 {
		setGraceStart(
			state,
			userID,
			now,
		)

		logger.Printf(
			"IP LIMIT | user=%s username=%s ips=%d limit=%d | grace started",
			userID,
			user.Username,
			ipCount,
			user.HWIDLimit,
		)

		return
	}

	if now-graceStart <
		int64(cfg.ToleranceSeconds) {

		if cfg.Verbose {
			logger.Printf(
				"IP LIMIT | user=%s ips=%d limit=%d | grace %ds/%ds",
				userID,
				ipCount,
				user.HWIDLimit,
				now-graceStart,
				cfg.ToleranceSeconds,
			)
		}

		return
	}

	if err := client.setDisabled(
		userID,
		true,
	); err != nil {
		logger.Printf(
			"IP LIMIT | user=%s disable failed: %v",
			userID,
			err,
		)
		return
	}

	stateMu.Lock()

	state.BlockedUsers[userID] = BlockedUser{
		BlockedAt: now,
		Duration:  int64(cfg.PenaltySeconds),
		AbuseBan: false,
	}

	stateMu.Unlock()

	logger.Printf(
		"IP LIMIT | user=%s username=%s ips=%d limit=%d | disabled for %ds",
		userID,
		user.Username,
		ipCount,
		user.HWIDLimit,
		cfg.PenaltySeconds,
	)
}

func processAntiAbuse(
	client *APIClient,
	cfg *Config,
	state *RuntimeState,
	user User,
	userID string,
	ips map[string]struct{},
) {
	now := time.Now().Unix()

	stateMu.Lock()

	history := state.IPHistory[userID]

	if history == nil {
		history = make(map[string]IPSeen)
		state.IPHistory[userID] = history
	}

	abuse := state.Abuse[userID]

	cutoffHistory :=
		now -
			int64(
				cfg.AntiAbuse.LogRetentionSeconds,
			)

	for ip, seen := range history {
		if seen.LastSeen < cutoffHistory {
			delete(history, ip)
		}
	}

	newEvents := make(
		[]AbuseEvent,
		0,
	)

	for ip := range ips {
		seen, exists := history[ip]

		if !exists {
			history[ip] = IPSeen{
				FirstSeen: now,
				LastSeen:  now,
			}

			newEvents = append(
				newEvents,
				AbuseEvent{
					IP:   ip,
					Time: now,
				},
			)
		} else {
			seen.LastSeen = now
			history[ip] = seen
		}
	}

	abuse.NewIPs = append(
		abuse.NewIPs,
		newEvents...,
	)

	newCutoff :=
		now -
			int64(
				cfg.AntiAbuse.NewIPWindowSeconds,
			)

	abuse.NewIPs =
		pruneEvents(
			abuse.NewIPs,
			newCutoff,
		)

	strikeCutoff :=
		now -
			int64(
				cfg.AntiAbuse.StrikeWindowSeconds,
			)

	abuse.Strikes =
		pruneEventsKeepingGrace(
			abuse.Strikes,
			strikeCutoff,
		)

	newCount := len(abuse.NewIPs)

	strikeCreated := false
	shouldBan := false

	if newCount >=
		cfg.AntiAbuse.NewIPThreshold &&
		len(newEvents) > 0 {

		abuse.Strikes =
			append(
				abuse.Strikes,
				AbuseEvent{
					Time: now,
				},
			)

		strikeCreated = true

		abuse.NewIPs =
			consumeBurst(
				abuse.NewIPs,
				now,
			)

		abuse.Strikes =
			pruneEvents(
				abuse.Strikes,
				strikeCutoff,
			)

		if len(abuse.Strikes) >=
			cfg.AntiAbuse.StrikeThreshold {

			shouldBan = true
		}
	}

	state.Abuse[userID] = abuse

	currentStrikes := 0

	for _, event := range abuse.Strikes {
		if event.IP != "__ip_limit_grace__" &&
			event.Time >= strikeCutoff {
			currentStrikes++
		}
	}

	stateMu.Unlock()

	if len(newEvents) > 0 &&
		cfg.Verbose {

		logger.Printf(
			"ANTI-ABUSE | user=%s username=%s new_ips=%d window_count=%d",
			userID,
			user.Username,
			len(newEvents),
			newCount,
		)
	}

	if strikeCreated {
		logger.Printf(
			"ANTI-ABUSE | user=%s username=%s STRIKE %d/%d | new IP burst detected",
			userID,
			user.Username,
			currentStrikes,
			cfg.AntiAbuse.StrikeThreshold,
		)
	}

	if !shouldBan {
		return
	}

	stateMu.Lock()

	if _, alreadyBlocked :=
		state.BlockedUsers[userID]; alreadyBlocked {

		stateMu.Unlock()
		return
	}

	stateMu.Unlock()

	if err := client.setDisabled(
		userID,
		true,
	); err != nil {

		logger.Printf(
			"ANTI-ABUSE | user=%s disable failed: %v",
			userID,
			err,
		)

		return
	}

	stateMu.Lock()

	state.BlockedUsers[userID] = BlockedUser{
		BlockedAt: now,
		Duration:  int64(cfg.AntiAbuse.BanSeconds),
		AbuseBan: true,
	}

	abuse = state.Abuse[userID]

	abuse.Strikes = nil
	abuse.NewIPs = nil

	state.Abuse[userID] = abuse

	stateMu.Unlock()

	logger.Printf(
		"ANTI-ABUSE | user=%s username=%s TEMPORARILY DISABLED for %ds after %d strikes",
		userID,
		user.Username,
		cfg.AntiAbuse.BanSeconds,
		cfg.AntiAbuse.StrikeThreshold,
	)
}

func getGraceStart(
	state *RuntimeState,
	userID string,
) int64 {
	stateMu.Lock()
	defer stateMu.Unlock()

	abuse := state.Abuse[userID]

	for _, event := range abuse.Strikes {
		if event.IP == "__ip_limit_grace__" {
			return event.Time
		}
	}

	return 0
}

func setGraceStart(
	state *RuntimeState,
	userID string,
	now int64,
) {
	stateMu.Lock()
	defer stateMu.Unlock()

	abuse := state.Abuse[userID]

	for _, event := range abuse.Strikes {
		if event.IP == "__ip_limit_grace__" {
			return
		}
	}

	abuse.Strikes =
		append(
			abuse.Strikes,
			AbuseEvent{
				IP:   "__ip_limit_grace__",
				Time: now,
			},
		)

	state.Abuse[userID] = abuse
}

func clearGrace(
	state *RuntimeState,
	userID string,
) {
	stateMu.Lock()
	defer stateMu.Unlock()

	abuse := state.Abuse[userID]

	kept := abuse.Strikes[:0]

	for _, event := range abuse.Strikes {
		if event.IP != "__ip_limit_grace__" {
			kept = append(
				kept,
				event,
			)
		}
	}

	abuse.Strikes = kept

	if len(abuse.NewIPs) == 0 &&
		len(abuse.Strikes) == 0 {

		delete(
			state.Abuse,
			userID,
		)
	} else {
		state.Abuse[userID] = abuse
	}
}

func processExpiredBlocks(
	client *APIClient,
	state *RuntimeState,
) {
	now := time.Now().Unix()

	type expiredEntry struct {
		ID string
		B  BlockedUser
	}

	var expired []expiredEntry

	stateMu.Lock()

	for id, block :=
		range state.BlockedUsers {

		if block.BlockedAt <= 0 ||
			block.Duration <= 0 ||
			now-block.BlockedAt >= block.Duration {

			expired =
				append(
					expired,
					expiredEntry{
						ID: id,
						B:  block,
					},
				)
		}
	}

	stateMu.Unlock()

	for _, item := range expired {

		if err := client.setDisabled(
			item.ID,
			false,
		); err != nil {

			logger.Printf(
				"RE-ENABLE | user=%s failed: %v",
				item.ID,
				err,
			)

			continue
		}

		stateMu.Lock()

		delete(
			state.BlockedUsers,
			item.ID,
		)

		delete(
			state.Abuse,
			item.ID,
		)

		stateMu.Unlock()

		if item.B.AbuseBan {
			logger.Printf(
				"ANTI-ABUSE | user=%s temporary ban expired; user re-enabled",
				item.ID,
			)
		} else {
			logger.Printf(
				"IP LIMIT | user=%s penalty expired; user re-enabled",
				item.ID,
			)
		}
	}
}

func pruneState(
	cfg *Config,
	state *RuntimeState,
) {
	now := time.Now().Unix()

	historyCutoff :=
		now -
			int64(
				cfg.AntiAbuse.LogRetentionSeconds,
			)

	newCutoff :=
		now -
			int64(
				cfg.AntiAbuse.NewIPWindowSeconds,
			)

	strikeCutoff :=
		now -
			int64(
				cfg.AntiAbuse.StrikeWindowSeconds,
			)

	stateMu.Lock()
	defer stateMu.Unlock()

	for userID, abuse :=
		range state.Abuse {

		abuse.NewIPs =
			pruneEvents(
				abuse.NewIPs,
				newCutoff,
			)

		abuse.Strikes =
			pruneEventsKeepingGrace(
				abuse.Strikes,
				strikeCutoff,
			)

		if len(abuse.NewIPs) >
			cfg.AntiAbuse.MaxEventsPerUser {

			abuse.NewIPs =
				abuse.NewIPs[
					len(abuse.NewIPs)-
						cfg.AntiAbuse.MaxEventsPerUser:
				]
		}

		if len(abuse.Strikes) >
			cfg.AntiAbuse.MaxEventsPerUser {

			abuse.Strikes =
				abuse.Strikes[
					len(abuse.Strikes)-
						cfg.AntiAbuse.MaxEventsPerUser:
				]
		}

		if len(abuse.NewIPs) == 0 &&
			len(abuse.Strikes) == 0 {

			delete(
				state.Abuse,
				userID,
			)
		} else {
			state.Abuse[userID] = abuse
		}
	}

	for userID, history :=
		range state.IPHistory {

		for ip, seen :=
			range history {

			if seen.LastSeen <
				historyCutoff {

				delete(
					history,
					ip,
				)
			}
		}

		if len(history) == 0 {
			delete(
				state.IPHistory,
				userID,
			)
		}
	}
}

func pruneEvents(
	events []AbuseEvent,
	cutoff int64,
) []AbuseEvent {

	kept := events[:0]

	for _, event := range events {
		if event.Time >= cutoff {
			kept =
				append(
					kept,
					event,
				)
		}
	}

	return kept
}

func pruneEventsKeepingGrace(
	events []AbuseEvent,
	cutoff int64,
) []AbuseEvent {

	kept := events[:0]

	for _, event := range events {

		if event.IP == "__ip_limit_grace__" ||
			event.Time >= cutoff {

			kept =
				append(
					kept,
					event,
				)
		}
	}

	return kept
}

func consumeBurst(
	events []AbuseEvent,
	now int64,
) []AbuseEvent {

	kept := events[:0]

	for _, event := range events {
		if event.Time != now {
			kept =
				append(
					kept,
					event,
				)
		}
	}

	return kept
}

func stringifyID(id interface{}) string {
	switch value := id.(type) {

	case string:
		return value

	case float64:
		return strconv.FormatInt(
			int64(value),
			10,
		)

	case int:
		return strconv.Itoa(value)

	case int64:
		return strconv.FormatInt(
			value,
			10,
		)

	case json.Number:
		return value.String()

	default:
		return fmt.Sprint(value)
	}
}

func trimBody(body []byte) string {
	s := strings.TrimSpace(
		string(body),
	)

	if len(s) > 500 {
		return s[:500] + "..."
	}

	return s
}
GO

cat > "$GO_MOD_FILE" <<'MOD'
module teperip

go 1.18
MOD
}

build_binary() {
    ensure_go

    export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"

    cd "$INSTALL_DIR"

    gofmt -w "$GO_SRC_FILE"

    go mod tidy

    CGO_ENABLED=0 \
        go build \
        -trimpath \
        -ldflags='-s -w' \
        -o "$BINARY_FILE" \
        "$GO_SRC_FILE"

    chmod 700 "$BINARY_FILE"

    ok "TeperIP build شد: $BINARY_FILE"
}

create_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=PasarGuard TeperIP Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BINARY_FILE
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    chmod 644 "$SERVICE_FILE"

    systemctl daemon-reload

    systemctl enable \
        "$SERVICE_NAME" >/dev/null
}

configure_journald() {
    mkdir -p /etc/systemd/journald.conf.d

    cat > /etc/systemd/journald.conf.d/teperip.conf <<'EOF_JOURNAL'
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
RuntimeMaxUse=20M
RuntimeMaxFileSize=10M
MaxRetentionSec=7day
EOF_JOURNAL

    systemctl restart systemd-journald \
        >/dev/null 2>&1 || true
}

save_install_state() {
    jq -n \
        --arg version "$CURRENT_VERSION" \
        --arg installed_at "$(date -Is)" \
        --arg binary "$BINARY_FILE" \
        '{
            version:$version,
            installed_at:$installed_at,
            binary:$binary
        }' \
        > "$INSTALL_STATE_FILE"

    chmod 600 "$INSTALL_STATE_FILE"
}

test_api() {
    local panel_url panel_user panel_pass
    local response status token

    panel_url="$(
        jq -r '.panel_url // empty' "$CONFIG_FILE"
    )"

    panel_user="$(
        jq -r '.panel_user // empty' "$CONFIG_FILE"
    )"

    panel_pass="$(
        jq -r '.panel_pass // empty' "$CONFIG_FILE"
    )"

    log "تست اتصال به PasarGuard..."

    response="$(
        curl -k \
            -sS \
            --max-time 15 \
            -o /tmp/teperip_api_response \
            -w '%{http_code}' \
            -X POST \
            "$panel_url/api/admin/token" \
            -H 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode "username=$panel_user" \
            --data-urlencode "password=$panel_pass" \
            || true
    )"

    status="$response"

    token="$(
        jq -r \
            '.access_token // .token // empty' \
            /tmp/teperip_api_response \
            2>/dev/null ||
            true
    )"

    rm -f /tmp/teperip_api_response

    if [[ "$status" =~ ^2[0-9][0-9]$ &&
          -n "$token" ]]; then

        ok "احراز هویت API موفق بود."
        return 0
    fi

    warn "تست API موفق نبود. HTTP=$status"
    warn "سرویس نصب می‌شود، اما credentials یا آدرس پنل را بررسی کنید."

    return 1
}

read_config_value() {
    local filter="$1"
    local fallback="$2"

    if [[ -r "$CONFIG_FILE" ]] &&
       jq empty "$CONFIG_FILE" >/dev/null 2>&1
    then
        jq -r "$filter" \
            "$CONFIG_FILE" \
            2>/dev/null ||
            printf '%s' "$fallback"
    else
        printf '%s' "$fallback"
    fi
}

show_status() {
    clear

    echo -e \
        "${CYAN}━━━━━━━━━━━━ TeperIP Status ━━━━━━━━━━━━${NC}"

    local service_status
    local anti_abuse
    local panel_url
    local interval
    local workers
    local binary_version

    service_status="$(
        systemctl is-active \
            "$SERVICE_NAME" \
            2>/dev/null ||
            echo inactive
    )"

    panel_url="$(
        read_config_value \
            '.panel_url // "UNKNOWN"' \
            'UNKNOWN'
    )"

    interval="$(
        read_config_value \
            '.check_interval // "UNKNOWN"' \
            'UNKNOWN'
    )"

    workers="$(
        read_config_value \
            '.max_workers // "UNKNOWN"' \
            'UNKNOWN'
    )"

    binary_version="$(
        read_config_value \
            '.version // "UNKNOWN"' \
            'UNKNOWN'
    )"

    anti_abuse="UNKNOWN"

    if [[ -r "$CONFIG_FILE" ]] &&
       jq empty "$CONFIG_FILE" >/dev/null 2>&1
    then
        anti_abuse="$(
            jq -r \
                'if (.anti_abuse.enabled? // false)
                 then "ON"
                 else "OFF"
                 end' \
                "$CONFIG_FILE" \
                2>/dev/null ||
                echo UNKNOWN
        )"
    fi

    echo "Version:        $binary_version"
    echo "Service:        $service_status"
    echo "Panel:          $panel_url"
    echo "Interval:       ${interval}s"
    echo "Workers:        $workers"
    echo "Anti-Abuse:     $anti_abuse"
    echo "Binary:         $BINARY_FILE"
    echo "State:          $STATE_FILE"

    echo

    if [[ -r "$STATE_FILE" ]] &&
       jq empty "$STATE_FILE" >/dev/null 2>&1
    then
        echo "Blocked users:  $(
            jq \
                '.blocked_users // {} | length' \
                "$STATE_FILE" \
                2>/dev/null ||
                echo UNKNOWN
        )"

        echo "Tracked users:  $(
            jq \
                '.ip_history // {} | length' \
                "$STATE_FILE" \
                2>/dev/null ||
                echo UNKNOWN
        )"
    else
        echo "Runtime state:  UNKNOWN"
    fi
}

show_logs() {
    clear

    echo -e \
        "${CYAN}━━━━━━━━━━━━ Live Logs ━━━━━━━━━━━━${NC}"

    echo "برای خروج Ctrl+C بزنید."
    echo

    journalctl \
        -u "$SERVICE_NAME" \
        -f \
        -n 80
}

edit_config() {
    local editor

    editor="${EDITOR:-nano}"

    if ! command_exists "$editor"; then
        editor="vi"
    fi

    "$editor" "$CONFIG_FILE"

    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        warn "config.json بعد از ویرایش JSON معتبر نیست."
        return 1
    fi

    systemctl restart "$SERVICE_NAME" || true

    ok "تنظیمات ذخیره و سرویس Restart شد."
}

backup_config() {
    local stamp
    local target

    stamp="$(date +%Y%m%d_%H%M%S)"

    target="$BACKUP_DIR/config_$stamp.json"

    cp -f \
        "$CONFIG_FILE" \
        "$target"

    chmod 600 "$target"

    ok "Backup: $target"
}

show_runtime_state() {
    if [[ -r "$STATE_FILE" ]] &&
       jq empty "$STATE_FILE" >/dev/null 2>&1
    then
        jq . "$STATE_FILE"
    else
        warn "runtime_state.json قابل خواندن نیست."
    fi
}

set_jq_number() {
    local key="$1"
    local value="$2"
    local tmp

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        warn "مقدار باید عدد صحیح مثبت باشد."
        return 1
    fi

    tmp="$(mktemp)"

    jq \
        --argjson value "$value" \
        ".${key} = \$value" \
        "$CONFIG_FILE" \
        > "$tmp"

    chmod 600 "$tmp"

    mv "$tmp" "$CONFIG_FILE"
}

anti_abuse_settings() {
    while true; do
        clear

        echo -e \
            "${CYAN}━━━━━━━━━━━━ Anti-Abuse Settings ━━━━━━━━━━━━${NC}"

        local enabled
        local threshold
        local window
        local strikes
        local strike_window
        local ban
        local retention
        local max_events
        local choice
        local value
        local new_enabled
        local tmp

        enabled="$(
            read_config_value \
                '.anti_abuse.enabled // false' \
                'false'
        )"

        threshold="$(
            read_config_value \
                '.anti_abuse.new_ip_threshold // 20' \
                '20'
        )"

        window="$(
            read_config_value \
                '.anti_abuse.new_ip_window_seconds // 60' \
                '60'
        )"

        strikes="$(
            read_config_value \
                '.anti_abuse.strike_threshold // 3' \
                '3'
        )"

        strike_window="$(
            read_config_value \
                '.anti_abuse.strike_window_seconds // 1800' \
                '1800'
        )"

        ban="$(
            read_config_value \
                '.anti_abuse.ban_seconds // 3600' \
                '3600'
        )"

        retention="$(
            read_config_value \
                '.anti_abuse.log_retention_seconds // 86400' \
                '86400'
        )"

        max_events="$(
            read_config_value \
                '.anti_abuse.max_events_per_user // 1000' \
                '1000'
        )"

        echo "Status:              $enabled"
        echo "New IP threshold:    $threshold"
        echo "New IP window:       ${window}s"
        echo "Strike threshold:    $strikes"
        echo "Strike window:       ${strike_window}s"
        echo "Temporary ban:       ${ban}s"
        echo "History retention:   ${retention}s"
        echo "Max events/user:     $max_events"

        echo

        echo "1) Enable / Disable"
        echo "2) Change New IP threshold"
        echo "3) Change New IP window"
        echo "4) Change Strike threshold"
        echo "5) Change Strike window"
        echo "6) Change Temporary Ban duration"
        echo "7) Change History retention"
        echo "8) Change Max events/user"
        echo "9) Show Runtime State"
        echo "0) Back"

        echo

        read -r -p "انتخاب: " choice

        case "$choice" in

            1)
                if [[ "$enabled" == "true" ]]; then
                    new_enabled=false
                else
                    new_enabled=true
                fi

                tmp="$(mktemp)"

                jq \
                    --argjson value "$new_enabled" \
                    '.anti_abuse.enabled = $value' \
                    "$CONFIG_FILE" \
                    > "$tmp"

                chmod 600 "$tmp"
                mv "$tmp" "$CONFIG_FILE"

                systemctl restart "$SERVICE_NAME" || true

                ok "Anti-Abuse = $new_enabled"

                pause_menu
                ;;

            2)
                read -r \
                    -p "New IP threshold [$threshold]: " \
                    value

                set_jq_number \
                    'anti_abuse.new_ip_threshold' \
                    "${value:-$threshold}" ||
                    true

                systemctl restart "$SERVICE_NAME" || true
                ;;

            3)
                read -r \
                    -p "New IP window seconds [$window]: " \
                    value

                set_jq_number \
                    'anti_abuse.new_ip_window_seconds' \
                    "${value:-$window}" ||
                    true

                systemctl restart "$SERVICE_NAME" || true
                ;;

            4)
                read -r \
                    -p "Strike threshold [$strikes]: " \
                    value

                set_jq_number \
                    'anti_abuse.strike_threshold' \
                    "${value:-$strikes}" ||
                    true

                systemctl restart "$SERVICE_NAME" || true
                ;;

            5)
                read -r \
                    -p "Strike window seconds [$strike_window]: " \
                    value

                set_jq_number \
                    'anti_abuse.strike_window_seconds' \
                    "${value:-$strike_window}" ||
                    true

                systemctl restart "$SERVICE_NAME" || true
                ;;

            6)
                read -r \
                    -p "Temporary ban seconds [$ban]: " \
                    value

                set_jq_number \
                    'anti_abuse.ban_seconds' \
                    "${value:-$ban}" ||
                    true

                systemctl restart "$SERVICE_NAME" || true
                ;;

            7)
                read -r \
                    -p "History retention seconds [$retention]: " \
                    value

                set_jq_number \
                    'anti_abuse.log_retention_seconds' \
                    "${value:-$retention}" ||
                    true

                systemctl restart "$SERVICE_NAME" || true
                ;;

            8)
                read -r \
                    -p "Max events/user [$max_events]: " \
                    value

                set_jq_number \
                    'anti_abuse.max_events_per_user' \
                    "${value:-$max_events}" ||
                    true

                systemctl restart "$SERVICE_NAME" || true
                ;;

            9)
                clear
                show_runtime_state
                pause_menu
                ;;

            0)
                return
                ;;

            *)
                warn "انتخاب نامعتبر."
                sleep 1
                ;;
        esac
    done
}

version_parts() {
    local v="$1"
    local a b c

    v="${v#v}"
    v="${v%%-*}"

    IFS=. read -r a b c <<< "$v"

    a="${a:-0}"
    b="${b:-0}"
    c="${c:-0}"

    [[ "$a" =~ ^[0-9]+$ ]] || a=0
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    [[ "$c" =~ ^[0-9]+$ ]] || c=0

    printf '%d %d %d\n' \
        "$((10#$a))" \
        "$((10#$b))" \
        "$((10#$c))"
}

version_gt() {
    local a1 a2 a3
    local b1 b2 b3

    read -r a1 a2 a3 <<< \
        "$(version_parts "$1")"

    read -r b1 b2 b3 <<< \
        "$(version_parts "$2")"

    ((a1 > b1)) && return 0
    ((a1 < b1)) && return 1

    ((a2 > b2)) && return 0
    ((a2 < b2)) && return 1

    ((a3 > b3))
}

version_eq() {
    local a1 a2 a3
    local b1 b2 b3

    read -r a1 a2 a3 <<< \
        "$(version_parts "$1")"

    read -r b1 b2 b3 <<< \
        "$(version_parts "$2")"

    ((a1 == b1 &&
      a2 == b2 &&
      a3 == b3))
}

get_latest_release_version() {
    curl \
        -fsSL \
        --max-time 5 \
        -H 'Accept: application/vnd.github+json' \
        "$GITHUB_RELEASES_URL" \
        2>/dev/null |
        jq -r \
            '.tag_name // empty' \
            2>/dev/null |
        sed 's/^v//' |
        head -n1
}

get_installer_version() {
    curl \
        -fsSL \
        --max-time 5 \
        "$INSTALLER_URL" \
        2>/dev/null |
        sed \
            -n \
            's/^CURRENT_VERSION="\([^"]*\)"/\1/p' |
        head -n1
}

check_updates() {
    clear

    echo -e \
        "${CYAN}━━━━━━━━━━━━ Check for Updates ━━━━━━━━━━━━${NC}"

    echo "نسخه فعلی: v$CURRENT_VERSION"
    echo

    local latest
    local installer_version
    local confirm
    local tmp

    latest="$(
        get_latest_release_version ||
        true
    )"

    if [[ -z "$latest" ]]; then

        latest="$(
            get_installer_version ||
            true
        )"

        if [[ -z "$latest" ]]; then
            warn "ارتباط با GitHub برقرار نشد یا Release/Installer قابل دریافت نیست."
            pause_menu
            return
        fi

        echo "منبع بررسی: نسخه منتشرشده در main"

    else

        echo "منبع بررسی: GitHub Release"
        echo "Latest Release: v$latest"

    fi

    if version_gt \
        "$latest" \
        "$CURRENT_VERSION"
    then

        echo -e \
            "${YELLOW}[!] نسخه جدید یافت شد: v$latest (نسخه فعلی: v$CURRENT_VERSION)${NC}"

        read -r \
            -p "آیا می‌خواهید آپدیت کنید؟ (y/n): " \
            confirm

        [[ "$confirm" =~ ^[Yy]$ ]] ||
            return

    elif version_eq \
        "$latest" \
        "$CURRENT_VERSION"
    then

        echo -e \
            "${GREEN}[OK] شما از آخرین نسخه (v$CURRENT_VERSION) استفاده می‌کنید.${NC}"

        read -r \
            -p "آیا می‌خواهید نصب مجدد (Reinstall) انجام دهید؟ (y/n): " \
            confirm

        [[ "$confirm" =~ ^[Yy]$ ]] ||
            return

    else

        echo -e \
            "${GREEN}[OK] نسخه نصب‌شده ($CURRENT_VERSION) از نسخه بررسی‌شده ($latest) جدیدتر است.${NC}"

        pause_menu
        return
    fi

    installer_version="$(
        get_installer_version ||
        true
    )"

    if [[ -z "$installer_version" ]]; then
        warn "نسخه installer از GitHub دریافت نشد."
        pause_menu
        return
    fi

    if ! version_gt \
        "$installer_version" \
        "$CURRENT_VERSION" &&
       ! version_eq \
        "$installer_version" \
        "$CURRENT_VERSION"
    then
        warn "installer موجود در main از نسخه نصب‌شده قدیمی‌تر است؛ آپدیت متوقف شد."
        pause_menu
        return
    fi

    tmp="$(
        mktemp \
            /tmp/teperip-install.XXXXXX.sh
    )"

    if ! curl \
        -fsSL \
        --retry 3 \
        --connect-timeout 10 \
        --max-time 60 \
        "$INSTALLER_URL" \
        -o "$tmp"
    then

        rm -f "$tmp"

        err "دریافت installer ناموفق بود."

        pause_menu
        return
    fi

    chmod +x "$tmp"

    bash "$tmp"

    rm -f "$tmp"

    exit 0
}

uninstall_teperip() {
    echo
    warn "این عملیات TeperIP را از سیستم حذف می‌کند."

    read -r \
        -p "برای تأیید عبارت REMOVE را وارد کنید: " \
        confirm

    [[ "$confirm" == "REMOVE" ]] ||
        {
            echo "لغو شد."
            return
        }

    systemctl disable --now \
        "$SERVICE_NAME" \
        >/dev/null 2>&1 ||
        true

    rm -f \
        "$SERVICE_FILE" \
        "$MENU_FILE" \
        "$INSTALL_DIR/pg_ip_limit_menu" \
        /etc/systemd/journald.conf.d/teperip.conf

    systemctl daemon-reload

    systemctl restart systemd-journald \
        >/dev/null 2>&1 ||
        true

    echo
    echo "آیا /opt/pg_iplimit و backupها نیز حذف شوند؟"

    read -r \
        -p "(y/n): " \
        delete_data

    if [[ "$delete_data" =~ ^[Yy]$ ]]; then

        rm -rf "$INSTALL_DIR"

        ok "TeperIP و داده‌های آن حذف شدند."

    else

        ok "سرویس حذف شد؛ داده‌ها در $INSTALL_DIR باقی ماندند."

    fi
}

create_menu() {

    cat > "$MENU_FILE" <<'EOF_MENU'
#!/usr/bin/env bash
set -euo pipefail

exec /opt/pg_iplimit/pg_ip_limit_menu "$@"
EOF_MENU

    chmod 755 "$MENU_FILE"

    cat > "$INSTALL_DIR/pg_ip_limit_menu" <<'MENU_IMPL'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/pg_iplimit"
CONFIG_FILE="$INSTALL_DIR/config.json"
STATE_FILE="$INSTALL_DIR/runtime_state.json"
BACKUP_DIR="$INSTALL_DIR/backups"

SERVICE_NAME="pg_iplimit.service"

CURRENT_VERSION="1.3.1"

INSTALLER_URL="https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh"

GITHUB_RELEASES_URL="https://api.github.com/repos/Jyavaz68/teperip/releases/latest"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pause_menu() {
    echo
    read -r -p "برای ادامه Enter بزنید... " _
}

read_config_value() {
    local filter="$1"
    local fallback="$2"

    if [[ -r "$CONFIG_FILE" ]] &&
       jq empty "$CONFIG_FILE" >/dev/null 2>&1
    then

        jq -r "$filter" \
            "$CONFIG_FILE" \
            2>/dev/null ||
            printf '%s' "$fallback"

    else

        printf '%s' "$fallback"

    fi
}

show_status() {
    clear

    echo -e \
        "${CYAN}━━━━━━━━━━━━ TeperIP Status ━━━━━━━━━━━━${NC}"

    local s
    local a
    local p
    local i
    local w
    local v

    s="$(
        systemctl is-active \
            "$SERVICE_NAME" \
            2>/dev/null ||
            echo inactive
    )"

    a="UNKNOWN"

    p="$(
        read_config_value \
            '.panel_url // "UNKNOWN"' \
            'UNKNOWN'
    )"

    i="$(
        read_config_value \
            '.check_interval // "UNKNOWN"' \
            'UNKNOWN'
    )"

    w="$(
        read_config_value \
            '.max_workers // "UNKNOWN"' \
            'UNKNOWN'
    )"

    v="$(
        read_config_value \
            '.version // "UNKNOWN"' \
            'UNKNOWN'
    )"

    if [[ -r "$CONFIG_FILE" ]] &&
       jq empty "$CONFIG_FILE" >/dev/null 2>&1
    then

        a="$(
            jq -r \
                'if (.anti_abuse.enabled? // false)
                 then "ON"
                 else "OFF"
                 end' \
                "$CONFIG_FILE" \
                2>/dev/null ||
                echo UNKNOWN
        )"

    fi

    echo "Version:        $v"
    echo "Service:        $s"
    echo "Panel:          $p"
    echo "Interval:       ${i}s"
    echo "Workers:        $w"
    echo "Anti-Abuse:     $a"
    echo "Binary:         $INSTALL_DIR/pg_ip_limit"
    echo "State:          $STATE_FILE"

    echo

    if [[ -r "$STATE_FILE" ]] &&
       jq empty "$STATE_FILE" >/dev/null 2>&1
    then

        echo "Blocked users:  $(
            jq \
                '.blocked_users // {} | length' \
                "$STATE_FILE" \
                2>/dev/null ||
                echo UNKNOWN
        )"

        echo "Tracked users:  $(
            jq \
                '.ip_history // {} | length' \
                "$STATE_FILE" \
                2>/dev/null ||
                echo UNKNOWN
        )"

    else

        echo "Runtime state:  UNKNOWN"

    fi
}

show_logs() {
    clear

    echo -e \
        "${CYAN}━━━━━━━━━━━━ Live Logs ━━━━━━━━━━━━${NC}"

    echo "برای خروج Ctrl+C بزنید."

    echo

    journalctl \
        -u "$SERVICE_NAME" \
        -f \
        -n 80
}

set_num() {
    local k="$1"
    local v="$2"
    local t

    [[ "$v" =~ ^[0-9]+$ ]] ||
        {
            echo "مقدار باید عدد باشد."
            return 1
        }

    t="$(mktemp)"

    jq \
        --argjson value "$v" \
        ".${k} = \$value" \
        "$CONFIG_FILE" \
        > "$t"

    chmod 600 "$t"

    mv "$t" "$CONFIG_FILE"

    systemctl restart "$SERVICE_NAME"
}

anti_menu() {

    while true; do

        clear

        echo -e \
            "${CYAN}━━━━━━━━━━━━ Anti-Abuse Settings ━━━━━━━━━━━━${NC}"

        local e
        local t
        local w
        local s
        local sw
        local b
        local r
        local m
        local c
        local x

        e="$(
            read_config_value \
                '.anti_abuse.enabled // false' \
                false
        )"

        t="$(
            read_config_value \
                '.anti_abuse.new_ip_threshold // 20' \
                20
        )"

        w="$(
            read_config_value \
                '.anti_abuse.new_ip_window_seconds // 60' \
                60
        )"

        s="$(
            read_config_value \
                '.anti_abuse.strike_threshold // 3' \
                3
        )"

        sw="$(
            read_config_value \
                '.anti_abuse.strike_window_seconds // 1800' \
                1800
        )"

        b="$(
            read_config_value \
                '.anti_abuse.ban_seconds // 3600' \
                3600
        )"

        r="$(
            read_config_value \
                '.anti_abuse.log_retention_seconds // 86400' \
                86400
        )"

        m="$(
            read_config_value \
                '.anti_abuse.max_events_per_user // 1000' \
                1000
        )"

        echo "Status:              $e"
        echo "New IP threshold:    $t"
        echo "New IP window:       ${w}s"
        echo "Strike threshold:    $s"
        echo "Strike window:       ${sw}s"
        echo "Temporary ban:       ${b}s"
        echo "History retention:   ${r}s"
        echo "Max events/user:     $m"

        echo

        echo "1) Enable / Disable"
        echo "2) Change New IP threshold"
        echo "3) Change New IP window"
        echo "4) Change Strike threshold"
        echo "5) Change Strike window"
        echo "6) Change Temporary Ban duration"
        echo "7) Change History retention"
        echo "8) Change Max events/user"
        echo "9) Show Runtime State"
        echo "0) Back"

        read -r \
            -p "انتخاب: " \
            c

        case "$c" in

            1)
                local n
                local tfile

                if [[ "$e" == true ]]; then
                    n=false
                else
                    n=true
                fi

                tfile="$(mktemp)"

                jq \
                    --argjson value "$n" \
                    '.anti_abuse.enabled=$value' \
                    "$CONFIG_FILE" \
                    > "$tfile"

                chmod 600 "$tfile"

                mv "$tfile" "$CONFIG_FILE"

                systemctl restart "$SERVICE_NAME"

                pause_menu
                ;;

            2)
                read -r \
                    -p "New IP threshold [$t]: " \
                    x

                set_num \
                    'anti_abuse.new_ip_threshold' \
                    "${x:-$t}"
                ;;

            3)
                read -r \
                    -p "New IP window [$w]: " \
                    x

                set_num \
                    'anti_abuse.new_ip_window_seconds' \
                    "${x:-$w}"
                ;;

            4)
                read -r \
                    -p "Strike threshold [$s]: " \
                    x

                set_num \
                    'anti_abuse.strike_threshold' \
                    "${x:-$s}"
                ;;

            5)
                read -r \
                    -p "Strike window [$sw]: " \
                    x

                set_num \
                    'anti_abuse.strike_window_seconds' \
                    "${x:-$sw}"
                ;;

            6)
                read -r \
                    -p "Temporary ban [$b]: " \
                    x

                set_num \
                    'anti_abuse.ban_seconds' \
                    "${x:-$b}"
                ;;

            7)
                read -r \
                    -p "History retention [$r]: " \
                    x

                set_num \
                    'anti_abuse.log_retention_seconds' \
                    "${x:-$r}"
                ;;

            8)
                read -r \
                    -p "Max events/user [$m]: " \
                    x

                set_num \
                    'anti_abuse.max_events_per_user' \
                    "${x:-$m}"
                ;;

            9)
                clear

                if [[ -r "$STATE_FILE" ]]; then
                    jq . "$STATE_FILE"
                else
                    echo "State unavailable"
                fi

                pause_menu
                ;;

            0)
                return
                ;;

            *)
                echo "انتخاب نامعتبر."
                sleep 1
                ;;

        esac
    done
}

version_parts() {
    local v="$1"
    local a b c

    v="${v#v}"
    v="${v%%-*}"

    IFS=. read -r a b c <<< "$v"

    a="${a:-0}"
    b="${b:-0}"
    c="${c:-0}"

    [[ "$a" =~ ^[0-9]+$ ]] || a=0
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    [[ "$c" =~ ^[0-9]+$ ]] || c=0

    printf \
        '%d %d %d\n' \
        "$((10#$a))" \
        "$((10#$b))" \
        "$((10#$c))"
}

version_gt() {
    local a b c d e f

    read -r a b c <<< \
        "$(version_parts "$1")"

    read -r d e f <<< \
        "$(version_parts "$2")"

    ((a > d)) && return 0
    ((a < d)) && return 1

    ((b > e)) && return 0
    ((b < e)) && return 1

    ((c > f))
}

version_eq() {
    local a b c d e f

    read -r a b c <<< \
        "$(version_parts "$1")"

    read -r d e f <<< \
        "$(version_parts "$2")"

    ((a == d &&
      b == e &&
      c == f))
}

get_latest() {
    curl \
        -fsSL \
        --max-time 5 \
        -H 'Accept: application/vnd.github+json' \
        "$GITHUB_RELEASES_URL" \
        2>/dev/null |
        jq -r \
            '.tag_name // empty' \
            2>/dev/null |
        sed 's/^v//' |
        head -n1
}

get_installer() {
    curl \
        -fsSL \
        --max-time 5 \
        "$INSTALLER_URL" \
        2>/dev/null |
        sed \
            -n \
            's/^CURRENT_VERSION="\([^"]*\)"/\1/p' |
        head -n1
}

updates() {
    clear

    echo -e \
        "${CYAN}━━━━━━━━━━━━ Check for Updates ━━━━━━━━━━━━${NC}"

    echo "نسخه فعلی: v$CURRENT_VERSION"

    echo

    local latest
    local installer
    local confirm
    local tmp

    latest="$(
        get_latest ||
        true
    )"

    if [[ -z "$latest" ]]; then

        latest="$(
            get_installer ||
            true
        )"

        echo "منبع بررسی: main"

    else

        echo "منبع بررسی: GitHub Release"

    fi

    if [[ -z "$latest" ]]; then
        echo "ارتباط با GitHub برقرار نشد."
        pause_menu
        return
    fi

    if version_gt \
        "$latest" \
        "$CURRENT_VERSION"
    then

        echo -e \
            "${YELLOW}[!] نسخه جدید: v$latest${NC}"

        read -r \
            -p "آپدیت شود؟ (y/n): " \
            confirm

        [[ "$confirm" =~ ^[Yy]$ ]] ||
            return

    elif version_eq \
        "$latest" \
        "$CURRENT_VERSION"
    then

        echo -e \
            "${GREEN}[OK] آخرین نسخه نصب است.${NC}"

        read -r \
            -p "Reinstall شود؟ (y/n): " \
            confirm

        [[ "$confirm" =~ ^[Yy]$ ]] ||
            return

    else

        echo "نسخه نصب‌شده جدیدتر است."

        pause_menu

        return
    fi

    installer="$(
        get_installer ||
        true
    )"

    if [[ -z "$installer" ]]; then
        echo "installer دریافت نشد."
        pause_menu
        return
    fi

    if ! version_gt \
        "$installer" \
        "$CURRENT_VERSION" &&
       ! version_eq \
        "$installer" \
        "$CURRENT_VERSION"
    then

        echo "installer موجود قدیمی‌تر است؛ لغو شد."

        pause_menu

        return
    fi

    tmp="$(
        mktemp \
            /tmp/teperip-install.XXXXXX.sh
    )"

    curl \
        -fsSL \
        --retry 3 \
        --connect-timeout 10 \
        --max-time 60 \
        "$INSTALLER_URL" \
        -o "$tmp"

    chmod +x "$tmp"

    bash "$tmp"

    rm -f "$tmp"

    exit 0
}

backup() {
    local t

    t="$BACKUP_DIR/config_$(date +%Y%m%d_%H%M%S).json"

    cp \
        "$CONFIG_FILE" \
        "$t"

    chmod 600 "$t"

    echo "Backup: $t"
}

edit() {
    local e

    e="${EDITOR:-nano}"

    command -v "$e" >/dev/null 2>&1 ||
        e=vi

    "$e" "$CONFIG_FILE"

    jq empty "$CONFIG_FILE" ||
        {
            echo "JSON خراب است."
            return 1
        }

    systemctl restart "$SERVICE_NAME"
}

uninstall() {
    echo "برای حذف کامل REMOVE را وارد کنید:"

    read -r c

    [[ "$c" == REMOVE ]] ||
        return

    systemctl disable --now \
        "$SERVICE_NAME" \
        >/dev/null 2>&1 ||
        true

    rm -f \
        "/etc/systemd/system/$SERVICE_NAME" \
        /etc/systemd/journald.conf.d/teperip.conf \
        /usr/local/bin/teperip \
        /opt/pg_iplimit/pg_ip_limit_menu

    systemctl daemon-reload

    systemctl restart systemd-journald \
        >/dev/null 2>&1 ||
        true

    echo "سرویس حذف شد."

    echo "حذف داده‌ها؟ (y/n)"

    read -r d

    [[ "$d" =~ ^[Yy]$ ]] &&
        rm -rf "$INSTALL_DIR"
}

while true; do

    clear

    echo -e \
        "${CYAN}━━━━━━━━━━━━ TeperIP v$CURRENT_VERSION ━━━━━━━━━━━━${NC}"

    echo "1) Status"
    echo "2) Live Logs"
    echo "3) Restart Service"
    echo "4) Start Service"
    echo "5) Stop Service"
    echo "6) Edit Config"
    echo "7) Anti-Abuse Settings"
    echo "8) Backup Config"
    echo "9) Uninstall"
    echo "10) Check for Updates"
    echo "0) Exit"

    echo

    read -r \
        -p "انتخاب: " \
        c

    case "$c" in

        1)
            show_status
            pause_menu
            ;;

        2)
            show_logs
            ;;

        3)
            systemctl restart "$SERVICE_NAME"
            echo "Restart شد."
            pause_menu
            ;;

        4)
            systemctl start "$SERVICE_NAME"
            echo "Start شد."
            pause_menu
            ;;

        5)
            systemctl stop "$SERVICE_NAME"
            echo "Stop شد."
            pause_menu
            ;;

        6)
            edit
            pause_menu
            ;;

        7)
            anti_menu
            ;;

        8)
            backup
            pause_menu
            ;;

        9)
            uninstall
            exit 0
            ;;

        10)
            updates
            ;;

        0)
            exit 0
            ;;

        *)
            echo "انتخاب نامعتبر."
            sleep 1
            ;;

    esac

done
MENU_IMPL

    chmod 700 \
        "$INSTALL_DIR/pg_ip_limit_menu"
}

start_service() {
    systemctl daemon-reload

    systemctl enable \
        "$SERVICE_NAME" \
        >/dev/null

    systemctl restart \
        "$SERVICE_NAME"

    sleep 2

    if systemctl is-active \
        --quiet \
        "$SERVICE_NAME"
    then

        ok "سرویس TeperIP فعال است."

    else

        warn "سرویس اجرا نشد."

        warn \
            "لاگ: journalctl -u $SERVICE_NAME -n 100 --no-pager"

    fi
}

install_all() {
    require_root

    ensure_dependencies

    create_directories

    local existing=0

    if [[ -f "$CONFIG_FILE" ||
          -f "$BINARY_FILE" ||
          -f "$SERVICE_FILE" ]]
    then
        existing=1
    fi

    if ((existing)); then
        backup_existing
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        migrate_config
    fi

    if ! config_is_valid; then
        prompt_config
    else
        log "تنظیمات فعلی پنل حفظ می‌شوند."
    fi

    create_initial_state

    write_go_source

    build_binary

    create_systemd_service

    configure_journald

    create_menu

    save_install_state

    test_api || true

    start_service

    echo

    echo -e \
        "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    echo -e \
        "${GREEN}TeperIP v$CURRENT_VERSION نصب شد.${NC}"

    echo "مدیریت: teperip"
    echo "سرویس: $SERVICE_NAME"
    echo "کانفیگ: $CONFIG_FILE"
    echo "State:  $STATE_FILE"

    echo -e \
        "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

main() {
    install_all
}

main "$@"