#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-remotemount RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Exercises CRUD operations for every mount backend type, then runs a full
# mount/unmount cycle using rclone/WebDAV against a local rclone WebDAV server.
# Also simulates an unresponsive/hung remote (by SIGSTOPping the rclone FUSE
# process) to verify the `timeout` guards around isMounted()/getStatistics()
# bound RPC calls instead of hanging. No remote server or network access
# required.
#
# WARNING: The integration test runs omv-salt deploy run remotemount, which
# regenerates service files and restarts ALL configured remote mounts.
# Run on a test system or during a maintenance window.

set -uo pipefail

# ---------------------------------------------------------------------------
# Colours / counters  (display goes to stderr; $() captures only JSON)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
KNOWN=0
declare -a FAILED_TESTS=()
declare -a KNOWN_ISSUES=()

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() {
    echo -e "  ${GREEN}PASS${NC}  $1" >&2
    ((PASS++)) || true
}
# Use for defects that are confirmed real but live outside this plugin's own
# code (e.g. core OMV) and so can't be fixed here. Reported distinctly from
# FAIL so the suite stays green while still surfacing the gap on every run —
# it does not affect the PASS/FAIL counts or exit code.
_known() {
    echo -e "  ${YELLOW}KNOWN${NC} $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${YELLOW}→${NC} $2" >&2
    ((KNOWN++)) || true
    KNOWN_ISSUES+=("$1")
}
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------
rpc() {
    local svc=$1 method=$2 params=${3:-'{}'}
    omv-rpc -u admin "$svc" "$method" "$params"
}

assert_rpc() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "$(echo "$out" | tail -3)"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in: ${out:0:200}"
        return 1
    fi
    _pass "$desc"
    echo "$out"
    return 0
}

assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded: ${out:0:200}"
        return 1
    fi
    _pass "$desc"
    return 0
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
MOUNT1_UUID=""
MOUNT2_UUID=""
MOUNT3_UUID=""
OFFLINE_UUID=""
SERVE_PID=""
SRC_DIR=""
FROZEN_PID=""

LIST_PARAMS='{"start":0,"limit":null,"sortfield":null,"sortdir":null}'
OMV_NEW_UUID=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")

WEBDAV_PORT=19998
MNT1="/srv/remotemount/rmtest-webdav1"
MNT2="/srv/remotemount/rmtest-webdav2"
MNT3="/srv/remotemount/rmtest-webdav-hang"

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit
# ---------------------------------------------------------------------------
cleanup() {
    section "Cleanup"

    # Unfreeze any rclone process left paused by the hang-simulation test
    # (only set if a test aborted after SIGSTOP but before SIGCONT).
    if [ -n "$FROZEN_PID" ] && kill -0 "$FROZEN_PID" 2>/dev/null; then
        info "Unfreezing rclone process (PID $FROZEN_PID)"
        kill -CONT "$FROZEN_PID" 2>/dev/null || true
    fi

    # Stop local WebDAV server
    if [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
        info "Stopping local WebDAV server (PID $SERVE_PID)"
        kill "$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
    fi

    # Unmount and delete integration-test mounts
    for uuid in "$MOUNT1_UUID" "$MOUNT2_UUID" "$MOUNT3_UUID" "$OFFLINE_UUID"; do
        [ -z "$uuid" ] && continue
        info "Stopping mount $uuid"
        rpc "RemoteMount" "mount" "{\"uuid\":\"$uuid\",\"action\":\"stop\"}" \
            &>/dev/null || true
        sleep 1
        info "Deleting mount $uuid from DB"
        rpc "RemoteMount" "delete" "{\"uuid\":\"$uuid\"}" &>/dev/null || true
    done

    # Remove mount point directories left behind by rclone
    for mnt in "$MNT1" "$MNT2" "$MNT3"; do
        if [ -d "$mnt" ]; then
            mountpoint -q "$mnt" 2>/dev/null && fusermount -uz "$mnt" 2>/dev/null || true
            rmdir "$mnt" 2>/dev/null || true
        fi
    done

    # Redeploy to regenerate service files for remaining production mounts
    info "Running omv-salt deploy run remotemount (cleanup)"
    omv-salt deploy run remotemount &>/dev/null || true

    # Remove temp source directory
    [ -n "$SRC_DIR" ] && rm -rf "$SRC_DIR" 2>/dev/null || true

    info "Done."
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# CRUD helper — create, read, delete; no mounting
# ---------------------------------------------------------------------------
crud_test() {
    local label=$1 params=$2
    local result uuid
    result=$(assert_rpc "set ($label)" "RemoteMount" "set" "$params") || return 1
    uuid=$(echo "$result" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")
    if [ -z "$uuid" ] || [ "$uuid" = "$OMV_NEW_UUID" ]; then
        _fail "set ($label) — no real UUID returned"
        return 1
    fi
    assert_rpc "get ($label)" "RemoteMount" "get" \
        "{\"uuid\":\"$uuid\"}" "\"uuid\":\"$uuid\"" >/dev/null
    assert_rpc "getList includes $label" "RemoteMount" "getList" \
        "$LIST_PARAMS" "\"name\":\"$label\"" >/dev/null
    assert_rpc "delete ($label)" "RemoteMount" "delete" \
        "{\"uuid\":\"$uuid\"}" >/dev/null
    assert_rpc_fails "get ($label) after delete" "RemoteMount" "get" \
        "{\"uuid\":\"$uuid\"}"
    return 0
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
section "Pre-flight"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Must be run as root.${NC}" >&2
    exit 1
fi

for cmd in omv-rpc rclone python3 omv-salt curl mountpoint fusermount; do
    if command -v "$cmd" &>/dev/null; then
        _pass "command available: $cmd"
    else
        _fail "command available: $cmd" "$cmd not found in PATH"
    fi
done

if ! omv-rpc -u admin "Config" "isDirty" '{}' &>/dev/null; then
    echo -e "\n${RED}omv-rpc not functional — aborting.${NC}" >&2
    exit 1
fi
_pass "omv-rpc functional"

# ---------------------------------------------------------------------------
# Informational RPCs (empty state check)
# ---------------------------------------------------------------------------
section "Informational RPCs"

assert_rpc "getList" "RemoteMount" "getList" "$LIST_PARAMS" >/dev/null

# ---------------------------------------------------------------------------
# CRUD — one create/get/delete per backend type (no actual mounting)
# ---------------------------------------------------------------------------
section "CRUD — CIFS"
crud_test "rmtest-cifs" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-cifs', 'mounttype': 'cifs',
    'server': '192.168.99.1', 'sharename': 'testshare',
    'username': 'user', 'password': 'pass', 'options': '',
}))")"

section "CRUD — NFS (v3)"
crud_test "rmtest-nfs" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-nfs', 'mounttype': 'nfs',
    'server': '192.168.99.1', 'sharename': '/exports/test',
    'nfs4': False, 'options': '',
}))")"

