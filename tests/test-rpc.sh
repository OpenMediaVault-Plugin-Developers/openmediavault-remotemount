#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-remotemount RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Exercises CRUD operations for every mount backend type, then runs a full
# mount/unmount cycle using rclone/WebDAV against a local rclone WebDAV server.
# No remote server or network access required.
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
declare -a FAILED_TESTS=()

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() {
    echo -e "  ${GREEN}PASS${NC}  $1" >&2
    ((PASS++)) || true
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
SERVE_PID=""
SRC_DIR=""

LIST_PARAMS='{"start":0,"limit":null,"sortfield":null,"sortdir":null}'
OMV_NEW_UUID=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")

WEBDAV_PORT=19998
MNT1="/srv/remotemount/rmtest-webdav1"
MNT2="/srv/remotemount/rmtest-webdav2"

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit
# ---------------------------------------------------------------------------
cleanup() {
    section "Cleanup"

    # Stop local WebDAV server
    if [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
        info "Stopping local WebDAV server (PID $SERVE_PID)"
        kill "$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
    fi

    # Unmount and delete integration-test mounts
    for uuid in "$MOUNT1_UUID" "$MOUNT2_UUID"; do
        [ -z "$uuid" ] && continue
        info "Stopping mount $uuid"
        rpc "RemoteMount" "mount" "{\"uuid\":\"$uuid\",\"action\":\"stop\"}" \
            &>/dev/null || true
        sleep 1
        info "Deleting mount $uuid from DB"
        rpc "RemoteMount" "delete" "{\"uuid\":\"$uuid\"}" &>/dev/null || true
    done

    # Remove mount point directories left behind by rclone
    for mnt in "$MNT1" "$MNT2"; do
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
# Summary
# ---------------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS + FAIL))
echo >&2
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} (${TOTAL} total)" >&2
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo -e "\n  ${RED}Failed tests:${NC}" >&2
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "    ${RED}✗${NC} $t" >&2
    done
fi
echo >&2

[ $FAIL -eq 0 ] && exit 0 || exit 1
