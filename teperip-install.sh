#!/usr/bin/env bash
set -euo pipefail

CURRENT_VERSION="1.4.0"

INSTALL_DIR="/opt/pg_iplimit"
CONFIG_FILE="$INSTALL_DIR/config.json"
STATE_FILE="$INSTALL_DIR/runtime_state.json"
DB_FILE="$INSTALL_DIR/teperip.db"
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
        err "This script must be run as root."
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

pause_menu() {
    echo
    read -r -p "Press Enter to continue... " _
}

normalize_url() {
    echo "${1%/}"
}

generate_token() {
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_valid_url() {
    [[ "$1" =~ ^https?://[^[:space:]]+$ ]]
}

ensure_dependencies() {
    local missing=()
    local cmd

    for cmd in curl jq systemctl awk sed grep tar sqlite3; do
        command_exists "$cmd" || missing+=("$cmd")
    done

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    log "Installing required dependencies: ${missing[*]}"

    if command_exists apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl jq sqlite3 systemd coreutils tar ca-certificates
    elif command_exists dnf; then
        dnf install -y curl jq sqlite systemd coreutils tar ca-certificates
    elif command_exists yum; then
        yum install -y curl jq sqlite systemd coreutils tar ca-certificates
    else
        err "Supported package manager not found."
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
            err "Architecture $(uname -m) is not supported for automatic Go installation."
            return 1
            ;;
    esac

    if ! command_exists jq; then
        err "jq is required to fetch the stable Go version."
        return 1
    fi

    log "Fetching the latest stable Go version for Linux/$arch ..."

    latest_go="$(
        curl -fsSL \
            --max-time 15 \
            'https://go.dev/dl/?mode=json' |
            jq -r '[.[] | select(.stable == true)][0].version // empty'
    )" || true

    [[ -n "$latest_go" && "$latest_go" != "null" ]] || {
        err "Failed to fetch Go version from go.dev."
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

    log "Downloading $latest_go ..."

    curl -fL \
        --retry 3 \
        --connect-timeout 10 \
        --max-time 120 \
        "$url" \
        -o "$tarball"

    tar -xzf "$tarball" -C "$tmp_dir"

    [[ -x "$tmp_dir/go/bin/go" ]] || {
        err "Invalid Go archive."
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
        err "Go installed but version is less than 1.18: $(go_version_string)"
        return 1
    fi

    ok "Go is ready: $(go version)"
}

ensure_go() {
    export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"

    if command_exists go && go_version_ok; then
        ok "Go is available: $(go version)"
        return 0
    fi

    if command_exists go; then
        warn "Current Go version is old: $(go version 2>/dev/null || true)"
    else
        warn "Go is not installed on the system."
    fi

    if command_exists apt-get; then
        log "Attempting to install Go from system repositories..."
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
        ok "Go is ready: $(go version)"
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

    # Backward compatibility: Check for both new and old (admin_user) keys
    panel_user="$(
        jq -r '.panel_user // .admin_user // empty' "$CONFIG_FILE" 2>/dev/null || true
    )"

    panel_pass="$(
        jq -r '.panel_pass // .admin_pass // empty' "$CONFIG_FILE" 2>/dev/null || true
    )"

    [[ -n "$panel_url" && -n "$panel_user" && -n "$panel_pass" ]]
}

backup_existing() {
    local stamp backup_file files

    if [[ ! -f "$CONFIG_FILE" &&
          ! -f "$STATE_FILE" &&
          ! -f "$DB_FILE" &&
          ! -f "$BINARY_FILE" ]]; then
        return 0
    fi

    stamp="$(date +%Y%m%d_%H%M%S)"
    backup_file="$BACKUP_DIR/teperip_$stamp.tar.gz"

    files=()

    for f in \
        config.json \
        runtime_state.json \
        teperip.db \
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

        ok "Previous version backed up to: $backup_file"
    fi
}

migrate_config() {
    local tmp_file

    [[ -f "$CONFIG_FILE" ]] || return 0

    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        warn "config.json is corrupted; you will be prompted for panel info to create a new config."
        return 0
    fi

    tmp_file="$(mktemp)"

    jq \
        --arg version "$CURRENT_VERSION" \
        --arg new_token "$(generate_token)" \
        '
        .version = $version |

        .panel_url = (.panel_url // "") |
        .panel_user = (.panel_user // .admin_user // "") |
        .panel_pass = (.panel_pass // .admin_pass // "") |

        .check_interval = (.check_interval // 30) |
        .tolerance_seconds = (.tolerance_seconds // 60) |
        .penalty_seconds = (.penalty_seconds // 300) |
        .ip_stability_checks = (.ip_stability_checks // 2) |

        .request_timeout = (.request_timeout // 15) |
        .max_workers = (.max_workers // 5) |
        .verbose = (.verbose // false) |

        .anti_abuse = ((.anti_abuse // {}) + {
            enabled: (if .anti_abuse.enabled == null then true else .anti_abuse.enabled end),
            new_ip_threshold: ((.anti_abuse.new_ip_threshold // 20)),
            new_ip_window_seconds: ((.anti_abuse.new_ip_window_seconds // 60)),
            strike_threshold: ((.anti_abuse.strike_threshold // 3)),
            strike_window_seconds: ((.anti_abuse.strike_window_seconds // 1800)),
            ban_seconds: ((.anti_abuse.ban_seconds // 3600)),
            log_retention_seconds: ((.anti_abuse.log_retention_seconds // 86400)),
            max_events_per_user: ((.anti_abuse.max_events_per_user // 1000))
        }) |

        .journal_max_size = (.journal_max_size // "50M") |
        .journal_max_file_size = (.journal_max_file_size // "10M") |

        .insecure_skip_verify = (if .insecure_skip_verify == null then true else .insecure_skip_verify end) |

        .kick = ((.kick // {}) + {
            mode: (.kick.mode // "off"),
            agent_port: (.kick.agent_port // 8765),
            agent_token: (if (.kick.agent_token // "") == "" then $new_token else .kick.agent_token end),
            extra_agents: (.kick.extra_agents // []),
            block_ip: (if .kick.block_ip == null then true else .kick.block_ip end),
            kill_sockets: (if .kick.kill_sockets == null then true else .kick.kill_sockets end),
            max_block_seconds: (.kick.max_block_seconds // 3600),
            timeout_seconds: (.kick.timeout_seconds // 5),
            master_ip: (.kick.master_ip // "")
        })
        ' \
        "$CONFIG_FILE" > "$tmp_file"

    chmod 600 "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
}

prompt_config() {
    local panel_url panel_user panel_pass
    local check_interval tolerance penalty stability_checks timeout workers
    local input

    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "PasarGuard Connection Setup"
    echo "General example: $EXAMPLE_PANEL_URL"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    panel_url="$(
        jq -r '.panel_url // empty' "$CONFIG_FILE" 2>/dev/null || true
    )"

    panel_user="$(
        jq -r '.panel_user // .admin_user // empty' "$CONFIG_FILE" 2>/dev/null || true
    )"

    panel_pass="$(
        jq -r '.panel_pass // .admin_pass // empty' "$CONFIG_FILE" 2>/dev/null || true
    )"

    if [[ -z "$panel_url" ]]; then
        read -r -p "Panel URL: " panel_url
    else
        read -r -p "Panel URL [$panel_url]: " input
        panel_url="${input:-$panel_url}"
    fi

    panel_url="$(normalize_url "$panel_url")"

    if ! is_valid_url "$panel_url"; then
        err "Invalid panel URL."
        exit 1
    fi

    if [[ -z "$panel_user" ]]; then
        read -r -p "Admin Username: " panel_user
    else
        read -r -p "Admin Username [$panel_user]: " input
        panel_user="${input:-$panel_user}"
    fi

    if [[ -z "$panel_pass" ]]; then
        read -r -s -p "Admin Password: " panel_pass
        echo
    else
        read -r -s -p "Admin Password (press Enter to keep current): " input
        echo
        panel_pass="${input:-$panel_pass}"
    fi

    check_interval="$(
        jq -r '.check_interval // 30' "$CONFIG_FILE" 2>/dev/null || echo 30
    )"

    tolerance="$(
        jq -r '.tolerance_seconds // 60' "$CONFIG_FILE" 2>/dev/null || echo 60
    )"

    penalty="$(
        jq -r '.penalty_seconds // 300' "$CONFIG_FILE" 2>/dev/null || echo 300
    )"

    stability_checks="$(
        jq -r '.ip_stability_checks // 2' "$CONFIG_FILE" 2>/dev/null || echo 2
    )"

    timeout="$(
        jq -r '.request_timeout // 15' "$CONFIG_FILE" 2>/dev/null || echo 15
    )"

    workers="$(
        jq -r '.max_workers // 5' "$CONFIG_FILE" 2>/dev/null || echo 5
    )"

    read -r -p "Check interval (seconds) [$check_interval]: " input
    check_interval="${input:-$check_interval}"

    read -r -p "IP Limit tolerance (seconds) [$tolerance]: " input
    tolerance="${input:-$tolerance}"

    read -r -p "Disable duration for IP Limit (seconds) [$penalty]: " input
    penalty="${input:-$penalty}"

    read -r -p "Stable IP checks required [$stability_checks]: " input
    stability_checks="${input:-$stability_checks}"

    read -r -p "API Request Timeout (seconds) [$timeout]: " input
    timeout="${input:-$timeout}"

    read -r -p "Number of Workers [$workers]: " input
    workers="${input:-$workers}"

    local value
    for value in \
        "$check_interval" \
        "$tolerance" \
        "$penalty" \
        "$stability_checks" \
        "$timeout" \
        "$workers"
    do
        if ! is_uint "$value"; then
            err "Numeric settings must be non-negative integers (got: '$value')."
            exit 1
        fi
    done

    # Normalize values such as "08" which are not valid JSON numbers.
    check_interval=$((10#$check_interval))
    tolerance=$((10#$tolerance))
    penalty=$((10#$penalty))
    stability_checks=$((10#$stability_checks))
    timeout=$((10#$timeout))
    workers=$((10#$workers))

    local tmp_config
    tmp_config="$(mktemp)"

    if ! jq -n \
        --arg version "$CURRENT_VERSION" \
        --arg panel_url "$panel_url" \
        --arg panel_user "$panel_user" \
        --arg panel_pass "$panel_pass" \
        --arg agent_token "$(generate_token)" \
        --argjson check_interval "$check_interval" \
        --argjson tolerance_seconds "$tolerance" \
        --argjson penalty_seconds "$penalty" \
        --argjson ip_stability_checks "$stability_checks" \
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
            ip_stability_checks: $ip_stability_checks,

            request_timeout: $request_timeout,
            max_workers: $max_workers,
            verbose: false,

            insecure_skip_verify: true,

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

            kick: {
                mode: "off",
                agent_port: 8765,
                agent_token: $agent_token,
                extra_agents: [],
                block_ip: true,
                kill_sockets: true,
                max_block_seconds: 3600,
                timeout_seconds: 5,
                master_ip: ""
            },

            journal_max_size: "50M",
            journal_max_file_size: "10M"
        }' > "$tmp_config"
    then
        rm -f "$tmp_config"
        err "Failed to build config.json."
        exit 1
    fi

    chmod 600 "$tmp_config"
    mv "$tmp_config" "$CONFIG_FILE"
}

create_initial_state() {
    if [[ ! -s "$STATE_FILE" ]] ||
       ! jq empty "$STATE_FILE" >/dev/null 2>&1
    then
        cat > "$STATE_FILE" <<'JSON'
{
  "blocked_users": {},
  "abuse": {},
  "ip_history": {},
  "ip_stability": {}
}
JSON

        chmod 600 "$STATE_FILE"
    fi
}

initialize_database() {
    if [[ ! -f "$DB_FILE" ]]; then
        log "Creating TeperIP SQLite database..."
    else
        log "Checking TeperIP SQLite database..."
    fi

    sqlite3 "$DB_FILE" <<'SQL'
PRAGMA journal_mode=DELETE;
PRAGMA synchronous=FULL;

CREATE TABLE IF NOT EXISTS disabled_users (
    user_id TEXT PRIMARY KEY,
    username TEXT NOT NULL DEFAULT '',
    reason TEXT NOT NULL,
    blocked_at INTEGER NOT NULL,
    duration INTEGER NOT NULL
);
SQL

    chmod 600 "$DB_FILE"
}

migrate_blocked_users_to_database() {
    [[ -f "$STATE_FILE" ]] || return 0
    [[ -f "$DB_FILE" ]] || return 0

    if ! jq -e '.blocked_users | type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
        return 0
    fi

    local count=0
    local user_id blocked_at duration abuse_ban reason

    while IFS=$'\t' read -r user_id blocked_at duration abuse_ban; do
        [[ -n "$user_id" ]] || continue
        [[ "$blocked_at" =~ ^[0-9]+$ ]] || continue
        [[ "$duration" =~ ^[0-9]+$ ]] || continue

        if [[ "$abuse_ban" == "true" ]]; then
            reason="anti_abuse"
        else
            reason="ip_limit"
        fi

        sqlite3 "$DB_FILE"             "INSERT OR IGNORE INTO disabled_users
             (user_id, username, reason, blocked_at, duration)
             VALUES ($(printf '%s' "$user_id" | sed "s/'/''/g" | sed "s/^/'/;s/$/'/"),
                     '',
                     '$reason',
                     $blocked_at,
                     $duration);"

        count=$((count + 1))
    done < <(
        jq -r '
            .blocked_users
            | to_entries[]
            | [
                (.key | tostring),
                (.value.blocked_at // 0),
                (.value.duration_seconds // 0),
                (.value.abuse_ban // false)
              ]
            | @tsv
        ' "$STATE_FILE" 2>/dev/null || true
    )

    if ((count > 0)); then
        chmod 600 "$DB_FILE"
        ok "Migrated $count active TeperIP block(s) into SQLite."
    fi
}

write_go_source() {
cat > "$GO_SRC_FILE" <<'GO'
package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
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
	IPStabilityChecks  int             `json:"ip_stability_checks"`
	RequestTimeout     int             `json:"request_timeout"`
	MaxWorkers         int             `json:"max_workers"`
	Verbose            bool            `json:"verbose"`
	AntiAbuse          AntiAbuseConfig `json:"anti_abuse"`
	JournalMaxSize     string          `json:"journal_max_size"`
	JournalMaxFileSize string          `json:"journal_max_file_size"`

	// nil means "not set" and is treated as true for backward compatibility.
	InsecureSkipVerify *bool      `json:"insecure_skip_verify"`
	Kick               KickConfig `json:"kick"`
}

type KickConfig struct {
	Mode            string   `json:"mode"`
	AgentPort       int      `json:"agent_port"`
	AgentToken      string   `json:"agent_token"`
	ExtraAgents     []string `json:"extra_agents"`
	BlockIP         *bool    `json:"block_ip"`
	KillSockets     *bool    `json:"kill_sockets"`
	MaxBlockSeconds int      `json:"max_block_seconds"`
	TimeoutSeconds  int      `json:"timeout_seconds"`
	MasterIP        string   `json:"master_ip"`
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

type IPStabilitySeen struct {
	Consecutive int   `json:"consecutive"`
	LastSeen    int64 `json:"last_seen"`
	LastCycle   int64 `json:"last_cycle"`
}

type UserAbuseState struct {
	NewIPs  []AbuseEvent `json:"new_ips"`
	Strikes []AbuseEvent `json:"strikes"`

	// Start of the IP-limit grace period. Kept apart from Strikes so it can
	// never be mistaken for a real anti-abuse strike.
	GraceStart int64 `json:"grace_start"`
}

type BlockedUser struct {
	BlockedAt int64 `json:"blocked_at"`
	Duration  int64 `json:"duration_seconds"`
	AbuseBan  bool  `json:"abuse_ban"`
}

type RuntimeState struct {
	BlockedUsers map[string]BlockedUser                `json:"blocked_users"`
	Abuse        map[string]UserAbuseState             `json:"abuse"`
	IPHistory    map[string]map[string]IPSeen          `json:"ip_history"`
	IPStability  map[string]map[string]IPStabilitySeen `json:"ip_stability"`
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
	databasePath = "/opt/pg_iplimit/teperip.db"

	stateMu = sync.Mutex{}
	dbMu    = sync.Mutex{}

	logger = log.New(os.Stdout, "", log.LstdFlags)

	// Incremented once per successful cycle; used by the IP stability logic.
	cycleCounter int64

	kickMu   sync.Mutex
	kickLast = make(map[string]int64)
)

func main() {
	cfg, err := loadConfig(configPath)
	if err != nil {
		logger.Fatalf("config error: %v", err)
	}

	normalizeConfig(&cfg)

	if len(os.Args) > 1 {
		os.Exit(runCLI(cfg, os.Args[1:]))
	}

	state, err := loadState(statePath)
	if err != nil {
		logger.Fatalf("state error: %v", err)
	}

	ensureStateMaps(&state)

	// Stability counters are cycle based; they are meaningless across restarts.
	state.IPStability = make(map[string]map[string]IPStabilitySeen)

	if err := initDatabase(); err != nil {
		logger.Fatalf("database error: %v", err)
	}

	activeBlocks, err := loadActiveBlocks()
	if err != nil {
		logger.Fatalf("database load error: %v", err)
	}

	stateMu.Lock()
	state.BlockedUsers = activeBlocks
	stateMu.Unlock()

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

	if cfg.insecureSkipVerify() {
		logger.Printf(
			"WARNING: TLS certificate verification for the panel is disabled " +
				"(insecure_skip_verify=true). Set it to false in config.json if " +
				"your panel has a valid certificate.",
		)
	}

	if cfg.Kick.Mode == "agents" {
		logger.Printf(
			"KICK enabled | agent_port=%d block_ip=%t kill_sockets=%t extra_agents=%d",
			cfg.Kick.AgentPort,
			boolOr(cfg.Kick.BlockIP, true),
			boolOr(cfg.Kick.KillSockets, true),
			len(cfg.Kick.ExtraAgents),
		)
	}

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
		cfg.PenaltySeconds = 300
	}

	if cfg.IPStabilityChecks < 1 {
		cfg.IPStabilityChecks = 2
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

	if cfg.Kick.Mode != "agents" {
		cfg.Kick.Mode = "off"
	}

	if cfg.Kick.AgentPort < 1 || cfg.Kick.AgentPort > 65535 {
		cfg.Kick.AgentPort = 8765
	}

	if cfg.Kick.MaxBlockSeconds < 1 {
		cfg.Kick.MaxBlockSeconds = 3600
	}

	if cfg.Kick.TimeoutSeconds < 1 {
		cfg.Kick.TimeoutSeconds = 5
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

func sqlQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func initDatabase() error {
	dbMu.Lock()
	defer dbMu.Unlock()

	sql := `
PRAGMA journal_mode=DELETE;
PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS disabled_users (
	user_id TEXT PRIMARY KEY,
	username TEXT NOT NULL DEFAULT '',
	reason TEXT NOT NULL,
	blocked_at INTEGER NOT NULL,
	duration INTEGER NOT NULL
);`

	cmd := exec.Command(
		"sqlite3",
		"-batch",
		databasePath,
		sql,
	)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf(
			"sqlite init failed: %v: %s",
			err,
			trimBody(output),
		)
	}

	if err := os.Chmod(databasePath, 0600); err != nil {
		return err
	}

	return nil
}

func saveActiveBlock(
	userID string,
	username string,
	block BlockedUser,
	reason string,
) error {
	dbMu.Lock()
	defer dbMu.Unlock()

	sql := fmt.Sprintf(
		`INSERT OR REPLACE INTO disabled_users
		 (user_id, username, reason, blocked_at, duration)
		 VALUES (%s, %s, %s, %d, %d);`,
		sqlQuote(userID),
		sqlQuote(username),
		sqlQuote(reason),
		block.BlockedAt,
		block.Duration,
	)

	cmd := exec.Command(
		"sqlite3",
		"-batch",
		databasePath,
		sql,
	)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf(
			"sqlite save block failed: %v: %s",
			err,
			trimBody(output),
		)
	}

	return nil
}

func deleteActiveBlock(userID string) error {
	dbMu.Lock()
	defer dbMu.Unlock()

	sql := fmt.Sprintf(
		"DELETE FROM disabled_users WHERE user_id=%s;",
		sqlQuote(userID),
	)

	cmd := exec.Command(
		"sqlite3",
		"-batch",
		databasePath,
		sql,
	)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf(
			"sqlite delete block failed: %v: %s",
			err,
			trimBody(output),
		)
	}

	return nil
}

func loadActiveBlocks() (map[string]BlockedUser, error) {
	dbMu.Lock()
	defer dbMu.Unlock()

	cmd := exec.Command(
		"sqlite3",
		"-batch",
		"-noheader",
		"-separator", "|",
		databasePath,
		`SELECT hex(user_id),
		        reason,
		        blocked_at,
		        duration
		   FROM disabled_users
		  ORDER BY blocked_at ASC;`,
	)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf(
			"sqlite load blocks failed: %v: %s",
			err,
			trimBody(output),
		)
	}

	blocks := make(map[string]BlockedUser)

	for _, line := range strings.Split(
		strings.TrimSpace(string(output)),
		"\n",
	) {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		parts := strings.Split(line, "|")
		if len(parts) != 4 {
			return nil, fmt.Errorf(
				"invalid sqlite block row: %q",
				line,
			)
		}

		rawID, err := hex.DecodeString(parts[0])
		if err != nil {
			return nil, fmt.Errorf(
				"invalid sqlite user id: %w",
				err,
			)
		}

		blockedAt, err := strconv.ParseInt(parts[2], 10, 64)
		if err != nil {
			return nil, fmt.Errorf(
				"invalid sqlite blocked_at: %w",
				err,
			)
		}

		duration, err := strconv.ParseInt(parts[3], 10, 64)
		if err != nil {
			return nil, fmt.Errorf(
				"invalid sqlite duration: %w",
				err,
			)
		}

		blocks[string(rawID)] = BlockedUser{
			BlockedAt: blockedAt,
			Duration:  duration,
			AbuseBan:  parts[1] == "anti_abuse",
		}
	}

	return blocks, nil
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

	if state.IPStability == nil {
		state.IPStability = make(map[string]map[string]IPStabilitySeen)
	}

	// Older versions stored the grace start as a fake strike. Move it.
	for userID, abuse := range state.Abuse {
		kept := abuse.Strikes[:0]

		for _, event := range abuse.Strikes {
			if event.IP == "__ip_limit_grace__" {
				if abuse.GraceStart == 0 {
					abuse.GraceStart = event.Time
				}

				continue
			}

			kept = append(kept, event)
		}

		abuse.Strikes = kept
		state.Abuse[userID] = abuse
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
			InsecureSkipVerify: cfg.insecureSkipVerify(),
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
	var raw json.RawMessage

	if err := a.getJSON(
		"/api/users?online=true&all=true",
		&raw,
	); err != nil {
		return nil, err
	}

	// Older PasarGuard versions returned a bare JSON array.
	var users []User
	if err := json.Unmarshal(raw, &users); err == nil {
		return users, nil
	}

	// Current PasarGuard versions return an object containing `users`.
	var envelope struct {
		Users []User `json:"users"`
	}

	if err := json.Unmarshal(raw, &envelope); err != nil {
		return nil, fmt.Errorf(
			"decode /api/users?online=true: %w",
			err,
		)
	}

	if envelope.Users == nil {
		return nil, fmt.Errorf(
			"decode /api/users?online=true: response object does not contain users array",
		)
	}

	return envelope.Users, nil
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

	atomic.AddInt64(&cycleCounter, 1)

	online := make(map[string]struct{}, len(users))

	for _, u := range users {
		if id := stringifyID(u.ID); id != "" {
			online[id] = struct{}{}
		}
	}

	// Users that are no longer online must not keep stale grace periods or
	// IP stability counters around.
	cleanupOffline(state, online)

	stats := &cycleStats{}

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
				stats,
			)
		}()
	}

	wg.Wait()

	if stats.failed > 0 {
		logger.Printf(
			"CYCLE | online=%d ip_lookup_failed=%d first_error=%s",
			len(users),
			stats.failed,
			stats.firstErr,
		)
	} else if cfg.Verbose {
		logger.Printf(
			"CYCLE | online=%d ok",
			len(users),
		)
	}

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
	stats *cycleStats,
) {
	userID := stringifyID(user.ID)

	if userID == "" {
		return
	}

	ips, err := client.getUserIPs(userID)

	if err != nil {
		stats.fail(err)

		if cfg.Verbose {
			logger.Printf(
				"user=%s IP lookup failed: %v",
				userID,
				err,
			)
		}
		return
	}

	stateMu.Lock()
	_, blocked := state.BlockedUsers[userID]
	stateMu.Unlock()

	if blocked {
		// Already disabled by us. If the user is still online their old
		// connections are alive, so try to cut them again.
		maybeRekick(
			client,
			cfg,
			state,
			userID,
			user.Username,
			ips,
		)
		return
	}

	if user.HWIDLimit > 0 {
		processIPLimit(
			client,
			cfg,
			state,
			user,
			userID,
			ips,
		)
		return
	}

	// The limit may have been removed in the panel during a grace period.
	clearGrace(state, userID)

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

func updateIPStability(
	cfg *Config,
	state *RuntimeState,
	userID string,
	ips map[string]struct{},
) map[string]struct{} {
	cycle := atomic.LoadInt64(&cycleCounter)
	now := time.Now().Unix()

	checksRequired := cfg.IPStabilityChecks
	if checksRequired < 1 {
		checksRequired = 1
	}

	stateMu.Lock()
	defer stateMu.Unlock()

	if state.IPStability == nil {
		state.IPStability = make(map[string]map[string]IPStabilitySeen)
	}

	userIPs := state.IPStability[userID]
	if userIPs == nil {
		userIPs = make(map[string]IPStabilitySeen)
		state.IPStability[userID] = userIPs
	}

	seenNow := make(map[string]struct{}, len(ips))

	for ip := range ips {
		ip = strings.TrimSpace(ip)
		if ip == "" {
			continue
		}

		seenNow[ip] = struct{}{}

		// "Consecutive" counts consecutive monitoring cycles, not seconds, so a
		// slow cycle can never reset the counter.
		seen, exists := userIPs[ip]
		if !exists || cycle < seen.LastCycle || cycle-seen.LastCycle > 1 {
			seen = IPStabilitySeen{}
		}

		if seen.LastCycle != cycle {
			seen.Consecutive++
		}

		seen.LastCycle = cycle
		seen.LastSeen = now
		userIPs[ip] = seen
	}

	// An IP that disappears from the online snapshot is no longer a
	// simultaneous connection.
	for ip := range userIPs {
		if _, ok := seenNow[ip]; !ok {
			delete(userIPs, ip)
		}
	}

	stable := make(map[string]struct{})

	for ip, seen := range userIPs {
		if seen.Consecutive >= checksRequired {
			stable[ip] = struct{}{}
		}
	}

	if len(userIPs) == 0 {
		delete(state.IPStability, userID)
	}

	return stable
}

func processIPLimit(
	client *APIClient,
	cfg *Config,
	state *RuntimeState,
	user User,
	userID string,
	ips map[string]struct{},
) {
	stableIPs := updateIPStability(
		cfg,
		state,
		userID,
		ips,
	)

	ipCount := len(stableIPs)

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

	block := BlockedUser{
		BlockedAt: now,
		Duration:  int64(cfg.PenaltySeconds),
		AbuseBan: false,
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

	if err := saveActiveBlock(
		userID,
		user.Username,
		block,
		"ip_limit",
	); err != nil {
		if enableErr := client.setDisabled(userID, false); enableErr != nil {
			logger.Printf(
				"IP LIMIT | user=%s database save failed and rollback re-enable failed: %v",
				userID,
				enableErr,
			)
		} else {
			logger.Printf(
				"IP LIMIT | user=%s database save failed; disable rolled back",
				userID,
			)
		}
		return
	}

	stateMu.Lock()
	state.BlockedUsers[userID] = block
	stateMu.Unlock()

	kickUser(
		client,
		cfg,
		userID,
		user.Username,
		ips,
		block.Duration,
		"ip_limit",
	)

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
		pruneEvents(
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
		if event.Time >= strikeCutoff {
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

	block := BlockedUser{
		BlockedAt: now,
		Duration:  int64(cfg.AntiAbuse.BanSeconds),
		AbuseBan: true,
	}

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

	if err := saveActiveBlock(
		userID,
		user.Username,
		block,
		"anti_abuse",
	); err != nil {
		if enableErr := client.setDisabled(userID, false); enableErr != nil {
			logger.Printf(
				"ANTI-ABUSE | user=%s database save failed and rollback re-enable failed: %v",
				userID,
				enableErr,
			)
		} else {
			logger.Printf(
				"ANTI-ABUSE | user=%s database save failed; disable rolled back",
				userID,
			)
		}
		return
	}

	stateMu.Lock()

	state.BlockedUsers[userID] = block

	abuse = state.Abuse[userID]

	abuse.Strikes = nil
	abuse.NewIPs = nil

	state.Abuse[userID] = abuse

	stateMu.Unlock()

	kickUser(
		client,
		cfg,
		userID,
		user.Username,
		ips,
		block.Duration,
		"anti_abuse",
	)

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

	return state.Abuse[userID].GraceStart
}

func setGraceStart(
	state *RuntimeState,
	userID string,
	now int64,
) {
	stateMu.Lock()
	defer stateMu.Unlock()

	abuse := state.Abuse[userID]

	if abuse.GraceStart != 0 {
		return
	}

	abuse.GraceStart = now

	state.Abuse[userID] = abuse
}

func clearGrace(
	state *RuntimeState,
	userID string,
) {
	stateMu.Lock()
	defer stateMu.Unlock()

	abuse, ok := state.Abuse[userID]

	if !ok || abuse.GraceStart == 0 {
		return
	}

	abuse.GraceStart = 0

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

	blocks, err := loadActiveBlocks()
	if err != nil {
		logger.Printf(
			"RE-ENABLE | failed to load active blocks: %v",
			err,
		)
		return
	}

	stateMu.Lock()
	state.BlockedUsers = blocks
	stateMu.Unlock()

	for id, block := range blocks {
		if block.BlockedAt > 0 &&
			block.Duration > 0 &&
			now-block.BlockedAt < block.Duration {
			continue
		}

		if err := client.setDisabled(
			id,
			false,
		); err != nil {
			logger.Printf(
				"RE-ENABLE | user=%s failed: %v",
				id,
				err,
			)
			continue
		}

		if err := deleteActiveBlock(id); err != nil {
			logger.Printf(
				"RE-ENABLE | user=%s enabled but database cleanup failed: %v",
				id,
				err,
			)
			continue
		}

		stateMu.Lock()

		delete(
			state.BlockedUsers,
			id,
		)

		delete(
			state.Abuse,
			id,
		)

		stateMu.Unlock()

		kickMu.Lock()
		delete(kickLast, id)
		kickMu.Unlock()

		if block.AbuseBan {
			logger.Printf(
				"ANTI-ABUSE | user=%s temporary ban expired; user re-enabled",
				id,
			)
		} else {
			logger.Printf(
				"IP LIMIT | user=%s penalty expired; user re-enabled",
				id,
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
			pruneEvents(
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
			len(abuse.Strikes) == 0 &&
			abuse.GraceStart == 0 {

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

	case nil:
		return ""

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

// ---------------------------------------------------------------------------
// Cycle statistics
// ---------------------------------------------------------------------------

type cycleStats struct {
	mu       sync.Mutex
	failed   int
	firstErr string
}

func (s *cycleStats) fail(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.failed++

	if s.firstErr == "" && err != nil {
		s.firstErr = err.Error()
	}
}

func cleanupOffline(state *RuntimeState, online map[string]struct{}) {
	stateMu.Lock()
	defer stateMu.Unlock()

	for userID := range state.IPStability {
		if _, ok := online[userID]; !ok {
			delete(state.IPStability, userID)
		}
	}

	for userID, abuse := range state.Abuse {
		if _, ok := online[userID]; ok {
			continue
		}

		abuse.GraceStart = 0

		if len(abuse.NewIPs) == 0 && len(abuse.Strikes) == 0 {
			delete(state.Abuse, userID)
		} else {
			state.Abuse[userID] = abuse
		}
	}
}

// ---------------------------------------------------------------------------
// Node agent "kick" support
//
// The panel/node APIs have no way to close established connections, so an
// optional agent on every node blocks the offending IPs in nftables for a
// limited time and kills their sockets.
// ---------------------------------------------------------------------------

const (
	kickHeaderTS      = "X-Teperip-Ts"
	kickHeaderNonce   = "X-Teperip-Nonce"
	kickHeaderSig     = "X-Teperip-Sig"
	kickRetrySeconds  = 30
	kickMaxIPsPerCall = 200
)

type kickRequest struct {
	IPs     []string `json:"ips"`
	Seconds int64    `json:"seconds"`
	Block   bool     `json:"block"`
	Kill    bool     `json:"kill"`
	Reason  string   `json:"reason,omitempty"`
}

type kickResponse struct {
	OK      bool     `json:"ok"`
	Blocked []string `json:"blocked"`
	Killed  int      `json:"killed"`
	Skipped []string `json:"skipped"`
	Error   string   `json:"error,omitempty"`
}

func boolOr(value *bool, fallback bool) bool {
	if value == nil {
		return fallback
	}

	return *value
}

func (c Config) insecureSkipVerify() bool {
	return boolOr(c.InsecureSkipVerify, true)
}

func newNonce() string {
	buf := make([]byte, 12)

	if _, err := rand.Read(buf); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}

	return hex.EncodeToString(buf)
}

func kickSign(
	token string,
	ts string,
	nonce string,
	method string,
	path string,
	body []byte,
) string {
	mac := hmac.New(sha256.New, []byte(token))

	mac.Write([]byte(ts))
	mac.Write([]byte("\n"))
	mac.Write([]byte(nonce))
	mac.Write([]byte("\n"))
	mac.Write([]byte(method))
	mac.Write([]byte("\n"))
	mac.Write([]byte(path))
	mac.Write([]byte("\n"))
	mac.Write(body)

	return hex.EncodeToString(mac.Sum(nil))
}

func normalizeNodeHost(raw string) string {
	raw = strings.TrimSpace(raw)

	if raw == "" {
		return ""
	}

	if strings.Contains(raw, "://") {
		if u, err := url.Parse(raw); err == nil && u.Hostname() != "" {
			return u.Hostname()
		}
	}

	if host, _, err := net.SplitHostPort(raw); err == nil {
		return host
	}

	return strings.Trim(raw, "[]")
}

func normalizeAgentURL(raw string, defaultPort int) string {
	raw = strings.TrimSpace(raw)

	if raw == "" {
		return ""
	}

	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}

	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return ""
	}

	port := u.Port()
	if port == "" {
		port = strconv.Itoa(defaultPort)
	}

	return "https://" + net.JoinHostPort(u.Hostname(), port)
}

func cleanIPString(raw string) string {
	raw = strings.TrimSpace(raw)

	if host, _, err := net.SplitHostPort(raw); err == nil {
		raw = host
	}

	raw = strings.Trim(raw, "[]")

	if net.ParseIP(raw) == nil {
		return ""
	}

	return raw
}

func (a *APIClient) getNodeHosts() ([]string, error) {
	var raw json.RawMessage

	if err := a.getJSON("/api/nodes", &raw); err != nil {
		return nil, err
	}

	var list []map[string]interface{}

	if err := json.Unmarshal(raw, &list); err != nil {
		var envelope struct {
			Nodes []map[string]interface{} `json:"nodes"`
		}

		if err2 := json.Unmarshal(raw, &envelope); err2 != nil {
			return nil, fmt.Errorf("decode /api/nodes: %w", err2)
		}

		list = envelope.Nodes
	}

	seen := make(map[string]struct{})
	hosts := make([]string, 0, len(list))

	for _, node := range list {
		address, _ := node["address"].(string)
		host := normalizeNodeHost(address)

		if host == "" {
			continue
		}

		if _, ok := seen[host]; ok {
			continue
		}

		seen[host] = struct{}{}
		hosts = append(hosts, host)
	}

	return hosts, nil
}

const nodeCacheTTL = 2 * time.Minute

var (
	nodeCacheMu    sync.Mutex
	nodeCacheHosts []string
	nodeCacheAt    time.Time
)

// cachedNodeHosts asks the panel for its nodes at most once per TTL, no matter
// how many users get kicked in the same cycle. The lock is held during the
// fetch on purpose: concurrent callers wait for it and then hit the cache.
func cachedNodeHosts(client *APIClient) ([]string, error) {
	nodeCacheMu.Lock()
	defer nodeCacheMu.Unlock()

	if len(nodeCacheHosts) > 0 && time.Since(nodeCacheAt) < nodeCacheTTL {
		return nodeCacheHosts, nil
	}

	hosts, err := client.getNodeHosts()

	if err != nil {
		if len(nodeCacheHosts) > 0 {
			// Keep using the last good list and retry in ~20 seconds.
			nodeCacheAt = time.Now().Add(-(nodeCacheTTL - 20*time.Second))

			return nodeCacheHosts, nil
		}

		return nil, err
	}

	if len(hosts) > 0 {
		nodeCacheHosts = hosts
		nodeCacheAt = time.Now()
	}

	return hosts, nil
}

func kickAgentURLs(client *APIClient, cfg *Config) []string {
	urls := make([]string, 0)
	seen := make(map[string]struct{})

	add := func(raw string) {
		u := normalizeAgentURL(raw, cfg.Kick.AgentPort)

		if u == "" {
			return
		}

		if _, ok := seen[u]; ok {
			return
		}

		seen[u] = struct{}{}
		urls = append(urls, u)
	}

	hosts, err := cachedNodeHosts(client)
	if err != nil {
		logger.Printf("KICK | node list from panel failed: %v", err)
	}

	for _, host := range hosts {
		add(host)
	}

	for _, extra := range cfg.Kick.ExtraAgents {
		add(extra)
	}

	return urls
}

func newKickHTTPClient(cfg *Config) *http.Client {
	return &http.Client{
		Timeout: time.Duration(cfg.Kick.TimeoutSeconds) * time.Second,
		Transport: &http.Transport{
			// Agents use a self-signed certificate. Requests are
			// authenticated with an HMAC signature instead.
			TLSClientConfig:   &tls.Config{InsecureSkipVerify: true},
			DisableKeepAlives: true,
		},
	}
}

func callAgent(
	hc *http.Client,
	token string,
	baseURL string,
	method string,
	path string,
	payload interface{},
) ([]byte, error) {
	var body []byte

	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}

		body = encoded
	}

	req, err := http.NewRequest(
		method,
		baseURL+path,
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, err
	}

	ts := strconv.FormatInt(time.Now().Unix(), 10)
	nonce := newNonce()

	req.Header.Set(kickHeaderTS, ts)
	req.Header.Set(kickHeaderNonce, nonce)
	req.Header.Set(
		kickHeaderSig,
		kickSign(token, ts, nonce, method, path, body),
	)

	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}

	defer resp.Body.Close()

	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf(
			"HTTP %d: %s",
			resp.StatusCode,
			trimBody(data),
		)
	}

	return data, nil
}

func kickIPsNow(
	client *APIClient,
	cfg *Config,
	label string,
	ips []string,
	seconds int64,
) {
	if cfg.Kick.Mode != "agents" || len(ips) == 0 {
		return
	}

	token := cfg.Kick.AgentToken

	if token == "" {
		logger.Printf("KICK | kick.agent_token is empty; skipping %s", label)
		return
	}

	if len(ips) > kickMaxIPsPerCall {
		ips = ips[:kickMaxIPsPerCall]
	}

	if seconds < 1 {
		seconds = 1
	}

	if limit := int64(cfg.Kick.MaxBlockSeconds); seconds > limit {
		seconds = limit
	}

	targets := kickAgentURLs(client, cfg)

	if len(targets) == 0 {
		logger.Printf("KICK | no agents to contact for %s", label)
		return
	}

	request := kickRequest{
		IPs:     ips,
		Seconds: seconds,
		Block:   boolOr(cfg.Kick.BlockIP, true),
		Kill:    boolOr(cfg.Kick.KillSockets, true),
		Reason:  label,
	}

	hc := newKickHTTPClient(cfg)

	var wg sync.WaitGroup

	for _, target := range targets {
		target := target

		wg.Add(1)

		go func() {
			defer wg.Done()

			data, err := callAgent(
				hc,
				token,
				target,
				http.MethodPost,
				"/v1/block",
				request,
			)
			if err != nil {
				logger.Printf(
					"KICK | %s agent=%s failed: %v",
					label,
					target,
					err,
				)
				return
			}

			var result kickResponse

			if err := json.Unmarshal(data, &result); err != nil {
				logger.Printf(
					"KICK | %s agent=%s unreadable reply: %s",
					label,
					target,
					trimBody(data),
				)
				return
			}

			logger.Printf(
				"KICK | %s agent=%s blocked=%d killed=%d skipped=%d for %ds",
				label,
				target,
				len(result.Blocked),
				result.Killed,
				len(result.Skipped),
				seconds,
			)
		}()
	}

	wg.Wait()
}

func kickUser(
	client *APIClient,
	cfg *Config,
	userID string,
	username string,
	ips map[string]struct{},
	seconds int64,
	reason string,
) {
	if cfg.Kick.Mode != "agents" || len(ips) == 0 {
		return
	}

	list := make([]string, 0, len(ips))

	for raw := range ips {
		if ip := cleanIPString(raw); ip != "" {
			list = append(list, ip)
		}
	}

	if len(list) == 0 {
		return
	}

	kickMu.Lock()
	kickLast[userID] = time.Now().Unix()
	kickMu.Unlock()

	label := fmt.Sprintf(
		"%s user=%s username=%s",
		reason,
		userID,
		username,
	)

	go kickIPsNow(client, cfg, label, list, seconds)
}

// maybeRekick handles users we already disabled who still show up as online
// (for example when the first kick missed an agent or the IP changed).
func maybeRekick(
	client *APIClient,
	cfg *Config,
	state *RuntimeState,
	userID string,
	username string,
	ips map[string]struct{},
) {
	if cfg.Kick.Mode != "agents" || len(ips) == 0 {
		return
	}

	stateMu.Lock()
	block, ok := state.BlockedUsers[userID]
	stateMu.Unlock()

	if !ok {
		return
	}

	now := time.Now().Unix()
	remaining := block.BlockedAt + block.Duration - now

	if remaining < 1 {
		return
	}

	kickMu.Lock()
	last := kickLast[userID]
	kickMu.Unlock()

	if now-last < kickRetrySeconds {
		return
	}

	reason := "ip_limit-recheck"

	if block.AbuseBan {
		reason = "anti_abuse-recheck"
	}

	kickUser(client, cfg, userID, username, ips, remaining, reason)
}

// ---------------------------------------------------------------------------
// Command line helpers: pg_ip_limit --kick-test | --kick-block IP [SECONDS]
// ---------------------------------------------------------------------------

func runCLI(cfg Config, args []string) int {
	switch args[0] {
	case "--kick-test":
		return cliKickTest(&cfg)

	case "--kick-block":
		return cliKickBlock(&cfg, args[1:])

	default:
		fmt.Fprintf(
			os.Stderr,
			"unknown option %q\nusage: pg_ip_limit [--kick-test | --kick-block IP [SECONDS]]\n",
			args[0],
		)
		return 2
	}
}

func cliPanelClient(cfg *Config) (*APIClient, error) {
	client, err := newAPIClient(*cfg)
	if err != nil {
		return nil, err
	}

	if err := client.login(); err != nil {
		return nil, fmt.Errorf("panel login failed: %w", err)
	}

	return client, nil
}

func cliKickTest(cfg *Config) int {
	if cfg.Kick.AgentToken == "" {
		fmt.Println("kick.agent_token is empty in config.json")
		return 1
	}

	client, err := cliPanelClient(cfg)
	if err != nil {
		fmt.Println(err)
		return 1
	}

	targets := kickAgentURLs(client, cfg)

	if len(targets) == 0 {
		fmt.Println("no agents found (panel returned no nodes and extra_agents is empty)")
		return 1
	}

	hc := newKickHTTPClient(cfg)
	failed := 0

	for _, target := range targets {
		data, err := callAgent(
			hc,
			cfg.Kick.AgentToken,
			target,
			http.MethodGet,
			"/v1/health",
			nil,
		)
		if err != nil {
			fmt.Printf("FAIL  %s  %v\n", target, err)
			failed++
			continue
		}

		fmt.Printf("OK    %s  %s\n", target, strings.TrimSpace(string(data)))
	}

	if failed > 0 {
		return 1
	}

	return 0
}

func cliKickBlock(cfg *Config, args []string) int {
	if len(args) < 1 {
		fmt.Println("usage: pg_ip_limit --kick-block IP [SECONDS]")
		return 2
	}

	ip := cleanIPString(args[0])

	if ip == "" {
		fmt.Println("invalid IP address")
		return 2
	}

	seconds := int64(60)

	if len(args) > 1 {
		value, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil || value < 1 {
			fmt.Println("SECONDS must be a positive integer")
			return 2
		}

		seconds = value
	}

	client, err := cliPanelClient(cfg)
	if err != nil {
		fmt.Println(err)
		return 1
	}

	cfg.Kick.Mode = "agents"

	kickIPsNow(client, cfg, "manual-test", []string{ip}, seconds)

	return 0
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

    ok "TeperIP built successfully: $BINARY_FILE"
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

    log "Testing connection to PasarGuard..."

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

        ok "API authentication successful."
        return 0
    fi

    warn "API test failed. HTTP=$status"
    warn "Service will be installed, but please check your credentials and panel URL."

    return 1
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
DB_FILE="$INSTALL_DIR/teperip.db"
BINARY_FILE="$INSTALL_DIR/pg_ip_limit"
BACKUP_DIR="$INSTALL_DIR/backups"

SERVICE_NAME="pg_iplimit.service"

CURRENT_VERSION="1.4.0"

INSTALLER_URL="https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-install.sh"

GITHUB_RELEASES_URL="https://api.github.com/repos/Jyavaz68/teperip/releases/latest"
AGENT_INSTALLER_URL="https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-agent-install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pause_menu() {
    echo
    read -r -p "Press Enter to continue... " _
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
    echo "Kick:           $(read_config_value '.kick.mode // "off"' off)"
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

    echo "Press Ctrl+C to exit."

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
            echo "Value must be a number."
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
            -p "Select: " \
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
                echo "Invalid selection."
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

    echo "Current version: v$CURRENT_VERSION"

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

        echo "Check source: Published version on main"

    else

        echo "Check source: GitHub Release"

    fi

    if [[ -z "$latest" ]]; then
        echo "Could not connect to GitHub."
        pause_menu
        return
    fi

    if version_gt \
        "$latest" \
        "$CURRENT_VERSION"
    then

        echo -e \
            "${YELLOW}[!] New version found: v$latest${NC}"

        read -r \
            -p "Do you want to update? (y/n): " \
            confirm

        [[ "$confirm" =~ ^[Yy]$ ]] ||
            return

    elif version_eq \
        "$latest" \
        "$CURRENT_VERSION"
    then

        echo -e \
            "${GREEN}[OK] You are using the latest version.${NC}"

        read -r \
            -p "Do you want to reinstall? (y/n): " \
            confirm

        [[ "$confirm" =~ ^[Yy]$ ]] ||
            return

    else

        echo "Installed version is newer than checked version."

        pause_menu

        return
    fi

    installer="$(
        get_installer ||
        true
    )"

    if [[ -z "$installer" ]]; then
        echo "Failed to download installer."
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

        echo "Installer on main is older than the installed version; update aborted."

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
            echo "JSON is corrupted."
            return 1
        }

    systemctl restart "$SERVICE_NAME"
}

uninstall() {
    echo "Type REMOVE to completely uninstall:"

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

    echo "Service removed."

    echo "Delete data? (y/n)"

    read -r d

    [[ "$d" =~ ^[Yy]$ ]] &&
        rm -rf "$INSTALL_DIR"
}

cfg_set_json() {
    # usage: cfg_set_json '.kick.mode' '"agents"'   (value must be valid JSON)
    local path="$1"
    local value="$2"
    local t

    t="$(mktemp)"

    if jq --argjson v "$value" "$path = \$v" "$CONFIG_FILE" > "$t"; then
        chmod 600 "$t"
        mv "$t" "$CONFIG_FILE"
    else
        rm -f "$t"
        echo "Failed to update config.json."
        return 1
    fi
}

cfg_set_string() {
    local path="$1"
    local value="$2"
    local t

    t="$(mktemp)"

    if jq --arg v "$value" "$path = \$v" "$CONFIG_FILE" > "$t"; then
        chmod 600 "$t"
        mv "$t" "$CONFIG_FILE"
    else
        rm -f "$t"
        echo "Failed to update config.json."
        return 1
    fi
}

generate_token() {
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

show_agent_install_command() {
    local token port master_ip detected

    token="$(read_config_value '.kick.agent_token // ""' '')"
    port="$(read_config_value '.kick.agent_port // 8765' 8765)"
    master_ip="$(read_config_value '.kick.master_ip // ""' '')"

    if [[ -z "$master_ip" ]]; then
        detected="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

        read -r -p "Public IP of THIS (panel) server [${detected:-unknown}]: " master_ip
        master_ip="${master_ip:-$detected}"

        if [[ -z "$master_ip" ]]; then
            echo "No IP given."
            return 1
        fi

        cfg_set_string '.kick.master_ip' "$master_ip" || true
    fi

    echo
    echo "Run this on EVERY node server (as root):"
    echo
    echo "curl -fsSL $AGENT_INSTALLER_URL | sudo bash -s -- --token $token --master-ip $master_ip --port $port"
    echo
    echo "Small server (<1GB RAM)? Add --prebuilt to avoid compiling on the node."
    echo "If the panel and a node share one server, also run it there and add"
    echo "https://127.0.0.1:$port as an extra agent (option 8)."
}

kick_menu() {
    while true; do

        clear

        echo -e "${CYAN}━━━━━━━━━━━━ Kick Settings (node agents) ━━━━━━━━━━━━${NC}"

        local mode port token master_ip block kill maxb extra c x

        mode="$(read_config_value '.kick.mode // "off"' off)"
        port="$(read_config_value '.kick.agent_port // 8765' 8765)"
        token="$(read_config_value '.kick.agent_token // ""' '')"
        master_ip="$(read_config_value '.kick.master_ip // ""' '')"
        block="$(read_config_value 'if .kick.block_ip == null then true else .kick.block_ip end' true)"
        kill="$(read_config_value 'if .kick.kill_sockets == null then true else .kick.kill_sockets end' true)"
        maxb="$(read_config_value '.kick.max_block_seconds // 3600' 3600)"
        extra="$(read_config_value '(.kick.extra_agents // []) | join(",")' '')"

        echo "Mode:               $mode"
        echo "Agent port:         $port"
        echo "Agent token:        ${token:0:8}... (hidden)"
        echo "Panel server IP:    ${master_ip:-not set}"
        echo "Block IP (nft):     $block"
        echo "Kill sockets (ss):  $kill"
        echo "Max block seconds:  $maxb"
        echo "Extra agents:       ${extra:-none}"

        echo

        echo "1) Enable / Disable kick"
        echo "2) Show node install command"
        echo "3) Test agents (health check)"
        echo "4) Regenerate token"
        echo "5) Set panel server IP"
        echo "6) Change agent port"
        echo "7) Toggle block IP / kill sockets"
        echo "8) Add extra agent URL"
        echo "9) Clear extra agents"
        echo "0) Back"

        echo

        read -r -p "Select: " c

        case "$c" in

            1)
                if [[ "$mode" == "agents" ]]; then
                    cfg_set_json '.kick.mode' '"off"' || true
                    echo "Kick disabled."
                else
                    if [[ -z "$token" ]]; then
                        cfg_set_string '.kick.agent_token' "$(generate_token)" || true
                    fi

                    cfg_set_json '.kick.mode' '"agents"' || true
                    echo "Kick enabled. Make sure the agent is installed on your nodes (option 2),"
                    echo "then verify with option 3."
                fi

                systemctl restart "$SERVICE_NAME" || true
                pause_menu
                ;;

            2)
                show_agent_install_command || true
                pause_menu
                ;;

            3)
                echo
                "$BINARY_FILE" --kick-test || true
                pause_menu
                ;;

            4)
                read -r -p "Regenerate the token? Agents must be reinstalled with the new one. (y/n): " x

                if [[ "$x" =~ ^[Yy]$ ]]; then
                    cfg_set_string '.kick.agent_token' "$(generate_token)" || true
                    systemctl restart "$SERVICE_NAME" || true
                    echo "New token saved. Re-run the install command (option 2) on every node."
                fi

                pause_menu
                ;;

            5)
                read -r -p "Public IP of this panel server [$master_ip]: " x
                x="${x:-$master_ip}"

                if [[ -n "$x" ]]; then
                    cfg_set_string '.kick.master_ip' "$x" || true
                fi
                ;;

            6)
                read -r -p "Agent port [$port]: " x
                x="${x:-$port}"

                if [[ "$x" =~ ^[0-9]+$ ]] && ((x >= 1 && x <= 65535)); then
                    cfg_set_json '.kick.agent_port' "$((10#$x))" || true
                    systemctl restart "$SERVICE_NAME" || true
                    echo "Agents must listen on the same port; re-run the install command on the nodes."
                else
                    echo "Invalid port."
                fi

                pause_menu
                ;;

            7)
                echo "a) block IP in nftables   (currently: $block)"
                echo "b) kill established sockets (currently: $kill)"

                read -r -p "Toggle which one (a/b): " x

                case "$x" in
                    a)
                        if [[ "$block" == "true" ]]; then
                            cfg_set_json '.kick.block_ip' false || true
                        else
                            cfg_set_json '.kick.block_ip' true || true
                        fi
                        ;;
                    b)
                        if [[ "$kill" == "true" ]]; then
                            cfg_set_json '.kick.kill_sockets' false || true
                        else
                            cfg_set_json '.kick.kill_sockets' true || true
                        fi
                        ;;
                    *)
                        echo "Nothing changed."
                        ;;
                esac

                systemctl restart "$SERVICE_NAME" || true
                pause_menu
                ;;

            8)
                read -r -p "Agent URL (e.g. https://127.0.0.1:$port): " x

                if [[ -n "$x" ]]; then
                    local t
                    t="$(mktemp)"

                    if jq --arg u "$x" '.kick.extra_agents = (((.kick.extra_agents // []) + [$u]) | unique)' "$CONFIG_FILE" > "$t"; then
                        chmod 600 "$t"
                        mv "$t" "$CONFIG_FILE"
                        systemctl restart "$SERVICE_NAME" || true
                        echo "Added."
                    else
                        rm -f "$t"
                        echo "Failed to update config.json."
                    fi
                fi

                pause_menu
                ;;

            9)
                cfg_set_json '.kick.extra_agents' '[]' || true
                systemctl restart "$SERVICE_NAME" || true
                echo "Cleared."
                pause_menu
                ;;

            0)
                return
                ;;

            *)
                echo "Invalid selection."
                sleep 1
                ;;

        esac

    done
}

show_active_blocks() {
    clear

    echo -e "${CYAN}━━━━━━━━━━━━ Active TeperIP Blocks ━━━━━━━━━━━━${NC}"
    echo

    if [[ ! -f "$DB_FILE" ]]; then
        echo "No TeperIP database found."
        return 0
    fi

    local count=0 now remaining blocked_at duration username reason user_id
    now="$(date +%s)"

    while IFS=$'\t' read -r user_id username reason blocked_at duration; do
        [[ -n "$user_id" ]] || continue
        count=$((count + 1))

        if [[ "$blocked_at" =~ ^[0-9]+$ && "$duration" =~ ^[0-9]+$ ]]; then
            remaining=$((blocked_at + duration - now))
            (( remaining < 0 )) && remaining=0
        else
            remaining="?"
        fi

        echo "#$count"
        echo "  Username : ${username:-unknown}"
        echo "  User ID  : $user_id"
        echo "  Reason   : $reason"
        echo "  Blocked  : $(date -d "@$blocked_at" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$blocked_at")"
        echo "  Remaining: ${remaining}s"
        echo
    done < <(
        sqlite3 -separator $'\t' "$DB_FILE" \
            'SELECT user_id, username, reason, blocked_at, duration FROM disabled_users ORDER BY blocked_at DESC;' \
            2>/dev/null || true
    )

    if ((count == 0)); then
        echo "No users are currently disabled by TeperIP."
    else
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "Active TeperIP blocks: $count"
    fi
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
    echo "11) Active TeperIP Blocks"
    echo "12) Kick Settings (node agents)"
    echo "0) Exit"

    echo

    read -r \
        -p "Select: " \
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
            echo "Service restarted."
            pause_menu
            ;;

        4)
            systemctl start "$SERVICE_NAME"
            echo "Service started."
            pause_menu
            ;;

        5)
            systemctl stop "$SERVICE_NAME"
            echo "Service stopped."
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

        11)
            show_active_blocks
            pause_menu
            ;;

        12)
            kick_menu
            ;;

        0)
            exit 0
            ;;

        *)
            echo "Invalid selection."
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

        ok "TeperIP service is active."

    else

        warn "Service failed to start."

        warn \
            "Log: journalctl -u $SERVICE_NAME -n 100 --no-pager"

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
        log "Current panel settings will be preserved."
    fi

    create_initial_state

    initialize_database
    migrate_blocked_users_to_database

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
        "${GREEN}TeperIP v$CURRENT_VERSION installed successfully.${NC}"

    echo "Management: teperip"
    echo "Service:    $SERVICE_NAME"
    echo "Config:     $CONFIG_FILE"
    echo "State:      $STATE_FILE"
    echo "Database:   $DB_FILE"
    echo "Kick:       off (enable it from the menu: teperip -> 12)"

    echo -e \
        "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

main() {
    install_all
}

main "$@"
