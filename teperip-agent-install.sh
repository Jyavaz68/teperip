#!/usr/bin/env bash
# TeperIP node agent installer.
#
# Run this on every PasarGuard NODE server (not on the panel/master).
# The `teperip` menu on the master prints the exact command for you:
#
#   curl -fsSL https://raw.githubusercontent.com/Jyavaz68/teperip/main/teperip-agent-install.sh \
#     | sudo bash -s -- --token <TOKEN> --master-ip <MASTER_IP> [--port 8765]
#
set -euo pipefail

AGENT_VERSION="1.0.0"

INSTALL_DIR="/opt/teperip-agent"
CONF_DIR="/etc/teperip-agent"
CONFIG_FILE="$CONF_DIR/config.json"
BINARY_FILE="$INSTALL_DIR/teperip-agent"
GO_SRC_FILE="$INSTALL_DIR/main.go"
GO_MOD_FILE="$INSTALL_DIR/go.mod"

SERVICE_NAME="teperip-agent.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
CLI_FILE="/usr/local/bin/teperip-agent"

RELEASE_BASE="https://github.com/Jyavaz68/teperip/releases/latest/download"

GO_MIN_MAJOR=1
GO_MIN_MINOR=18

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

ACTION="install"
TOKEN=""
MASTER_IPS=""
PORT=""
TRY_PREBUILT=0

usage() {
    cat <<'USAGE'
TeperIP node agent installer

Usage:
  teperip-agent-install.sh [install] --token TOKEN --master-ip IP[,IP...] [--port 8765] [--prebuilt]
  teperip-agent-install.sh uninstall

Options:
  --token TOKEN        Shared secret (at least 32 characters). Must match
                       kick.agent_token in the master's config.json.
  --master-ip IPS      IP address(es) of the panel/master server, comma separated.
                       Use "any" to skip the source IP check (not recommended).
  --port PORT          TCP port of the agent API (default 8765).
  --prebuilt           Try a prebuilt binary from GitHub Releases first
                       (useful on servers with little RAM). Falls back to
                       building from source.
USAGE
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        err "This script must be run as root."
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            install|uninstall)
                ACTION="$1"
                ;;
            --token)
                TOKEN="${2:-}"
                shift
                ;;
            --token=*)
                TOKEN="${1#*=}"
                ;;
            --master-ip)
                MASTER_IPS="${2:-}"
                shift
                ;;
            --master-ip=*)
                MASTER_IPS="${1#*=}"
                ;;
            --port)
                PORT="${2:-}"
                shift
                ;;
            --port=*)
                PORT="${1#*=}"
                ;;
            --prebuilt)
                TRY_PREBUILT=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                err "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