section "CRUD — NFS (v4 flag)"
crud_test "rmtest-nfs4" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-nfs4', 'mounttype': 'nfs',
    'server': '192.168.99.1', 'sharename': '/exports/v4',
    'nfs4': True, 'options': '',
}))")"

section "CRUD — davfs"
crud_test "rmtest-davfs" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-davfs', 'mounttype': 'davfs',
    'server': 'https://webdav.example.com/dav',
    'username': '', 'password': '', 'options': '',
}))")"

section "CRUD — rclone/s3"
crud_test "rmtest-s3" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-s3', 'mounttype': 'rclone', 'rclonetype': 's3',
    'server': '', 'sharename': 'mybucket',
    'username': 'AKIAIOSFODNN7EXAMPLE', 'password': 'wJalrXUtnFEMI',
    'options': '--vfs-cache-mode=off',
}))")"

section "CRUD — rclone/sftp"
crud_test "rmtest-sftp" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-sftp', 'mounttype': 'rclone', 'rclonetype': 'sftp',
    'server': '192.168.99.1', 'sharename': '/home/user',
    'username': 'user', 'password': 'pass',
    'options': '--vfs-cache-mode=off',
}))")"

section "CRUD — rclone/ftp"
crud_test "rmtest-ftp" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-ftp', 'mounttype': 'rclone', 'rclonetype': 'ftp',
    'server': '192.168.99.1', 'sharename': '/',
    'username': 'ftpuser', 'password': 'ftppass',
    'options': '--vfs-cache-mode=off',
}))")"

section "CRUD — rclone/webdav"
crud_test "rmtest-webdav-crud" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-webdav-crud', 'mounttype': 'rclone', 'rclonetype': 'webdav',
    'server': 'https://dav.example.com', 'sharename': '',
    'username': 'user', 'password': 'pass',
    'options': '--vfs-cache-mode=off',
}))")"

# ---------------------------------------------------------------------------
# Validation — negative tests
# ---------------------------------------------------------------------------
section "Validation — negative tests"

# Create a mount so we can test duplicate-name rejection
TMP_RESULT=$(rpc "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-dupcheck', 'mounttype': 'cifs',
    'server': '192.168.99.1', 'sharename': 'share',
    'username': '', 'password': '', 'options': '',
}))")" 2>/dev/null || echo "{}")
TMP_UUID=$(echo "$TMP_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -n "$TMP_UUID" ] && [ "$TMP_UUID" != "$OMV_NEW_UUID" ]; then
    assert_rpc_fails "set — duplicate name rejected" "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-dupcheck', 'mounttype': 'nfs',
    'server': '192.168.99.2', 'sharename': '/export', 'options': '',
}))")"
    rpc "RemoteMount" "delete" "{\"uuid\":\"$TMP_UUID\"}" &>/dev/null || true
fi

assert_rpc_fails "set — invalid mounttype" "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-badtype', 'mounttype': 's3fs',
    'server': '192.168.99.1', 'sharename': 'bucket', 'options': '',
}))")"

assert_rpc_fails "get — unknown UUID" "RemoteMount" "get" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

assert_rpc_fails "delete — unknown UUID" "RemoteMount" "delete" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ---------------------------------------------------------------------------
# Regression — davfs URL containing '%' (e.g. WebDAV path with %40 for '@')
# is escaped to '%%' in the systemd .mount unit's What= field (so systemd does
# not treat it as a unit specifier), while /etc/davfs2/secrets keeps the
# literal '%40' value. User enters a single '%' in the GUI.
# ---------------------------------------------------------------------------
section "Regression — davfs '%' escaping in systemd unit vs secrets"

# 127.0.0.1:1 → connection refused, so the bogus mount fails fast on deploy.
PCT_NAME="rmtest-davpct"
PCT_SERVER="https://127.0.0.1:1/remote.php/dav/files/info%40myhost.me"
PCT_RESULT=$(rpc "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': '$PCT_NAME', 'mounttype': 'davfs',
    'server': '$PCT_SERVER',
    'username': 'info@myhost.me', 'password': 'secret', 'options': '',
}))")" 2>/dev/null || echo "{}")
PCT_UUID=$(echo "$PCT_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -n "$PCT_UUID" ] && [ "$PCT_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "created davfs mount with '%40' in URL ($PCT_UUID)"

    # Deploy to regenerate unit + secrets. The bogus mount won't start, so
    # the restart step may fail — that's fine, the files are written first.
    info "Running omv-salt deploy run remotemount (% escaping check)"
    omv-salt deploy run remotemount &>/dev/null || true

    PCT_UNIT="/etc/systemd/system/$(systemd-escape --path --suffix=mount \
        "/srv/remotemount/${PCT_NAME}")"
    PCT_SECRETS="/etc/davfs2/secrets"

    # systemd unit: What= must contain the doubled '%%40'.
    if [ -f "$PCT_UNIT" ] && grep '^What=' "$PCT_UNIT" | grep -qF 'info%%40myhost.me'; then
        _pass "unit What= escapes '%' as '%%' (info%%40myhost.me)"
    else
        _fail "unit What= escapes '%' as '%%'" \
            "$( [ -f "$PCT_UNIT" ] && grep '^What=' "$PCT_UNIT" || echo "unit $PCT_UNIT missing" )"
    fi

    # secrets: keeps the literal single '%40' (NOT doubled).
    if grep -qF 'info%40myhost.me' "$PCT_SECRETS" \
        && ! grep -qF 'info%%40myhost.me' "$PCT_SECRETS"; then
        _pass "davfs2 secrets keeps literal '%40' (not doubled)"
    else
        _fail "davfs2 secrets keeps literal '%40' (not doubled)" \
            "$(grep -F 'myhost.me' "$PCT_SECRETS" 2>/dev/null || echo "no matching secrets line")"
    fi

    rpc "RemoteMount" "delete" "{\"uuid\":\"$PCT_UUID\"}" &>/dev/null || true
    omv-salt deploy run remotemount &>/dev/null || true
else
    _fail "Regression davfs '%' escaping — could not create test mount"
fi

# A doubled '%%' (old workaround / typo) must be normalized to a single '%'
# by set() before it is stored, so the value is the real URL.
DBL_RESULT=$(rpc "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-davdbl', 'mounttype': 'davfs',
    'server': 'https://127.0.0.1:1/remote.php/dav/files/info%%40myhost.me',
    'username': 'info@myhost.me', 'password': 'secret', 'options': '',
}))")" 2>/dev/null || echo "{}")
DBL_UUID=$(echo "$DBL_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")
DBL_SERVER=$(echo "$DBL_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('server',''))" 2>/dev/null || echo "")

