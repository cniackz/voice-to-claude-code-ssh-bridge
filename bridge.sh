#!/usr/bin/env bash
#
# bridge.sh - hand a message that arrives over SSH to a local agent, then
# return the agent's reply.
#
# Run this as the forced command of a single, dedicated SSH key (see
# examples/authorized_keys.example). The remote text arrives in the environment
# variable SSH_ORIGINAL_COMMAND. This script never evaluates that text. It
# sanitizes the text, writes it to a file, and passes the FILE PATH and an id
# (never the text itself) to a delivery hook that you configure. The hook is the
# only part that knows how to reach your agent.
#
# Security note: anyone who can use the key can send text to an agent that holds
# tools. Treat every message as untrusted data. See README.md.

set -u
umask 077

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-1}"
}

# Trim an incomplete UTF-8 sequence at the very end. head -c counts bytes, so a
# byte-length cut can split a multi-byte character; this drops only that split
# trailing sequence and leaves the rest of the text as it is (a stray byte in the
# middle is kept, not a reason to delete everything after it). Without perl, the
# byte-cut text passes through.
trim_partial_utf8() {
  if command -v perl > /dev/null 2>&1; then
    perl -e '
      binmode STDIN; binmode STDOUT;
      local $/; my $s = <STDIN>; $s = "" unless defined $s;
      my $len = length($s);
      if ($len) {
        # Walk back from the end over continuation bytes (0x80-0xBF), at most 3,
        # to find the start of the final sequence. Only that sequence is judged.
        my $i = $len - 1;
        my $cont = 0;
        while ($i >= 0 && $cont < 3) {
          my $b = ord(substr($s, $i, 1));
          last if ($b < 0x80 || $b > 0xBF);
          $cont++; $i--;
        }
        if ($i >= 0) {
          my $lead = ord(substr($s, $i, 1));
          my $need = -1;
          if    ($lead < 0x80)                    { $need = 0; }  # ASCII
          elsif ($lead >= 0xC2 && $lead <= 0xDF)  { $need = 1; }
          elsif ($lead >= 0xE0 && $lead <= 0xEF)  { $need = 2; }
          elsif ($lead >= 0xF0 && $lead <= 0xF4)  { $need = 3; }
          # $need == -1: a stray continuation or invalid lead byte; leave it.
          if ($need >= 0 && $cont < $need) {
            $s = substr($s, 0, $i);  # drop only the incomplete trailing sequence
          }
        }
      }
      print $s;
    '
  else
    cat
  fi
}

# A config file is trusted only if it is a regular file you own and neither the
# group nor others can write it.
config_is_trusted() {
  _f="$1"
  [ -f "$_f" ] || return 1
  [ -n "$(find "$_f" -maxdepth 0 -user "$(id -un)" 2> /dev/null)" ] || return 1
  [ -z "$(find "$_f" -maxdepth 0 \( -perm -020 -o -perm -002 \) 2> /dev/null)" ] || return 1
  return 0
}

# --- configuration ---------------------------------------------------------
# Settings come from an environment file, so the SSH forced command stays
# simple. The file is plain shell that sets the variables below. Under SSH the
# path is fixed; BRIDGE_CONFIG can override it only when the script is NOT run
# over SSH, so a remote caller cannot point it at a file of their choosing.
default_config="$HOME/.voice-bridge/config"
config="$default_config"
if [ -z "${SSH_CONNECTION:-}" ] && [ -n "${BRIDGE_CONFIG:-}" ]; then
  config="$BRIDGE_CONFIG"
fi
if [ -f "$config" ]; then
  if config_is_trusted "$config"; then
    # shellcheck source=/dev/null
    . "$config"
  else
    die "Config file must be a regular file you own, not writable by group or others: $config"
  fi
fi

# A conservative PATH, so the script does not depend on the caller's login shell.
export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"

BRIDGE_DIR="${BRIDGE_DIR:-$HOME/.voice-bridge}"   # where messages, replies and logs live
BRIDGE_DELIVER="${BRIDGE_DELIVER:-}"              # a single executable: your delivery hook
BRIDGE_TIMEOUT="${BRIDGE_TIMEOUT:-240}"           # seconds to wait for a reply
BRIDGE_MAX_BYTES="${BRIDGE_MAX_BYTES:-4000}"      # bytes kept from the whole message