is_valid_ip_or_any() {
    local value="$1"

    [[ "$value" == "any" ]] && return 0

    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local octet
        local IFS=.
        for octet in $value; do
            ((10#$octet <= 255)) || return 1
        done
        return 0
    fi

    [[ "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:.]+$ ]]
}

load_existing_config() {
    [[ -s "$CONFIG_FILE" ]] || return 0
    command_exists jq || return 0

    if [[ -z "$TOKEN" ]]; then
        TOKEN="$(jq -r '.token // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    fi

    if [[ -z "$MASTER_IPS" ]]; then
        MASTER_IPS="$(jq -r '(.master_ips // []) | join(",")' "$CONFIG_FILE" 2>/dev/null || true)"
    fi

    if [[ -z "$PORT" ]]; then
        PORT="$(jq -r '.listen // empty' "$CONFIG_FILE" 2>/dev/null | sed 's/^.*://' || true)"
    fi
}

validate_inputs() {
    local ip
    local -a list

    if [[ -z "$TOKEN" && -t 0 ]]; then
        read -r -p "Agent token (same as kick.agent_token on the master): " TOKEN
    fi

    if [[ -z "$MASTER_IPS" && -t 0 ]]; then
        read -r -p "Master (panel server) IP address: " MASTER_IPS
    fi

    PORT="${PORT:-8765}"
    MASTER_IPS="${MASTER_IPS// /}"

    if [[ -z "$TOKEN" ]]; then
        err "Missing --token."
        usage
        exit 1
    fi

    if ((${#TOKEN} < 32)) || ! [[ "$TOKEN" =~ ^[A-Za-z0-9._~-]+$ ]]; then
        err "Token must be at least 32 characters of [A-Za-z0-9._~-]."
        exit 1
    fi

    if [[ -z "$MASTER_IPS" ]]; then
        err "Missing --master-ip."
        usage
        exit 1
    fi

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
        err "Invalid port: $PORT"
        exit 1
    fi

    IFS=',' read -r -a list <<< "$MASTER_IPS"

    for ip in "${list[@]}"; do
        [[ -n "$ip" ]] || continue

        if ! is_valid_ip_or_any "$ip"; then
            err "Invalid master IP: $ip"
            exit 1
        fi
    done

    if [[ ",$MASTER_IPS," == *",any,"* ]]; then
        warn "master-ip=any disables the source IP check; only the HMAC token protects the API."
    fi
}

ensure_dependencies() {
    local missing=()
    local cmd

    for cmd in curl jq tar nft ss sha256sum systemctl; do
        command_exists "$cmd" || missing+=("$cmd")
    done

    if ((${#missing[@]} == 0)); then
        return 0
    fi

    log "Installing required dependencies: ${missing[*]}"

    if command_exists apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y nftables iproute2 curl jq tar coreutils ca-certificates systemd
    elif command_exists dnf; then
        dnf install -y nftables iproute curl jq tar coreutils ca-certificates systemd
    elif command_exists yum; then
        yum install -y nftables iproute curl jq tar coreutils ca-certificates systemd
    else
        err "Supported package manager not found."
        exit 1
    fi

    for cmd in curl jq tar nft ss sha256sum systemctl; do
        if ! command_exists "$cmd"; then
            err "Required command is still missing: $cmd"
            exit 1
        fi
    done
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             return 1 ;;
    esac
}

low_memory() {
    local mem_kb swap_kb

    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"

    ((mem_kb > 0 && mem_kb < 900000 && swap_kb == 0))
}

go_version_string() {
    go version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || true
}

go_version_ok() {
    local version major rest minor

    version="$(go_version_string)"
    [[ -n "$version" ]] || return 1

    major="${version%%.*}"
    rest="${version#*.}"
    minor="${rest%%.*}"

    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    [[ "$minor" =~ ^[0-9]+$ ]] || return 1

    if ((major > GO_MIN_MAJOR)); then
        return 0
    fi

    ((major == GO_MIN_MAJOR && minor >= GO_MIN_MINOR))
}

install_official_go() {
    local arch latest_go tarball tmp_dir url

    arch="$(detect_arch)" || {
        err "Architecture $(uname -m) is not supported for automatic Go installation."
        return 1
    }

    log "Fetching the latest stable Go version ..."

    latest_go="$(
        curl -fsSL --max-time 15 'https://go.dev/dl/?mode=json' |
            jq -r '[.[] | select(.stable == true)][0].version // empty'
    )" || true

    if [[ -z "$latest_go" || "$latest_go" == "null" ]]; then
        err "Failed to fetch the Go version from go.dev."
        return 1
    fi

    url="https://go.dev/dl/${latest_go}.linux-${arch}.tar.gz"
    tarball="$(mktemp /tmp/go.XXXXXX.tar.gz)"
    tmp_dir="$(mktemp -d /tmp/go-install.XXXXXX)"

    log "Downloading $latest_go ..."

    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 180 "$url" -o "$tarball"; then
        rm -f "$tarball"
        rm -rf "$tmp_dir"
        err "Go download failed."
        return 1
    fi

    tar -xzf "$tarball" -C "$tmp_dir"

    if [[ ! -x "$tmp_dir/go/bin/go" ]]; then
        rm -f "$tarball"
        rm -rf "$tmp_dir"
        err "Invalid Go archive."
        return 1
    fi

    if [[ -d /usr/local/go ]]; then
        mv /usr/local/go "/usr/local/go.backup.$(date +%Y%m%d%H%M%S)"
    fi

    mv "$tmp_dir/go" /usr/local/go
    rm -f "$tarball"
    rm -rf "$tmp_dir"

    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

    export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"
    hash -r 2>/dev/null || true

    if ! go_version_ok; then
        err "Go installed but version is too old: $(go_version_string)"
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

    install_official_go
}

write_go_source() {
cat > "$GO_SRC_FILE" <<'GO'
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	agentVersion = "1.0.0"

	headerTS    = "X-Teperip-Ts"
	headerNonce = "X-Teperip-Nonce"
	headerSig   = "X-Teperip-Sig"

	maxClockSkew  = 60 // seconds
	replayKeepFor = 180

	nftRuleset = `
table inet teperip {
	set block4 {
		type ipv4_addr
		flags timeout
	}
	set block6 {
		type ipv6_addr
		flags timeout
	}
	chain prerouting {
		type filter hook prerouting priority -300; policy accept;
		ip saddr @block4 drop
		ip6 saddr @block6 drop
	}
}
`
)

type agentConfig struct {
	Token      string   `json:"token"`
	Listen     string   `json:"listen"`
	MasterIPs  []string `json:"master_ips"`
	MaxIPs     int      `json:"max_ips"`
	MaxSeconds int64    `json:"max_seconds"`
	CertFile   string   `json:"cert_file"`
	KeyFile    string   `json:"key_file"`
}

type blockRequest struct {
	IPs     []string `json:"ips"`
	Seconds int64    `json:"seconds"`
	Block   bool     `json:"block"`
	Kill    bool     `json:"kill"`
	Reason  string   `json:"reason"`
}

type unblockRequest struct {
	IPs []string `json:"ips"`
	All bool     `json:"all"`
}

type blockResponse struct {
	OK      bool     `json:"ok"`
	Blocked []string `json:"blocked"`
	Killed  int      `json:"killed"`
	Skipped []string `json:"skipped"`
	Error   string   `json:"error,omitempty"`
}

var (
	cfg agentConfig

	anyMaster bool
	masterIPs []net.IP

	nftMu sync.Mutex

	replayMu   sync.Mutex
	replaySeen = make(map[string]int64)
)

func main() {
	path := "/etc/teperip-agent/config.json"

	if v := os.Getenv("TEPERIP_AGENT_CONFIG"); v != "" {
		path = v
	}

	if err := loadAgentConfig(path); err != nil {
		log.Fatalf("config error: %v", err)
	}

	if err := ensureNftRules(); err != nil {
		log.Fatalf("nftables setup failed: %v", err)
	}

	if err := ensureCert(cfg.CertFile, cfg.KeyFile); err != nil {
		log.Fatalf("certificate error: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/health", withAuth(http.MethodGet, handleHealth))
	mux.HandleFunc("/v1/block", withAuth(http.MethodPost, handleBlock))
	mux.HandleFunc("/v1/unblock", withAuth(http.MethodPost, handleUnblock))
	mux.HandleFunc("/v1/list", withAuth(http.MethodGet, handleList))

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    1 << 14,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
		// Internet scanners hitting the port would otherwise flood the log.
		ErrorLog: log.New(io.Discard, "", 0),
	}

	log.Printf(
		"teperip-agent %s listening on %s (master_ips=%s)",
		agentVersion,
		cfg.Listen,
		describeMasters(),
	)

	errCh := make(chan error, 1)

	go func() {
		errCh <- srv.ListenAndServeTLS(cfg.CertFile, cfg.KeyFile)
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-errCh:
		log.Fatalf("server stopped: %v", err)

	case sig := <-sigCh:
		log.Printf("received %s; shutting down", sig)

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		_ = srv.Shutdown(ctx)
	}
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

func loadAgentConfig(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}

	if err := json.Unmarshal(data, &cfg); err != nil {
		return err
	}

	if len(cfg.Token) < 32 {
		return errors.New("token must be at least 32 characters")
	}

	if cfg.Listen == "" {
		cfg.Listen = ":8765"
	}

	if cfg.MaxIPs < 1 {
		cfg.MaxIPs = 200
	}

	if cfg.MaxSeconds < 1 {
		cfg.MaxSeconds = 86400
	}

	if cfg.CertFile == "" {
		cfg.CertFile = "/etc/teperip-agent/cert.pem"
	}

	if cfg.KeyFile == "" {
		cfg.KeyFile = "/etc/teperip-agent/key.pem"
	}

	for _, raw := range cfg.MasterIPs {
		raw = strings.TrimSpace(raw)

		if raw == "" {
			continue
		}

		if strings.EqualFold(raw, "any") {
			anyMaster = true
			continue
		}

		ip := net.ParseIP(raw)

		if ip == nil {
			return fmt.Errorf("invalid master IP %q", raw)
		}

		masterIPs = append(masterIPs, ip)
	}

	if !anyMaster && len(masterIPs) == 0 {
		return errors.New(
			"master_ips is empty; set the panel server IP or \"any\"",
		)
	}

	return nil
}

func describeMasters() string {
	if anyMaster {
		return "any"
	}

	parts := make([]string, 0, len(masterIPs))

	for _, ip := range masterIPs {
		parts = append(parts, ip.String())
	}

	return strings.Join(parts, ",")
}

// ---------------------------------------------------------------------------
// Authentication: source IP check + HMAC signature + replay protection
// ---------------------------------------------------------------------------

func sourceAllowed(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return false
	}

	ip := net.ParseIP(host)

	if ip == nil {
		return false
	}

	// Local processes (master and node on the same server) are always fine.
	if ip.IsLoopback() || anyMaster {
		return true
	}

	for _, master := range masterIPs {
		if master.Equal(ip) {
			return true
		}
	}

	return false
}

func sign(
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

func replayed(nonce string, now int64) bool {
	replayMu.Lock()
	defer replayMu.Unlock()

	for key, seenAt := range replaySeen {
		if now-seenAt > replayKeepFor {
			delete(replaySeen, key)
		}
	}

	if _, ok := replaySeen[nonce]; ok {
		return true
	}

	replaySeen[nonce] = now

	return false
}

func withAuth(
	method string,
	next func(http.ResponseWriter, *http.Request, []byte),
) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !sourceAllowed(r.RemoteAddr) {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}

		if r.Method != method {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
		if err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}

		ts := r.Header.Get(headerTS)
		nonce := r.Header.Get(headerNonce)
		sig := r.Header.Get(headerSig)

		tsValue, err := strconv.ParseInt(ts, 10, 64)
		now := time.Now().Unix()

		if err != nil ||
			tsValue > now+maxClockSkew ||
			tsValue < now-maxClockSkew ||
			len(nonce) < 8 ||
			len(nonce) > 64 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		expected := sign(cfg.Token, ts, nonce, r.Method, r.URL.Path, body)

		if subtle.ConstantTimeCompare([]byte(expected), []byte(sig)) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		if replayed(nonce, now) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		next(w, r, body)
	}
}

func writeJSON(w http.ResponseWriter, status int, value interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

// ---------------------------------------------------------------------------
// nftables
// ---------------------------------------------------------------------------

func runCommand(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()

	return strings.TrimSpace(string(out)), err
}

func runNft(args ...string) (string, error) {
	return runCommand(10*time.Second, "nft", args...)
}

func ensureNftRules() error {
	if _, err := exec.LookPath("nft"); err != nil {
		return errors.New("nft binary not found (install nftables)")
	}

	nftMu.Lock()
	defer nftMu.Unlock()

	out, err := runNft("list", "table", "inet", "teperip")

	if err == nil &&
		strings.Contains(out, "@block4") &&
		strings.Contains(out, "@block6") {
		return nil
	}

	if err == nil {
		// Table exists but is not what we expect; rebuild it.
		if msg, delErr := runNft("delete", "table", "inet", "teperip"); delErr != nil {
			return fmt.Errorf("cannot reset table: %v: %s", delErr, msg)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "nft", "-f", "-")
	cmd.Stdin = strings.NewReader(nftRuleset)

	if combined, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf(
			"cannot load ruleset: %v: %s",
			err,
			strings.TrimSpace(string(combined)),
		)
	}

	return nil
}

func setNameFor(ip net.IP) (string, string) {
	if v4 := ip.To4(); v4 != nil {
		return "block4", v4.String()
	}

	return "block6", ip.String()
}

func nftBlock(ip net.IP, seconds int64) error {
	set, addr := setNameFor(ip)

	nftMu.Lock()
	defer nftMu.Unlock()

	// Re-adding an element does not always refresh its timeout, so remove it
	// first. The delete fails when the element is new; that is fine.
	_, _ = runNft("delete", "element", "inet", "teperip", set, "{ "+addr+" }")

	msg, err := runNft(
		"add", "element", "inet", "teperip", set,
		"{ "+addr+" timeout "+strconv.FormatInt(seconds, 10)+"s }",
	)

	if err != nil {
		return fmt.Errorf("%v: %s", err, msg)
	}

	return nil
}

func nftUnblock(ip net.IP) {
	set, addr := setNameFor(ip)

	nftMu.Lock()
	defer nftMu.Unlock()

	_, _ = runNft("delete", "element", "inet", "teperip", set, "{ "+addr+" }")
}

func nftFlushAll() error {
	nftMu.Lock()
	defer nftMu.Unlock()

	for _, set := range []string{"block4", "block6"} {
		if msg, err := runNft("flush", "set", "inet", "teperip", set); err != nil {
			return fmt.Errorf("%v: %s", err, msg)
		}
	}

	return nil
}

// killSockets destroys established sockets whose peer is ip. It is best
// effort: it needs `ss` from iproute2 and a kernel with sock_destroy support
// (CONFIG_INET_DIAG_DESTROY). Sockets that live in another network namespace
// (for example a bridged container) are not visible; the nftables drop still
// stalls those connections.
func killSockets(ip net.IP) (int, error) {
	if _, err := exec.LookPath("ss"); err != nil {
		return 0, errors.New("ss binary not found")
	}

	_, addr := setNameFor(ip)

	out, err := runCommand(5*time.Second, "ss", "-K", "-n", "dst", addr)

	if err != nil {
		return 0, fmt.Errorf("%v: %s", err, out)
	}

	count := 0

	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)

		if line == "" ||
			strings.HasPrefix(line, "Netid") ||
			strings.HasPrefix(line, "State") {
			continue
		}

		count++
	}

	return count, nil
}

// ---------------------------------------------------------------------------
// IP protection
// ---------------------------------------------------------------------------

func protectedReason(ip net.IP) string {
	switch {
	case ip.IsUnspecified(),
		ip.IsLoopback(),
		ip.IsPrivate(),
		ip.IsLinkLocalUnicast(),
		ip.IsLinkLocalMulticast(),
		ip.IsMulticast(),
		ip.Equal(net.IPv4bcast):
		return "non-public address"
	}

	for _, master := range masterIPs {
		if master.Equal(ip) {
			return "master address"
		}
	}

	addrs, err := net.InterfaceAddrs()

	if err == nil {
		for _, addr := range addrs {
			if ipNet, ok := addr.(*net.IPNet); ok && ipNet.IP.Equal(ip) {
				return "address of this node"
			}
		}
	}

	return ""
}

func sanitize(value string) string {
	value = strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return ' '
		}

		return r
	}, value)

	if len(value) > 120 {
		value = value[:120]
	}

	return strings.TrimSpace(value)
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

func handleHealth(w http.ResponseWriter, r *http.Request, _ []byte) {
	_, nftErr := runNft("list", "table", "inet", "teperip")
	_, ssErr := exec.LookPath("ss")

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok":      nftErr == nil,
		"version": agentVersion,
		"nft":     nftErr == nil,
		"ss":      ssErr == nil,
	})
}

func handleBlock(w http.ResponseWriter, r *http.Request, body []byte) {
	var req blockRequest

	if err := json.Unmarshal(body, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, blockResponse{Error: "invalid JSON"})
		return
	}

	if len(req.IPs) == 0 {
		writeJSON(w, http.StatusBadRequest, blockResponse{Error: "no ips given"})
		return
	}

	if len(req.IPs) > cfg.MaxIPs {
		writeJSON(w, http.StatusBadRequest, blockResponse{Error: "too many ips"})
		return
	}

	seconds := req.Seconds

	if seconds < 1 {
		seconds = 300
	}

	if seconds > cfg.MaxSeconds {
		seconds = cfg.MaxSeconds
	}

	resp := blockResponse{
		OK:      true,
		Blocked: []string{},
		Skipped: []string{},
	}

	for _, raw := range req.IPs {
		ip := net.ParseIP(strings.TrimSpace(raw))

		if ip == nil {
			resp.Skipped = append(resp.Skipped, "invalid:"+sanitize(raw))
			continue
		}

		if reason := protectedReason(ip); reason != "" {
			resp.Skipped = append(resp.Skipped, ip.String()+":protected")
			continue
		}

		if req.Block {
			if err := nftBlock(ip, seconds); err != nil {
				log.Printf("block %s failed: %v", ip, err)
				resp.Skipped = append(resp.Skipped, ip.String()+":nft-error")
				continue
			}

			resp.Blocked = append(resp.Blocked, ip.String())
		}

		if req.Kill {
			killed, err := killSockets(ip)

			if err != nil {
				log.Printf("kill sockets for %s failed: %v", ip, err)
			}

			resp.Killed += killed
		}
	}

	log.Printf(
		"block | reason=%q ips=%d blocked=%d killed=%d skipped=%d seconds=%d from=%s",
		sanitize(req.Reason),
		len(req.IPs),
		len(resp.Blocked),
		resp.Killed,
		len(resp.Skipped),
		seconds,
		r.RemoteAddr,
	)

	writeJSON(w, http.StatusOK, resp)
}

func handleUnblock(w http.ResponseWriter, r *http.Request, body []byte) {
	var req unblockRequest

	if err := json.Unmarshal(body, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, blockResponse{Error: "invalid JSON"})
		return
	}

	if req.All {
		if err := nftFlushAll(); err != nil {
			writeJSON(w, http.StatusInternalServerError, blockResponse{Error: err.Error()})
			return
		}

		log.Printf("unblock | all")
		writeJSON(w, http.StatusOK, blockResponse{OK: true})
		return
	}

	if len(req.IPs) > cfg.MaxIPs {
		writeJSON(w, http.StatusBadRequest, blockResponse{Error: "too many ips"})
		return
	}

	for _, raw := range req.IPs {
		if ip := net.ParseIP(strings.TrimSpace(raw)); ip != nil {
			nftUnblock(ip)
		}
	}

	log.Printf("unblock | ips=%d", len(req.IPs))
	writeJSON(w, http.StatusOK, blockResponse{OK: true})
}