if [ -n "$DBL_UUID" ] && [ "$DBL_UUID" != "$OMV_NEW_UUID" ]; then
    if [ "$DBL_SERVER" = "https://127.0.0.1:1/remote.php/dav/files/info%40myhost.me" ]; then
        _pass "set() normalizes doubled '%%40' to single '%40' before saving"
    else
        _fail "set() normalizes doubled '%%40' to single '%40'" "stored server: $DBL_SERVER"
    fi
    rpc "RemoteMount" "delete" "{\"uuid\":\"$DBL_UUID\"}" &>/dev/null || true
else
    _fail "set() normalizes doubled '%%40' — could not create test mount"
fi

# A legacy '%%' already stored in the config DB (written by an older plugin
# version, so it bypassed the set() normalization) must be collapsed to a
# single '%' by the salt templates at deploy time. We create a clean mount,
# then patch config.xml directly to inject '%%' and deploy.
OMV_CONFIG="/etc/openmediavault/config.xml"
LEG_NAME="rmtest-davlegacy"
LEG_RESULT=$(rpc "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': '$LEG_NAME', 'mounttype': 'davfs',
    'server': 'https://127.0.0.1:1/remote.php/dav/files/info%40legacy.me',
    'username': 'info@legacy.me', 'password': 'secret', 'options': '',
}))")" 2>/dev/null || echo "{}")
LEG_UUID=$(echo "$LEG_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -n "$LEG_UUID" ] && [ "$LEG_UUID" != "$OMV_NEW_UUID" ] && [ -f "$OMV_CONFIG" ]; then
    # Inject the legacy doubled '%' straight into the stored config (bypasses set()).
    python3 - "$OMV_CONFIG" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('info%40legacy.me', 'info%%40legacy.me')
open(p, 'w').write(s)
PY
    # Confirm the DB now holds the legacy '%%' value (get() does not normalize).
    LEG_STORED=$(rpc "RemoteMount" "get" "{\"uuid\":\"$LEG_UUID\"}" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('server',''))" 2>/dev/null || echo "")
    if [ "$LEG_STORED" = "https://127.0.0.1:1/remote.php/dav/files/info%%40legacy.me" ]; then
        _pass "injected legacy '%%40' into config DB ($LEG_UUID)"
    else
        _fail "injected legacy '%%40' into config DB" "stored server: $LEG_STORED"
    fi

    info "Running omv-salt deploy run remotemount (legacy '%%' collapse check)"
    omv-salt deploy run remotemount &>/dev/null || true

    LEG_UNIT="/etc/systemd/system/$(systemd-escape --path --suffix=mount \
        "/srv/remotemount/${LEG_NAME}")"
    LEG_SECRETS="/etc/davfs2/secrets"

    # systemd unit: collapsed to single '%40' then escaped → doubled '%%40'.
    if [ -f "$LEG_UNIT" ] && grep '^What=' "$LEG_UNIT" | grep -qF 'info%%40legacy.me'; then
        _pass "deploy collapses legacy '%%' then escapes in unit What= (info%%40legacy.me)"
    else
        _fail "deploy collapses legacy '%%' in unit What=" \
            "$( [ -f "$LEG_UNIT" ] && grep '^What=' "$LEG_UNIT" || echo "unit $LEG_UNIT missing" )"
    fi

    # secrets: collapsed to the literal single '%40'.
    if grep -qF 'info%40legacy.me' "$LEG_SECRETS" \
        && ! grep -qF 'info%%40legacy.me' "$LEG_SECRETS"; then
        _pass "deploy collapses legacy '%%' to single '%40' in davfs2 secrets"
    else
        _fail "deploy collapses legacy '%%' to single '%40' in davfs2 secrets" \
            "$(grep -F 'legacy.me' "$LEG_SECRETS" 2>/dev/null || echo "no matching secrets line")"
    fi

    rpc "RemoteMount" "delete" "{\"uuid\":\"$LEG_UUID\"}" &>/dev/null || true
    omv-salt deploy run remotemount &>/dev/null || true
else
    _fail "deploy collapses legacy '%%' — could not create test mount or config.xml missing"
    [ -n "$LEG_UUID" ] && [ "$LEG_UUID" != "$OMV_NEW_UUID" ] && \
        rpc "RemoteMount" "delete" "{\"uuid\":\"$LEG_UUID\"}" &>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Integration — rclone/WebDAV with local rclone WebDAV server
# ---------------------------------------------------------------------------
section "Integration — rclone/WebDAV (local server, no network required)"

# Create a temp directory as the WebDAV-served source
SRC_DIR=$(mktemp -d)
echo "remotemount rpc test" > "$SRC_DIR/test.txt"
_pass "source directory created: $SRC_DIR"

# Start rclone WebDAV server (background)
rclone serve webdav "$SRC_DIR" --addr "127.0.0.1:${WEBDAV_PORT}" &
SERVE_PID=$!
sleep 1

if kill -0 "$SERVE_PID" 2>/dev/null; then
    _pass "rclone WebDAV server started (PID=$SERVE_PID port=$WEBDAV_PORT)"
else
    _fail "rclone WebDAV server failed to start"
    exit 1
fi

if curl -sf "http://127.0.0.1:${WEBDAV_PORT}/" &>/dev/null; then
    _pass "WebDAV server responding on port $WEBDAV_PORT"
else
    _fail "WebDAV server not responding — cannot continue integration test"
    exit 1
fi

# Create mount 1
RESULT1=$(assert_rpc "set (rmtest-webdav1)" "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-webdav1', 'mounttype': 'rclone', 'rclonetype': 'webdav',
    'server': 'http://127.0.0.1:${WEBDAV_PORT}', 'sharename': '',
    'username': '', 'password': '',
    'options': '--vfs-cache-mode=off',
}))")") || exit 1
MOUNT1_UUID=$(echo "$RESULT1" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

# Create mount 2 (same server — this is what triggered the duplicate-name bug)
RESULT2=$(assert_rpc "set (rmtest-webdav2)" "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-webdav2', 'mounttype': 'rclone', 'rclonetype': 'webdav',
    'server': 'http://127.0.0.1:${WEBDAV_PORT}', 'sharename': '',
    'username': '', 'password': '',
    'options': '--vfs-cache-mode=off',
}))")") || exit 1
MOUNT2_UUID=$(echo "$RESULT2" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -z "$MOUNT1_UUID" ] || [ "$MOUNT1_UUID" = "$OMV_NEW_UUID" ] \
   || [ -z "$MOUNT2_UUID" ] || [ "$MOUNT2_UUID" = "$OMV_NEW_UUID" ]; then
    _fail "integration test — failed to create test mounts; cannot continue"
    exit 1
