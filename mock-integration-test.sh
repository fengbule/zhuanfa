#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fb.sh"
TEST_ROOT="$(pwd)/.mock-fb"
STUB_DIR="$TEST_ROOT/stubs"
CONF_DIR="$TEST_ROOT/etc/fb"
BACKUP_DIR="$CONF_DIR/backups"
SYSTEMD_DIR="$TEST_ROOT/systemd"
SELF_TARGET="$TEST_ROOT/bin/fb"
LOG_DIR="$TEST_ROOT/log"
STATE_DIR="$TEST_ROOT/state"
TMP_DIR="$TEST_ROOT/tmp"
SYSCTL_FILE="$TEST_ROOT/sysctl/99-fb.conf"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

pass() {
  echo "[PASS] $*"
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$expected" == "$actual" ]] || fail "$label: expected '$expected', got '$actual'"
  pass "$label"
}

assert_file_contains() {
  local file="$1" pattern="$2" label="$3"
  grep -Fq "$pattern" "$file" || fail "$label: pattern '$pattern' not found in $file"
  pass "$label"
}

assert_file_exists() {
  local file="$1" label="$2"
  [[ -f "$file" ]] || fail "$label: missing $file"
  pass "$label"
}

assert_file_missing() {
  local file="$1" label="$2"
  [[ ! -e "$file" ]] || fail "$label: unexpected $file"
  pass "$label"
}

assert_rule_count() {
  local expected="$1" label="$2"
  local count
  if [[ -f "$CONF_DIR/rules.db" ]]; then
    count="$(grep -cve '^\s*$' "$CONF_DIR/rules.db")"
  else
    count="0"
  fi
  assert_eq "$expected" "$count" "$label"
}

make_stub() {
  local name="$1"
  cat > "$STUB_DIR/$name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$STUB_DIR/$name"
}

reset_env() {
  rm -rf "$TEST_ROOT"
  mkdir -p "$STUB_DIR" "$BACKUP_DIR" "$SYSTEMD_DIR" "$(dirname "$SELF_TARGET")" "$LOG_DIR" "$STATE_DIR" "$TMP_DIR" "$(dirname "$SYSCTL_FILE")"

  cat > "$STUB_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "is-active" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "$STUB_DIR/systemctl"

  cat > "$STUB_DIR/iptables" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$STUB_DIR/iptables"

  cat > "$STUB_DIR/ss" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process"
EOF
  chmod +x "$STUB_DIR/ss"

  cat > "$STUB_DIR/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$STUB_DIR/getent"

  cat > "$STUB_DIR/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "mock journal"
EOF
  chmod +x "$STUB_DIR/journalctl"

  cat > "$STUB_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$out" ]] || exit 1
cp "$FB_TEST_DOWNLOAD_SOURCE" "$out"
EOF
  chmod +x "$STUB_DIR/curl"

  cat > "$STUB_DIR/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
"$@"
EOF
  chmod +x "$STUB_DIR/timeout"

  make_stub sysctl
  make_stub socat
  make_stub gost
  make_stub realm
}

run_fb() {
  FB_TEST_MODE=1 \
  FB_CONF_DIR="$CONF_DIR" \
  FB_BACKUP_DIR="$BACKUP_DIR" \
  FB_LOG_DIR="$LOG_DIR" \
  FB_STATE_DIR="$STATE_DIR" \
  FB_TMP_DIR="$TMP_DIR" \
  FB_SELF_TARGET="$SELF_TARGET" \
  FB_SYSTEMD_DIR="$SYSTEMD_DIR" \
  FB_SYSCTL_FILE="$SYSCTL_FILE" \
  PATH="$STUB_DIR:$PATH" \
  bash "$SCRIPT_PATH" "$@"
}

run_fb_stdin() {
  FB_TEST_MODE=1 \
  FB_CONF_DIR="$CONF_DIR" \
  FB_BACKUP_DIR="$BACKUP_DIR" \
  FB_LOG_DIR="$LOG_DIR" \
  FB_STATE_DIR="$STATE_DIR" \
  FB_TMP_DIR="$TMP_DIR" \
  FB_SELF_TARGET="$SELF_TARGET" \
  FB_SYSTEMD_DIR="$SYSTEMD_DIR" \
  FB_SYSCTL_FILE="$SYSCTL_FILE" \
  FB_SELF_SOURCE_URL="https://example.invalid/fb.sh" \
  FB_TEST_DOWNLOAD_SOURCE="$SCRIPT_PATH" \
  PATH="$STUB_DIR:$PATH" \
  bash -s -- "$@" < "$SCRIPT_PATH"
}

main() {
  reset_env

  bash -n "$SCRIPT_PATH"
  pass "bash -n syntax check"

  run_fb add iptables tcp 0.0.0.0 30000 1.1.1.1 22 >/dev/null
  assert_rule_count 1 "iptables rule added without unrelated binaries"

  run_fb add realm tcp 0.0.0.0 30001 2.2.2.2 22 >/dev/null
  assert_rule_count 2 "realm rule added"
  local realm_service
  realm_service="$(find "$SYSTEMD_DIR" -maxdepth 1 -name 'fb-realm-*.service' | head -n1)"
  assert_file_exists "$realm_service" "realm service generated"
  assert_file_contains "$realm_service" "$STUB_DIR/realm -c" "realm service uses detected binary path"

  if run_fb add haproxy tcp 0.0.0.0 30002 3.3.3.3 80 >/dev/null 2>&1; then
    fail "haproxy add should fail when binary is absent"
  fi
  assert_rule_count 2 "failed add rolled back cleanly"
  if grep -q '|haproxy|' "$CONF_DIR/rules.db"; then
    fail "haproxy rule should not remain after rollback"
  fi
  pass "rollback removed failed haproxy rule"

  run_fb batch-add gost tcp 0.0.0.0 31000 22 4.4.4.4,5.5.5.5:2222 >/dev/null
  assert_rule_count 4 "batch add committed two gost rules"
  local gost_service
  gost_service="$(find "$SYSTEMD_DIR" -maxdepth 1 -name 'fb-gost-*.service' | head -n1)"
  assert_file_exists "$gost_service" "gost service generated"
  assert_file_contains "$gost_service" "$STUB_DIR/gost -L=tcp://" "gost service uses detected binary path"

  local backup_file
  backup_file="$(run_fb backup | tail -n1)"
  assert_file_exists "$backup_file" "backup archive created"

  rm -f "$SELF_TARGET"
  run_fb_stdin install-self >/dev/null
  assert_file_exists "$SELF_TARGET" "stdin one-click install wrote fb command"

  local realm_id
  realm_id="$(awk -F'|' '$2=="realm"{print $1; exit}' "$CONF_DIR/rules.db")"
  [[ -n "$realm_id" ]] || fail "missing realm rule id"
  run_fb del "$realm_id" >/dev/null
  assert_rule_count 3 "delete rule committed"

  run_fb restore "$backup_file" >/dev/null
  assert_rule_count 4 "restore recovered deleted rule"

  touch "$SELF_TARGET"
  run_fb uninstall >/dev/null
  assert_file_missing "$SELF_TARGET" "uninstall removed fb command"
  assert_file_missing "$SYSTEMD_DIR/fb-rebuild.service" "uninstall removed rebuild service"
  gost_service="$(find "$SYSTEMD_DIR" -maxdepth 1 -name 'fb-gost-*.service' | head -n1)"
  assert_file_exists "$gost_service" "uninstall keep mode preserved existing forwarding services"

  pass "all mock integration checks passed"
}

main "$@"