func handleList(w http.ResponseWriter, r *http.Request, _ []byte) {
	out4, _ := runNft("list", "set", "inet", "teperip", "block4")
	out6, _ := runNft("list", "set", "inet", "teperip", "block6")

	writeJSON(w, http.StatusOK, map[string]string{
		"block4": out4,
		"block6": out6,
	})
}

// ---------------------------------------------------------------------------
// Self-signed certificate
// ---------------------------------------------------------------------------

func fileExists(path string) bool {
	info, err := os.Stat(path)

	return err == nil && !info.IsDir()
}

func ensureCert(certFile string, keyFile string) error {
	if fileExists(certFile) && fileExists(keyFile) {
		return nil
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 62))
	if err != nil {
		return err
	}

	now := time.Now()

	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "teperip-agent"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.AddDate(10, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"localhost"},
	}

	if host, err := os.Hostname(); err == nil && host != "" {
		template.DNSNames = append(template.DNSNames, host)
	}

	if addrs, err := net.InterfaceAddrs(); err == nil {
		for _, addr := range addrs {
			if ipNet, ok := addr.(*net.IPNet); ok {
				template.IPAddresses = append(template.IPAddresses, ipNet.IP)
			}
		}
	}

	der, err := x509.CreateCertificate(
		rand.Reader,
		template,
		template,
		&key.PublicKey,
		key,
	)
	if err != nil {
		return err
	}

	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(certFile), 0700); err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(keyFile), 0700); err != nil {
		return err
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})

	if err := os.WriteFile(certFile, certPEM, 0644); err != nil {
		return err
	}

	return os.WriteFile(keyFile, keyPEM, 0600)
}
GO