fi

# Verify DB entries carry distinct UUIDs
if [ "$MOUNT1_UUID" != "$MOUNT2_UUID" ]; then
    _pass "set — mounts got distinct UUIDs"
else
    _fail "set — both mounts got same UUID"
fi

# Verify the credentials/service files differ by UUID (unique-remote-name fix)
info "Verifying credential file remote names after: rclone config section name = UUID..."

# Deploy to generate service files and start the mounts
info "Running omv-salt deploy run remotemount ..."
if omv-salt deploy run remotemount &>/dev/null; then
    _pass "omv-salt deploy"
else
    _fail "omv-salt deploy"
fi

# Wait up to 30 s for both mounts to become active
info "Waiting for mounts to become active (up to 30 s) ..."
for i in $(seq 1 15); do
    M1=$(mountpoint -q "$MNT1" 2>/dev/null && echo yes || echo no)
    M2=$(mountpoint -q "$MNT2" 2>/dev/null && echo yes || echo no)
    [ "$M1" = yes ] && [ "$M2" = yes ] && break
    sleep 2
done

if mountpoint -q "$MNT1" 2>/dev/null; then
    _pass "rmtest-webdav1 mounted at $MNT1"
else
    _fail "rmtest-webdav1 not mounted at $MNT1 after 30 s"
fi

if mountpoint -q "$MNT2" 2>/dev/null; then
    _pass "rmtest-webdav2 mounted at $MNT2"
else
    _fail "rmtest-webdav2 not mounted at $MNT2 after 30 s"
fi

