#!/usr/bin/env bash
#
# test.sh - exercise bridge.sh without a network or a real agent.
#
# It drives bridge.sh through fake delivery hooks and checks that:
#   - an empty message prints the ready line;
#   - shell metacharacters in a message are never executed;
#   - control characters are stripped;
#   - the WHOLE message is truncated to BRIDGE_MAX_BYTES (not line by line);
#   - truncation does not leave a split UTF-8 character;
#   - a non-UTF-8 byte in the middle keeps the text after it (only the tail trims);
#   - an atomically written reply comes back whole, with no settling delay;
#   - a delivered message comes back as the reply (data, not code);
#   - a missing reply ends cleanly at the timeout.
#
# Run: ./test.sh   (also run "shellcheck bridge.sh test.sh examples/*.sh" if you
# have shellcheck installed).

set -u

here="$(cd "$(dirname "$0")" && pwd)"
bridge="$here/bridge.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/vbridge-test-XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

capture="$tmp/capture"
mkdir -p "$capture"

# A sentinel the injection test watches. If a message were ever evaluated, one
# of its metacharacters would create this file.
sentinel="$tmp/SENTINEL_MUST_NOT_EXIST"

fails=0
check() { # check <description> <0 for pass, anything else for fail>
  if [ "$2" = "0" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1"
    fails=$((fails + 1))
  fi
}

# Hook that echoes the message back as the reply, written atomically (.tmp then
# rename), the way a real agent should. It derives the replies directory from
# the message path, so it needs only its two arguments plus CAPTURE for the test.
echo_hook="$tmp/echo-hook.sh"
cat > "$echo_hook" <<'HOOK'
#!/usr/bin/env bash
set -u
msg_file="$1"
id="$2"
base="$(dirname "$(dirname "$msg_file")")"
mkdir -p "$base/replies"
cp "$msg_file" "$CAPTURE/last-message"
{ printf 'REPLY '; cat "$msg_file"; } > "$base/replies/$id.tmp"
mv "$base/replies/$id.tmp" "$base/replies/$id"
HOOK
chmod 700 "$echo_hook"

# Hook that returns at once and lets a background writer produce the reply after
# a short delay, through .tmp then rename. This checks that bridge.sh waits and
# reads the reply only once it is complete.
async_hook="$tmp/async-hook.sh"
cat > "$async_hook" <<'HOOK'
#!/usr/bin/env bash
set -u
msg_file="$1"
id="$2"
base="$(dirname "$(dirname "$msg_file")")"
mkdir -p "$base/replies"
(
  sleep 2
  printf 'line1\nline2\nline3\n' > "$base/replies/$id.tmp"
  mv "$base/replies/$id.tmp" "$base/replies/$id"
) > /dev/null 2>&1 &
HOOK
chmod 700 "$async_hook"

# Hook that delivers nothing, to force the timeout path.
silent_hook="$tmp/silent-hook.sh"
cat > "$silent_hook" <<'HOOK'
#!/usr/bin/env bash
set -u
exit 0
HOOK
chmod 700 "$silent_hook"

run() { # run <message> <state-subdir> <hook> <timeout> <max-bytes>
  SSH_ORIGINAL_COMMAND="$1" \
    BRIDGE_CONFIG=/dev/null \
    BRIDGE_DIR="$tmp/$2" \
    BRIDGE_DELIVER="$3" \
    BRIDGE_TIMEOUT="$4" \
    BRIDGE_MAX_BYTES="$5" \
    CAPTURE="$capture" \
    bash "$bridge"
}

# 1. Empty message.
out="$(run "" empty "$echo_hook" 5 4000)"
case "$out" in
  *"Bridge ready"*) check "empty message prints the ready line" 0 ;;
  *) check "empty message prints the ready line" 1 ;;
esac

# 2. Injection: metacharacters must be treated as text, not run.
rm -f "$sentinel"
# The $() and backticks are meant to stay literal here: this is the attack text.
# shellcheck disable=SC2016
inject='x; $(touch '"$sentinel"'); `touch '"$sentinel"'`; INJECT_MARKER'
out="$(run "$inject" inject "$echo_hook" 5 4000)"
if [ -e "$sentinel" ]; then
  check "injection did not execute (sentinel absent)" 1
else
  check "injection did not execute (sentinel absent)" 0
fi
case "$out" in
  *"INJECT_MARKER"*) check "injected text came back as data" 0 ;;
  *) check "injected text came back as data" 1 ;;
esac

# 3. Control characters stripped from the stored message (tab is kept).
ctrl="$(printf 'be\001fo\037re')"
run "$ctrl" ctrl "$echo_hook" 5 4000 > /dev/null
if LC_ALL=C grep -q "$(printf '[\001\037]')" "$capture/last-message"; then
  check "control characters stripped" 1
else
  check "control characters stripped" 0
fi

# 4. The WHOLE message is truncated, not each line. Three 3000-byte lines with a
#    4000-byte cap must store 4000 bytes, not 9002.
line="$(head -c 3000 < /dev/zero | tr '\0' 'a')"
multiline="$line
$line
$line"
run "$multiline" multiline "$echo_hook" 5 4000 > /dev/null
bytes="$(wc -c < "$capture/last-message" | tr -d ' ')"
if [ "$bytes" = "4000" ]; then
  check "whole message truncated to 4000 bytes" 0
else
  check "whole message truncated to 4000 bytes (got $bytes)" 1
fi

# 5. Truncation does not split a UTF-8 character. "cafe" with an accented e is
#    5 bytes; a 4-byte cap lands inside the accent, which must be dropped.
accented="$(printf 'caf\303\251')"
run "$accented" accent "$echo_hook" 5 4 > /dev/null
stored="$(cat "$capture/last-message")"
if [ "$stored" = "caf" ]; then
  check "truncation does not leave a split character" 0
else
  check "truncation does not leave a split character (got '$stored')" 1
fi

# 5b. A non-UTF-8 byte in the MIDDLE must not delete the text after it. Only an
#     incomplete sequence at the very end is trimmed. "caf\xe9here" (8 bytes, the
#     0xe9 is a lone Latin-1 byte) must be stored whole, not cut to "caf".
latin1="$(printf 'caf\351here')"
run "$latin1" latin1 "$echo_hook" 5 4000 > /dev/null
lbytes="$(wc -c < "$capture/last-message" | tr -d ' ')"
lstored="$(cat "$capture/last-message")"
case "$lstored" in
  *here) ltail=0 ;;
  *) ltail=1 ;;
esac
if [ "$lbytes" = "8" ] && [ "$ltail" = "0" ]; then
  check "a mid-string non-UTF-8 byte keeps the trailing text" 0
else
  check "a mid-string non-UTF-8 byte keeps the trailing text (got $lbytes bytes)" 1
fi

# 6. An atomically written reply comes back whole.
out="$(run "please reply" atomic "$async_hook" 10 4000)"
case "$out" in
  *"line1"*"line3"*) check "atomic reply returned whole" 0 ;;
  *) check "atomic reply returned whole" 1 ;;
esac

# 7. Timeout ends cleanly when no reply arrives.
start="$(date +%s)"
out="$(run "still here" timeout "$silent_hook" 1 4000)"
end="$(date +%s)"
case "$out" in
  *"no reply yet"*) check "timeout prints the no-reply line" 0 ;;
  *) check "timeout prints the no-reply line" 1 ;;
esac
if [ "$((end - start))" -le 5 ]; then
  check "timeout returned promptly" 0
else
  check "timeout returned promptly" 1
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'All tests passed.\n'
  exit 0
fi
printf '%s test(s) failed.\n' "$fails"
exit 1