cat > "$GO_MOD_FILE" <<'MOD'
module teperipagent

go 1.18
MOD
}

try_prebuilt() {
    local arch url tmp tmp_sum expected actual

    arch="$(detect_arch)" || return 1

    url="${AGENT_BIN_URL:-$RELEASE_BASE/teperip-agent-linux-$arch}"

    tmp="$(mktemp)"
    tmp_sum="$(mktemp)"

    log "Trying prebuilt binary: $url"

    if ! curl -fsSL --connect-timeout 10 --max-time 90 "$url" -o "$tmp" 2>/dev/null ||
       ! curl -fsSL --connect-timeout 10 --max-time 30 "$url.sha256" -o "$tmp_sum" 2>/dev/null
    then
        rm -f "$tmp" "$tmp_sum"
        warn "No prebuilt binary available; building from source."
        return 1
    fi

    expected="$(awk 'NR==1 {print $1}' "$tmp_sum")"
    actual="$(sha256sum "$tmp" | awk '{print $1}')"

    rm -f "$tmp_sum"

    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        rm -f "$tmp"
        warn "Checksum mismatch for the prebuilt binary; building from source."
        return 1
    fi

    install -m 700 "$tmp" "$BINARY_FILE"
    rm -f "$tmp"

    ok "Installed prebuilt binary (checksum verified)."
}