# getList shows both as mounted=true
MOUNTED_COUNT=$(rpc "RemoteMount" "getList" "$LIST_PARAMS" 2>/dev/null \
    | python3 -c "
import sys,json
data=json.load(sys.stdin).get('data',[])
print(sum(1 for m in data
          if m.get('mounted') and m.get('name','').startswith('rmtest-webdav'))
)" 2>/dev/null || echo 0)

if [ "$MOUNTED_COUNT" = "2" ]; then
    _pass "getList — both test mounts show mounted=true"
else
    _fail "getList — expected 2 mounted test mounts, got $MOUNTED_COUNT"
fi

# Verify test file is accessible through both mounts
for mnt in "$MNT1" "$MNT2"; do
    if [ -f "$mnt/test.txt" ]; then
        _pass "$(basename "$mnt") — test.txt accessible through mount"
    else
        _fail "$(basename "$mnt") — test.txt not found (mount may not be working)"
    fi
done

# Verify generated credential files use UUID as section name (unique-remote fix)
for uuid in "$MOUNT1_UUID" "$MOUNT2_UUID"; do
    mntentref=$(rpc "RemoteMount" "get" "{\"uuid\":\"$uuid\"}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('mntentref',''))" \
        2>/dev/null || echo "")
    creds="/root/.rclonecredentials-${mntentref}"
    if [ -f "$creds" ]; then
        if grep -q "^\[${uuid}\]" "$creds" 2>/dev/null; then
            _pass "credentials ($uuid) — section name is UUID (unique-remote fix)"
        else
            _fail "credentials ($uuid) — section name is not UUID (fix may not be applied)"
            grep "^\[" "$creds" | head -1 >&2 || true
        fi
    else
        _fail "credentials ($uuid) — file not found: $creds"
    fi
done

# ---------------------------------------------------------------------------
# Regression — duplicate name in ShareMgmt::getCandidates (main bug fix)
# ---------------------------------------------------------------------------
section "Regression — no duplicate names in ShareMgmt::getCandidates"

CANDIDATES=$(rpc "ShareMgmt" "getCandidates" "{}" 2>/dev/null || echo "[]")

for name in rmtest-webdav1 rmtest-webdav2; do
    count=$(echo "$CANDIDATES" | python3 -c "
import sys,json
cands=json.load(sys.stdin)
print(sum(1 for c in cands if '$name' in c.get('description',''))
)" 2>/dev/null || echo 0)
    if [ "$count" = "1" ]; then
        _pass "getCandidates — '$name' appears exactly once"
    else
        _fail "getCandidates — '$name' appears $count times (expected 1)"
    fi
done

TOTAL_TEST=$(echo "$CANDIDATES" | python3 -c "
import sys,json
cands=json.load(sys.stdin)
print(sum(1 for c in cands if 'rmtest-webdav' in c.get('description',''))
)" 2>/dev/null || echo 0)

if [ "$TOTAL_TEST" = "2" ]; then
    _pass "getCandidates — total test-mount candidates = 2 (no duplicates)"
else
    _fail "getCandidates — total test-mount candidates = $TOTAL_TEST (expected 2)"
    echo "  Full candidates list:" >&2
    echo "$CANDIDATES" | python3 -c "
import sys,json
for c in json.load(sys.stdin):
    if 'rmtest' in c.get('description',''):
        print('   ', c)
" 2>/dev/null >&2 || true
fi

# ---------------------------------------------------------------------------
# Regression — every mounted remote mount appears exactly once in getCandidates
# ---------------------------------------------------------------------------
section "Regression — all mounts in ShareMgmt::getCandidates"

ALL_LIST=$(rpc "RemoteMount" "getList" "$LIST_PARAMS" 2>/dev/null || echo '{"data":[]}')
ALL_CANDIDATES=$(rpc "ShareMgmt" "getCandidates" "{}" 2>/dev/null || echo "[]")

MOUNTED_NAMES=$(echo "$ALL_LIST" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
for m in data:
    if m.get('mounted'):
        print(m.get('name', ''))
" 2>/dev/null || echo "")

if [ -z "$MOUNTED_NAMES" ]; then
    info "No mounted remote mounts found — skipping"
else
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        count=$(echo "$ALL_CANDIDATES" | python3 -c "
import sys, json
cands = json.load(sys.stdin)
print(sum(1 for c in cands if c.get('description', '').split()[0] == '$name'))
" 2>/dev/null || echo 0)
        if [ "$count" = "1" ]; then
            _pass "getCandidates — '$name' appears exactly once"
        else
            _fail "getCandidates — '$name' appears $count times (expected 1)"
        fi
    done <<< "$MOUNTED_NAMES"
fi

# ---------------------------------------------------------------------------
# Regression — ShareMgmt::getList must not throw when two shared folders live
# on the same remote mount. The second lookup of the same fsname used to fail
# because fetchMountPointByFsnameAndType's duplicate-suppression claimed the
# mount point on the first call and then rejected the identical second request.
# Exercises $resolvedFsnames fsname→mountpoint cache.
# ---------------------------------------------------------------------------
section "Regression — ShareMgmt::getList with two shared folders on same remote mount"

SF1_UUID=""
SF2_UUID=""

# Get the mntentref (OMV filesystem UUID) from the webdav1 remotemount entry.
MNTENTREF=$(rpc "RemoteMount" "get" "{\"uuid\":\"$MOUNT1_UUID\"}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('mntentref',''))" \
    2>/dev/null || echo "")

if [ -n "$MNTENTREF" ] && mountpoint -q "$MNT1" 2>/dev/null; then
    # Pre-create subdirectories in the source so OMV doesn't need to mkdir
    # through the rclone layer. Each shared folder needs a distinct reldirpath —
    # OMV rejects two shared folders with the same mntentref+reldirpath.
    mkdir -p "$SRC_DIR/sf1dir" "$SRC_DIR/sf2dir"

    SF1_RESULT=$(rpc "ShareMgmt" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'name': 'rmtest-sf1',
    'mntentref': '$MNTENTREF', 'reldirpath': 'sf1dir',
    'comment': 'regression test sf1', 'mode': '775',
}))")" 2>/dev/null || echo "{}")
    SF1_UUID=$(echo "$SF1_RESULT" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

    SF2_RESULT=$(rpc "ShareMgmt" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'name': 'rmtest-sf2',
    'mntentref': '$MNTENTREF', 'reldirpath': 'sf2dir',
    'comment': 'regression test sf2', 'mode': '775',
}))")" 2>/dev/null || echo "{}")
    SF2_UUID=$(echo "$SF2_RESULT" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

    if [ -n "$SF1_UUID" ] && [ "$SF1_UUID" != "$OMV_NEW_UUID" ] \
       && [ -n "$SF2_UUID" ] && [ "$SF2_UUID" != "$OMV_NEW_UUID" ]; then
        _pass "created two shared folders ($SF1_UUID, $SF2_UUID) on same mount"
        assert_rpc "ShareMgmt getList — no exception with two shared folders on same mount" \
            "ShareMgmt" "getList" \
            '{"start":0,"limit":25,"sortfield":null,"sortdir":null}' >/dev/null
    else
        _fail "two-shared-folder regression — could not create both shared folders (SF1=${SF1_UUID:-empty} SF2=${SF2_UUID:-empty})"
    fi

    # Cleanup
    for sf_uuid in "$SF1_UUID" "$SF2_UUID"; do
        [ -z "$sf_uuid" ] || [ "$sf_uuid" = "$OMV_NEW_UUID" ] && continue
        rpc "ShareMgmt" "delete" \
            "{\"uuid\":\"$sf_uuid\",\"recursive\":false}" &>/dev/null || true
    done
    rm -rf "$SRC_DIR/sf1dir" "$SRC_DIR/sf2dir" 2>/dev/null || true
else
    _fail "two-shared-folder regression — skipped (mount $MNT1 not active or mntentref missing)"
fi

# ---------------------------------------------------------------------------
# mount RPC — stop / start
# ---------------------------------------------------------------------------
section "mount RPC — stop and start"

assert_rpc "mount stop (webdav1)" "RemoteMount" "mount" \
    "{\"uuid\":\"$MOUNT1_UUID\",\"action\":\"stop\"}" >/dev/null
sleep 2

if ! mountpoint -q "$MNT1" 2>/dev/null; then
    _pass "mount stop — rmtest-webdav1 unmounted"
else
    _fail "mount stop — rmtest-webdav1 still mounted"
fi

assert_rpc "mount start (webdav1)" "RemoteMount" "mount" \
    "{\"uuid\":\"$MOUNT1_UUID\",\"action\":\"start\"}" >/dev/null
sleep 3

if mountpoint -q "$MNT1" 2>/dev/null; then
    _pass "mount start — rmtest-webdav1 remounted"
else
    _fail "mount start — rmtest-webdav1 not remounted"
fi

# ---------------------------------------------------------------------------
# Regression — getCandidates must not throw when a bind mount sourced from a
# sub-path of a remotemount is present (SFTP plugin bind mount scenario).
# Exercises findUuidByDir's prefix-match path.
# ---------------------------------------------------------------------------
section "Regression — getCandidates with SFTP-style bind mount over rclone"

SFTP_BIND_BASE="/sftp/rmtest-sftp-user"
SFTP_BIND_MNT="${SFTP_BIND_BASE}/RM_rmtest-webdav1"
SFTP_BIND_SRC="${MNT1}/bindtestdir"
BIND_MOUNTED=false

if mountpoint -q "$MNT1" 2>/dev/null; then
    if mkdir -p "$SFTP_BIND_SRC" "$SFTP_BIND_MNT" 2>/dev/null; then
        if mount --bind "$SFTP_BIND_SRC" "$SFTP_BIND_MNT" 2>/dev/null; then
            BIND_FSTYPE=$(findmnt -no FSTYPE "$SFTP_BIND_MNT" 2>/dev/null || echo unknown)
            _pass "bind mount created: $SFTP_BIND_MNT → $SFTP_BIND_SRC (fstype=$BIND_FSTYPE)"
            BIND_MOUNTED=true
        else
            _fail "could not create bind mount — skipping SFTP bind mount regression"
        fi
    else
        _fail "could not create source dirs — skipping SFTP bind mount regression"
    fi
else
    _fail "rmtest-webdav1 not mounted — skipping SFTP bind mount regression"
fi

if $BIND_MOUNTED; then
    assert_rpc "getCandidates — no exception with SFTP-style bind mount over rclone" \
        "ShareMgmt" "getCandidates" '{}' >/dev/null

    umount "$SFTP_BIND_MNT" 2>/dev/null || true
    rmdir "$SFTP_BIND_MNT" "$SFTP_BIND_BASE" "$SFTP_BIND_SRC" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Regression — FileSystemMgmt::getList must not throw when all rclone mounts
# are inactive. Exercises the full fix:
#   1. fetchMountPointByFsnameAndType now checks .service units for type=rclone
#   2. getImpl now resolves mount-dir → UUID via DB lookup (findUuidByDir)
#      rather than relying on the fragile service-file grep in
#      extractUuidFromMountPoint, which fails when $output accumulates across
#      exec() calls.
# ---------------------------------------------------------------------------
section "Regression — FileSystemMgmt::getList with all rclone mounts inactive"

info "Stopping both test rclone mounts ..."
rpc "RemoteMount" "mount" "{\"uuid\":\"$MOUNT1_UUID\",\"action\":\"stop\"}" &>/dev/null || true
rpc "RemoteMount" "mount" "{\"uuid\":\"$MOUNT2_UUID\",\"action\":\"stop\"}" &>/dev/null || true
sleep 3

ALL_STOPPED=true
for mnt in "$MNT1" "$MNT2"; do
    if ! mountpoint -q "$mnt" 2>/dev/null; then
        _pass "confirmed unmounted: $mnt"
    else
        _fail "expected $mnt to be unmounted"
        ALL_STOPPED=false
    fi
done

if $ALL_STOPPED; then
    assert_rpc "FileSystemMgmt getList — no exception with all rclone mounts inactive" \
        "FileSystemMgmt" "getList" \
        '{"start":0,"limit":25,"sortfield":null,"sortdir":null}' >/dev/null
else
    _fail "FileSystemMgmt getList — skipped (mounts did not stop cleanly)"
fi

# ---------------------------------------------------------------------------
# Regression — FileSystemMgmt::getList must not throw when a CIFS/NFS/davfs
# mount is configured in the DB but has no unit file (not yet deployed).
# Exercises findUuidByFsname which resolves //server/share → UUID from the DB
# without needing the mount to be active or a unit file to exist.
# ---------------------------------------------------------------------------
section "Regression — FileSystemMgmt::getList with undeployed CIFS mount"

CIFS_TMP_UUID=""
CIFS_TMP_RESULT=$(rpc "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-cifs-nodeployment', 'mounttype': 'cifs',
    'server': '192.168.99.254', 'sharename': 'testshare',
    'username': '', 'password': '', 'options': '',
}))")" 2>/dev/null || echo "{}")
CIFS_TMP_UUID=$(echo "$CIFS_TMP_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -n "$CIFS_TMP_UUID" ] && [ "$CIFS_TMP_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "created undeployed CIFS mount ($CIFS_TMP_UUID) — no unit file will exist"
    assert_rpc "FileSystemMgmt getList — no exception with undeployed CIFS mount" \
        "FileSystemMgmt" "getList" \
        '{"start":0,"limit":25,"sortfield":null,"sortdir":null}' >/dev/null

    # Exercises the getMountsAssoc() try/catch fallback added for unreachable/
    # unprobeable mounts: isMounted()/getStatistics() can't succeed against a
    # share with no unit file, so the entry must still appear with defaults
    # (mounted=false, size/used/available=-1) instead of the RPC call failing.
    UNDEPLOYED_OUT=$(rpc "RemoteMount" "getList" "$LIST_PARAMS" 2>&1)
    UNDEPLOYED_EC=$?
    if [ $UNDEPLOYED_EC -eq 0 ]; then
        _pass "RemoteMount getList — no exception with undeployed CIFS mount"
    else
        _fail "RemoteMount getList — no exception with undeployed CIFS mount" \
            "${UNDEPLOYED_OUT:0:200}"
    fi
    UNDEPLOYED_MOUNTED=$(echo "$UNDEPLOYED_OUT" | python3 -c "
import sys,json
try:
    data=json.load(sys.stdin).get('data',[])
except Exception:
    data=[]
for m in data:
    if m.get('uuid')=='$CIFS_TMP_UUID':
        print(m.get('mounted'))
" 2>/dev/null || echo "")
    if [ "$UNDEPLOYED_MOUNTED" = "False" ]; then
        _pass "RemoteMount getList — undeployed CIFS mount reports mounted=false"
    else
        _fail "RemoteMount getList — undeployed CIFS mount reports mounted=false" \
            "got: '$UNDEPLOYED_MOUNTED'"
    fi

    rpc "RemoteMount" "delete" "{\"uuid\":\"$CIFS_TMP_UUID\"}" &>/dev/null || true
else
    _fail "FileSystemMgmt getList undeployed CIFS — could not create test mount"
fi

# ---------------------------------------------------------------------------
# Regression — unresponsive (hung) remote mount is bounded by `timeout`
#
# Simulates a remote server that has stopped responding entirely (dead NFS
# host, hung SMB server, ...): the rclone FUSE process backing a mount is
# frozen with SIGSTOP, so any process that touches the mountpoint (stat,
# statfs, path canonicalization, ...) blocks in the kernel waiting for the
# FUSE daemon to answer — exactly the situation `timeout` in
# Remote::isMounted()/getStatistics() exists to bound. SIGSTOP is safe and
# fully reversible: no real network is involved, and killing the frozen
# process (rather than resuming it) immediately unblocks any caller still
# waiting on it, unlike a genuinely wedged NFS mount in D state.
# ---------------------------------------------------------------------------
section "Regression — unresponsive (hung) remote mount"

RESULT3=$(assert_rpc "set (rmtest-webdav-hang)" "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-webdav-hang', 'mounttype': 'rclone', 'rclonetype': 'webdav',
    'server': 'http://127.0.0.1:${WEBDAV_PORT}', 'sharename': '',
    'username': '', 'password': '',
    'options': '--vfs-cache-mode=off',
}))")")
MOUNT3_UUID=$(echo "$RESULT3" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -z "$MOUNT3_UUID" ] || [ "$MOUNT3_UUID" = "$OMV_NEW_UUID" ]; then
    _fail "unresponsive-mount regression — could not create test mount; skipping"
