#!/bin/bash
# Tests for set-gui-env.sh. Runs against a temp env file; never touches the real
# launchd domain — `launchctl` is stubbed on PATH so the assertions read what
# would have been published rather than publishing it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/launchctl" <<'STUB'
#!/bin/bash
# Record what would have been published, value included, so the test can assert
# the value never appears anywhere it should not.
echo "$@" >> "$RECORD"
STUB
chmod +x "$TMP/bin/launchctl"
export PATH="$TMP/bin:$PATH"

cat > "$TMP/env" <<'ENVF'
UNRELATED=keep-me
CMEM_PRO_TOKEN="cm_pro_TESTVALUE123"
OTHER_KEY='second-value'
ENVF

# A stand-in for com.screddy.ollama.plist. Every run points at one of these so
# the assertions never depend on how this host happens to have Ollama set up.
GOOD_PLIST="$TMP/ollama-good.plist"
ZERO_PLIST="$TMP/ollama-zero.plist"
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' \
  -c 'Add :EnvironmentVariables:OLLAMA_NUM_PARALLEL string 3' "$GOOD_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :EnvironmentVariables dict' \
  -c 'Add :EnvironmentVariables:OLLAMA_NUM_PARALLEL string 0' "$ZERO_PLIST" >/dev/null
export OLLAMA_PLIST="$GOOD_PLIST"

RECORD="$TMP/rec1" GUI_ENV_SOURCE="$TMP/env" bash "$HERE/set-gui-env.sh" >"$TMP/out1" 2>&1
grep -q 'setenv CMEM_PRO_TOKEN cm_pro_TESTVALUE123' "$TMP/rec1" \
  && ok "publishes the default key with its quotes stripped" \
  || no "publishes the default key" "$(cat "$TMP/rec1" 2>/dev/null)"
grep -q 'cm_pro_TESTVALUE123' "$TMP/out1" \
  && no "the value must never be printed" "$(cat "$TMP/out1")" \
  || ok "prints a length, never the value"
grep -q '39\|18 chars\|chars' "$TMP/out1" && ok "reports a character count" || no "reports a character count" "$(cat "$TMP/out1")"

RECORD="$TMP/rec2" GUI_ENV_SOURCE="$TMP/env" GUI_ENV_KEYS="CMEM_PRO_TOKEN OTHER_KEY" bash "$HERE/set-gui-env.sh" >/dev/null 2>&1
[ "$(grep -c 'setenv CMEM_PRO_TOKEN\|setenv OTHER_KEY' "$TMP/rec2")" = 2 ] && ok "GUI_ENV_KEYS publishes several keys" || no "GUI_ENV_KEYS publishes several keys" "$(cat "$TMP/rec2")"
grep -q "setenv OTHER_KEY second-value" "$TMP/rec2" && ok "strips single quotes too" || no "strips single quotes" "$(cat "$TMP/rec2")"

RECORD="$TMP/rec3" GUI_ENV_SOURCE="$TMP/nope" bash "$HERE/set-gui-env.sh" >"$TMP/out3" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "a missing env file exits 0 rather than failing login" || no "missing env file exits 0" "rc=$rc"
! grep -q 'setenv CMEM_PRO_TOKEN' "$TMP/rec3" && ok "a missing env file publishes no secret" || no "missing env file publishes no secret" "$(cat "$TMP/rec3")"

RECORD="$TMP/rec4" GUI_ENV_SOURCE="$TMP/env" GUI_ENV_KEYS="ABSENT_KEY" bash "$HERE/set-gui-env.sh" >"$TMP/out4" 2>&1
! grep -q 'setenv ABSENT_KEY' "$TMP/rec4" && ok "an absent key publishes nothing" || no "absent key publishes nothing" "$(cat "$TMP/rec4")"
grep -q 'not found' "$TMP/out4" && ok "an absent key says so instead of failing silently" || no "absent key is reported" "$(cat "$TMP/out4")"

# LLMJURY_OLLAMA_PARALLEL is derived from Ollama's own launchd unit, not from
# the env file, so it is published on its own schedule and unset rather than
# guessed when the unit cannot supply a usable number. memguard assumes 4 when
# the variable is absent, which is the safe direction; a wrong number is not.
grep -q 'setenv LLMJURY_OLLAMA_PARALLEL 3' "$TMP/rec1" \
  && ok "publishes LLMJURY_OLLAMA_PARALLEL from the Ollama unit" \
  || no "publishes LLMJURY_OLLAMA_PARALLEL" "$(cat "$TMP/rec1")"

grep -q 'setenv LLMJURY_OLLAMA_PARALLEL 3' "$TMP/rec3" \
  && ok "a missing env file still publishes the derived value" \
  || no "missing env file still publishes the derived value" "$(cat "$TMP/rec3")"

RECORD="$TMP/rec5" GUI_ENV_SOURCE="$TMP/env" OLLAMA_PLIST="$TMP/absent.plist" bash "$HERE/set-gui-env.sh" >"$TMP/out5" 2>&1
grep -q 'unsetenv LLMJURY_OLLAMA_PARALLEL' "$TMP/rec5" \
  && ok "an absent Ollama unit unsets rather than guesses" \
  || no "absent Ollama unit unsets" "$(cat "$TMP/rec5")"

RECORD="$TMP/rec6" GUI_ENV_SOURCE="$TMP/env" OLLAMA_PLIST="$ZERO_PLIST" bash "$HERE/set-gui-env.sh" >"$TMP/out6" 2>&1
grep -q 'unsetenv LLMJURY_OLLAMA_PARALLEL' "$TMP/rec6" \
  && ok "a zero slot count unsets rather than publishing 0" \
  || no "zero slot count unsets" "$(cat "$TMP/rec6")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