build_binary() {
    ensure_go

    export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"

    cd "$INSTALL_DIR"

    gofmt -w "$GO_SRC_FILE"

    log "Building the agent (this can take a minute) ..."

    if ! GOMAXPROCS=1 GOFLAGS="-p=1" CGO_ENABLED=0 \
        go build -trimpath -ldflags='-s -w' -o "$BINARY_FILE" "$GO_SRC_FILE"
    then
        err "Build failed. On servers with little RAM try: --prebuilt, or add swap and retry."
        return 1
    fi

    chmod 700 "$BINARY_FILE"

    ok "Agent built: $BINARY_FILE"
}

write_config() {
    local masters_json tmp

    masters_json="$(
        printf '%s' "$MASTER_IPS" |
            jq -R 'split(",") | map(select(length > 0))'
    )"

    mkdir -p "$CONF_DIR"
    chmod 700 "$CONF_DIR"

    tmp="$(mktemp)"

    jq -n \
        --arg token "$TOKEN" \
        --arg listen ":$PORT" \
        --argjson masters "$masters_json" \
        '{
            token: $token,
            listen: $listen,
            master_ips: $masters,
            max_ips: 200,
            max_seconds: 86400
        }' > "$tmp"

    chmod 600 "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

configure_firewall() {
    local ip
    local family
    local -a list

    IFS=',' read -r -a list <<< "$MASTER_IPS"

    if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        for ip in "${list[@]}"; do
            [[ -n "$ip" ]] || continue

            if [[ "$ip" == "any" ]]; then
                ufw allow "$PORT/tcp" comment "teperip-agent" >/dev/null || true
            else
                ufw allow from "$ip" to any port "$PORT" proto tcp comment "teperip-agent" >/dev/null || true
            fi
        done

        ok "ufw rules added for TCP $PORT."

    elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        for ip in "${list[@]}"; do
            [[ -n "$ip" ]] || continue

            if [[ "$ip" == "any" ]]; then
                firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null || true
            else
                family="ipv4"
                [[ "$ip" == *:* ]] && family="ipv6"

                firewall-cmd --permanent --add-rich-rule="rule family=\"$family\" source address=\"$ip\" port port=\"$PORT\" protocol=\"tcp\" accept" >/dev/null || true
            fi
        done

        firewall-cmd --reload >/dev/null || true

        ok "firewalld rules added for TCP $PORT."

    else
        warn "No active ufw/firewalld detected. Make sure TCP $PORT is reachable from the master."
        warn "(The agent itself only accepts requests from: $MASTER_IPS)"
    fi
}