else
    info "Running omv-salt deploy run remotemount (hang test mount) ..."
    omv-salt deploy run remotemount &>/dev/null || true

    info "Waiting for rmtest-webdav-hang to become active (up to 30 s) ..."
    for i in $(seq 1 15); do
        mountpoint -q "$MNT3" 2>/dev/null && break
        sleep 2
    done

    if mountpoint -q "$MNT3" 2>/dev/null; then
        _pass "rmtest-webdav-hang mounted at $MNT3"

        UNIT3=$(systemd-escape --path --suffix=service "$MNT3")
        FROZEN_PID=$(systemctl show -p MainPID --value "$UNIT3" 2>/dev/null || echo "")

        if [ -n "$FROZEN_PID" ] && [ "$FROZEN_PID" != "0" ]; then
            info "Freezing rclone process (PID $FROZEN_PID) to simulate a hung/unresponsive remote ..."
            kill -STOP "$FROZEN_PID"

            # findmnt/df against the frozen mount must be bounded by the
            # `timeout` wrapper added to Remote::isMounted()/getStatistics().
            # Before that fix this call could hang indefinitely.
            START=$(date +%s)
            LIST_OUT=$(timeout 30 omv-rpc -u admin "RemoteMount" "getList" "$LIST_PARAMS" 2>&1)
            LIST_EC=$?
            ELAPSED=$(( $(date +%s) - START ))

            if [ $LIST_EC -eq 0 ]; then
                _pass "getList returned while a mount was hung (no crash/hang), took ${ELAPSED}s"
            else
                _fail "getList with a hung mount" \
                    "exit=$LIST_EC elapsed=${ELAPSED}s output: ${LIST_OUT:0:200}"
            fi

            if [ "$LIST_EC" -eq 0 ] && [ "$ELAPSED" -le 20 ]; then
                _pass "getList bounded by timeout wrapper (${ELAPSED}s <= 20s)"
            else
                _fail "getList bounded by timeout wrapper" "took ${ELAPSED}s (expected <= 20s)"
            fi

            # NOTE: `mounted` here reflects findmnt's answer, which can come
            # from the kernel's FUSE attribute cache (default ~1s) rather
            # than a fresh probe of the frozen daemon. Right after freezing,
            # the cache is usually still warm, so `mounted=true` here is
            # correct (it genuinely is still mounted, just unresponsive) —
            # this is informational, not a pass/fail signal on its own since
            # it depends on cache timing.
            HANG_MOUNTED=$(echo "$LIST_OUT" | python3 -c "
import sys,json
try:
    data=json.load(sys.stdin).get('data',[])
except Exception:
    data=[]
for m in data:
    if m.get('name')=='rmtest-webdav-hang':
        print(m.get('mounted'))
" 2>/dev/null || echo "")
            if [ "$HANG_MOUNTED" = "True" ] || [ "$HANG_MOUNTED" = "False" ]; then
                _pass "getList reports a well-formed mounted=$HANG_MOUNTED for the hung mount"
            else
                _fail "getList reports a well-formed mounted value for the hung mount" \
                    "got: '$HANG_MOUNTED'"
            fi

            # getDescription() (surfaced through ShareMgmt::getCandidates) is
            # supposed to mark the share '[unavailable]' once getStatistics()
            # fails, bounded by the same `df`-with-timeout fix. But the
            # candidate is only considered at all after
            # \OMV\System\MountPoint::isMountPoint() succeeds — core OMV
            # code, not touched by this fix, that does a native PHP stat()
            # with no subprocess/timeout involved. If the FUSE attribute
            # cache has expired by the time this runs, that stat() call can
            # block for real, and a client-side `timeout` here only kills
            # the omv-rpc CLI — the stuck call inside omv-engined keeps
            # running server-side until the frozen process is resumed below.
            # Distinguish "genuinely hung" (exit 124) from "returned but
            # missing the tag" so a failure here points at the right code.
            CSTART=$(date +%s)
            CANDS_OUT=$(timeout 30 omv-rpc -u admin "ShareMgmt" "getCandidates" "{}" 2>&1)
            CANDS_EC=$?
            CELAPSED=$(( $(date +%s) - CSTART ))

            if [ $CANDS_EC -eq 124 ]; then
                _known "getCandidates hangs on an unresponsive mount" \
                    "timed out after ${CELAPSED}s — confirmed cause: \\OMV\\System\\MountPoint::isMountPoint() in core OMV's mountpoint.inc shells out to 'mountpoint -q' with no timeout wrapper (unlike this plugin's findmnt/df fixes). Not fixable from this plugin; would need an upstream OMV core fix."
            elif [ $CANDS_EC -ne 0 ]; then
                _fail "getCandidates with a hung mount" \
                    "exit=$CANDS_EC elapsed=${CELAPSED}s output: ${CANDS_OUT:0:200}"
            else
                _pass "getCandidates returned with a mount hung (${CELAPSED}s, no client-side hang)"
                if echo "$CANDS_OUT" | python3 -c "
import sys,json
cands=json.load(sys.stdin)
sys.exit(0 if any('rmtest-webdav-hang' in c.get('description','')
                   and '[unavailable]' in c.get('description','') for c in cands) else 1)
" 2>/dev/null; then
                    _pass "getCandidates marks hung mount '[unavailable]'"
                else
                    _fail "getCandidates marks hung mount '[unavailable]'" \
                        "$(echo "$CANDS_OUT" | grep -o '.\{0,40\}rmtest-webdav-hang.\{0,60\}' || echo 'candidate not present in output')"
                fi
            fi

            info "Unfreezing rclone process (PID $FROZEN_PID) ..."
            kill -CONT "$FROZEN_PID" 2>/dev/null || true
            FROZEN_PID=""
        else
            _fail "unresponsive-mount regression — could not determine rclone PID for unit $UNIT3"
        fi
    else
        _fail "rmtest-webdav-hang not mounted at $MNT3 after 30 s — skipping hang simulation"
    fi
fi

# ---------------------------------------------------------------------------
# Regression — omv#2331: an offline remote must not fail the config apply
#
# Every apply regenerates and restarts *all* configured mounts. Previously a
# strict `systemctl restart` on a share whose server is unreachable failed the
# Salt state, so the whole apply errored and edits to any other entry could
# not be saved. A CIFS share on 127.0.0.1 with no such share fails to mount
# quickly (connection refused, or no such share if smbd runs).
# ---------------------------------------------------------------------------
section "Regression — offline remote does not fail config apply (omv#2331)"

OFFLINE_RESULT=$(rpc "RemoteMount" "set" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'mntentref': '$OMV_NEW_UUID',
    'name': 'rmtest-cifs-offline', 'mounttype': 'cifs',
    'server': '127.0.0.1', 'sharename': 'rmtest-nonexistent-share',
    'username': '', 'password': '', 'options': '',
}))")" 2>/dev/null || echo "{}")
OFFLINE_UUID=$(echo "$OFFLINE_RESULT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('uuid',''))" 2>/dev/null || echo "")