[ -n "$BRIDGE_DELIVER" ] ||
  die "BRIDGE_DELIVER is not set. Point it at a single executable that delivers a message to your agent."
[ -x "$BRIDGE_DELIVER" ] ||
  die "BRIDGE_DELIVER is not an executable file: $BRIDGE_DELIVER"

case "$BRIDGE_TIMEOUT" in
  '' | *[!0-9]*) die "BRIDGE_TIMEOUT must be a non-negative integer: $BRIDGE_TIMEOUT" ;;
esac
case "$BRIDGE_MAX_BYTES" in
  '' | *[!0-9]* | 0) die "BRIDGE_MAX_BYTES must be a positive integer: $BRIDGE_MAX_BYTES" ;;
esac

# --- directories -----------------------------------------------------------
msg_dir="$BRIDGE_DIR/messages"
reply_dir="$BRIDGE_DIR/replies"
log_dir="$BRIDGE_DIR/log"
mkdir -p "$msg_dir" "$reply_dir" "$log_dir" || die "cannot create $BRIDGE_DIR"
chmod 700 "$BRIDGE_DIR" "$msg_dir" "$reply_dir" "$log_dir" 2> /dev/null || true

# --- read the incoming text ------------------------------------------------
text="${SSH_ORIGINAL_COMMAND:-}"
if [ -z "$text" ]; then
  printf 'Bridge ready. Send a message with: ssh <user>@<host> "<message>"\n'
  exit 0
fi

# Remove control characters (keep tab, newline and carriage return), truncate
# the WHOLE message to BRIDGE_MAX_BYTES bytes, then drop a split trailing
# character. cut is not used: it would truncate each line, not the message.
# tr runs in the C locale so it treats the input as bytes: a non-UTF-8 byte must
# pass through, not make tr stop at "Illegal byte sequence".
text="$(printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013\014\016-\037' | head -c "$BRIDGE_MAX_BYTES" | trim_partial_utf8)"

# --- store the message with a collision-free id ----------------------------
# mktemp creates a uniquely named file, so two messages in the same second
# cannot share an id. The id is that file's name.
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
msg_file="$(mktemp "$msg_dir/$stamp-XXXXXX")" || die "cannot create a message file in $msg_dir"
id="$(basename "$msg_file")"
printf '%s' "$text" > "$msg_file"

# Input log: one line per message, metadata only (time, id, byte length). The
# text stays in the message file (mode 600), so the log never carries content.
bytes="$(printf '%s' "$text" | wc -c | tr -d ' ')"
printf '%s\t%s\t%s\n' "$stamp" "$id" "$bytes" >> "$log_dir/input.log"

# --- deliver ---------------------------------------------------------------
# The hook receives the message file path and the id as its two arguments. The
# raw remote text is removed from the environment first, so it is not passed on.
# The text is never on the command line and is never evaluated. The hook must
# return promptly: it should enqueue the message and let the agent work on its
# own. A hook that blocks holds the SSH connection open.
unset SSH_ORIGINAL_COMMAND
if ! "$BRIDGE_DELIVER" "$msg_file" "$id"; then
  die "The delivery hook failed, so the message was not handed to the agent ($id)." 1
fi

# --- wait for the reply ----------------------------------------------------
# The agent writes its reply atomically: to "$reply_dir/$id.tmp", then renames
# it to "$reply_dir/$id". Because the rename is atomic, the reply is only ever
# seen whole, so there is no read-while-writing race and no settling delay.
reply_file="$reply_dir/$id"
waited=0
while [ "$waited" -lt "$BRIDGE_TIMEOUT" ]; do
  if [ -s "$reply_file" ]; then
    cat "$reply_file"
    rm -f "$reply_file" "$msg_file"   # delivered: do not keep the pair
    exit 0
  fi
  sleep 1
  waited=$((waited + 1))
done

printf 'The message was delivered (%s) but there is no reply yet. Ask again shortly.\n' "$id"
exit 0