create_systemd_service() {
    cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=TeperIP node agent (nftables IP block + socket kill)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BINARY_FILE
Restart=always
RestartSec=5
User=root
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    chmod 644 "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

create_cli() {
    cat > "$CLI_FILE" <<'EOF_CLI'
#!/usr/bin/env bash
set -euo pipefail

SERVICE="teperip-agent.service"
CONF_DIR="/etc/teperip-agent"
INSTALL_DIR="/opt/teperip-agent"

case "${1:-}" in
    status)
        systemctl status "$SERVICE" --no-pager || true
        echo
        nft list table inet teperip 2>/dev/null | head -n 60 || echo "nft table not loaded"
        ;;
    logs)
        journalctl -u "$SERVICE" -f -n 80
        ;;
    list)
        nft list set inet teperip block4 || true
        nft list set inet teperip block6 || true
        ;;
    unblock-all)
        nft flush set inet teperip block4
        nft flush set inet teperip block6
        echo "All blocked IPs were removed."
        ;;
    restart)
        systemctl restart "$SERVICE"
        echo "Restarted."
        ;;
    uninstall)
        read -r -p "Type REMOVE to uninstall the TeperIP agent: " confirm
        [[ "$confirm" == "REMOVE" ]] || { echo "Cancelled."; exit 0; }

        port=""
        masters=""
        if [[ -r "$CONF_DIR/config.json" ]] && command -v jq >/dev/null 2>&1; then
            port="$(jq -r '.listen // empty' "$CONF_DIR/config.json" | sed 's/^.*://')"
            masters="$(jq -r '(.master_ips // []) | join(" ")' "$CONF_DIR/config.json")"
        fi

        systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
        nft delete table inet teperip >/dev/null 2>&1 || true

        if [[ -n "$port" ]]; then
            if command -v ufw >/dev/null 2>&1; then
                while read -r num; do
                    [[ -n "$num" ]] || continue
                    yes | ufw delete "$num" >/dev/null 2>&1 || true
                done < <(ufw status numbered 2>/dev/null | grep "teperip-agent" | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn)
            fi
        fi

        if [[ -n "$port" ]] && command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
            for ip in $masters; do
                if [[ "$ip" == "any" ]]; then
                    firewall-cmd --permanent --remove-port="$port/tcp" >/dev/null 2>&1 || true
                else
                    family="ipv4"
                    [[ "$ip" == *:* ]] && family="ipv6"

                    firewall-cmd --permanent --remove-rich-rule="rule family=\"$family\" source address=\"$ip\" port port=\"$port\" protocol=\"tcp\" accept" >/dev/null 2>&1 || true
                fi
            done

            firewall-cmd --reload >/dev/null 2>&1 || true
        fi

        rm -f "/etc/systemd/system/$SERVICE" /usr/local/bin/teperip-agent
        systemctl daemon-reload
        rm -rf "$INSTALL_DIR" "$CONF_DIR"

        echo "TeperIP agent removed."
        ;;
    *)
        echo "Usage: teperip-agent {status|logs|list|unblock-all|restart|uninstall}"
        exit 1
        ;;