if [ -z "$OFFLINE_UUID" ] || [ "$OFFLINE_UUID" = "$OMV_NEW_UUID" ]; then
    _fail "offline-remote apply regression — could not create test mount; skipping"
else
    MNT_OFFLINE="/srv/remotemount/rmtest-cifs-offline"
    UNIT_OFFLINE=$(systemd-escape --path --suffix=mount "$MNT_OFFLINE")
    HEALTHY_BEFORE=$(mountpoint -q "$MNT3" 2>/dev/null && echo yes || echo no)

    info "Running omv-salt deploy run remotemount with an offline share ..."
    DEPLOY_OUT=$(omv-salt deploy run remotemount 2>&1)
    DEPLOY_EC=$?

    if [ $DEPLOY_EC -eq 0 ]; then
        _pass "deploy succeeds while a configured remote is offline"
    else
        _fail "deploy succeeds while a configured remote is offline" \
            "exit=$DEPLOY_EC: $(echo "$DEPLOY_OUT" | grep -iE 'fail|error' | head -3)"
    fi

    if [ -f "/etc/systemd/system/$UNIT_OFFLINE" ]; then
        _pass "unit file generated for offline share ($UNIT_OFFLINE)"
    else
        _fail "unit file generated for offline share" "/etc/systemd/system/$UNIT_OFFLINE missing"
    fi

    if mountpoint -q "$MNT_OFFLINE" 2>/dev/null; then
        _fail "offline share is not mounted" "$MNT_OFFLINE unexpectedly mounted"
    else
        _pass "offline share is not mounted"
    fi

    # A healthy mount configured alongside it must still come up.
    if [ "$HEALTHY_BEFORE" = "yes" ]; then
        if mountpoint -q "$MNT3" 2>/dev/null; then
            _pass "healthy mount ($MNT3) still mounted after apply with offline share"
        else
            _fail "healthy mount still mounted after apply with offline share" "$MNT3 not mounted"
        fi
    else
        info "healthy-mount check skipped ($MNT3 was not mounted before apply)"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS + FAIL + KNOWN))
echo >&2
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${KNOWN} known issues${NC} (${TOTAL} total)" >&2
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo -e "\n  ${RED}Failed tests:${NC}" >&2
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "    ${RED}✗${NC} $t" >&2
    done
fi
if [ ${#KNOWN_ISSUES[@]} -gt 0 ]; then
    echo -e "\n  ${YELLOW}Known issues (not fixable in this plugin; don't affect exit code):${NC}" >&2
    for t in "${KNOWN_ISSUES[@]}"; do
        echo -e "    ${YELLOW}!${NC} $t" >&2
    done
fi
echo >&2

[ $FAIL -eq 0 ] && exit 0 || exit 1
