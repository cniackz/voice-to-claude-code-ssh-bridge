#!/usr/bin/env bash
#
# Example delivery hook for BRIDGE_DELIVER.
#
# bridge.sh calls this with two arguments:
#   $1  the path to the message file (the text is in the file; read it as data)
#   $2  the id of the message
# The raw remote text is not in the environment: bridge.sh clears it first.
#
# This hook never runs the message. It only copies the message into a queue
# directory and returns at once, so the SSH call is not held open. A separate
# agent watches the queue, reads each message as untrusted data, and writes its
# reply where bridge.sh is waiting:
#
#   reply directory: the "replies" folder beside "messages"
#                    (for a message file .../messages/<id>, that is .../replies/)
#   write it atomically: first ".../replies/<id>.tmp", then rename to
#                        ".../replies/<id>" on the same filesystem.
#
# The atomic rename means bridge.sh only ever sees a whole reply.

set -u
umask 077

msg_file="${1:?message file path required}"
id="${2:?id required}"

queue="${BRIDGE_QUEUE:-$HOME/.voice-bridge/queue}"
mkdir -p "$queue"

# Copy rather than move: bridge.sh owns the message file.
cp "$msg_file" "$queue/$id"