esac
EOF_CLI

    chmod 755 "$CLI_FILE"
}

start_service() {
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "TeperIP agent is active."
    else
        warn "Agent failed to start. Log: journalctl -u $SERVICE_NAME -n 50 --no-pager"
        return 1
    fi
}

do_uninstall() {
    require_root

    if [[ -x "$CLI_FILE" ]]; then
        exec "$CLI_FILE" uninstall
    fi

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    nft delete table inet teperip >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$CLI_FILE"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR" "$CONF_DIR"

    ok "TeperIP agent removed."
}

do_install() {
    require_root

    ensure_dependencies
    load_existing_config
    validate_inputs

    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"

    write_config

    local built=0

    if ((TRY_PREBUILT)) || low_memory; then
        if low_memory && ((! TRY_PREBUILT)); then
            warn "Low memory detected (<900MB RAM, no swap); trying a prebuilt binary first."
        fi

        if try_prebuilt; then
            built=1
        fi
    fi

    if ((! built)); then
        write_go_source
        build_binary
    fi

    configure_firewall
    create_systemd_service
    create_cli
    start_service

    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}TeperIP agent v$AGENT_VERSION installed.${NC}"
    echo "Listening:   :$PORT (HTTPS, self-signed certificate)"
    echo "Master IPs:  $MASTER_IPS"
    echo "Manage:      teperip-agent {status|logs|list|unblock-all|restart|uninstall}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

main() {
    parse_args "$@"

    case "$ACTION" in
        uninstall) do_uninstall ;;
        *)         do_install ;;
    esac
}

main "$@"
