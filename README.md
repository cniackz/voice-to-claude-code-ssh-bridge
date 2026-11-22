# voice-to-claude-code-ssh-bridge

Send a short message to a local AI coding agent over SSH, and hear its reply. You
speak into any SSH client (for example a phone shortcut that dictates text), the
message reaches an agent on your machine, and the agent's answer comes back on
the same connection.

The bridge is a small Bash script. It does not run your message. It writes the
message to a file and hands that file to a delivery hook you write. The hook is
the only part that knows how to reach your agent.

## Read this first: the security model

Anyone who can use the SSH key can put text in front of an agent that holds
tools. That agent can read files, run commands, and change things. So this is
prompt injection by design: the message is an instruction aimed at a capable
agent, sent by whoever holds the key.

Set it up so that risk stays small:

- **One key per device.** Give each device its own SSH key, used for nothing
  else. Lock each key down in `authorized_keys` with `restrict`, `from=` (the
  address the device connects from), and `command=` (the bridge). See
  `examples/authorized_keys.example`. A per-device key lets you revoke one device
  without touching the others; it does not isolate them, because every key
  reaches the same agent and the same `BRIDGE_DIR`.
- **Treat the message as data, never as orders.** Your agent must read each
  message as untrusted input and decide what to do, not follow it blindly. Give
  the agent only the tools it needs.
- **Keep secrets out of replies.** The reply travels back over SSH and may be
  read aloud. Do not let the agent put passwords, tokens, or private paths in it.
- **Revoke a lost key at once.** Delete that device's line from
  `authorized_keys`. The key's comment (the device label) tells you which line.

If you cannot accept that someone with the key can instruct your agent, do not
run this.

## Setup

1. Copy `bridge.sh` to the machine that runs your agent, and make it executable:
   `chmod 700 bridge.sh`.
2. Write a delivery hook. Start from `examples/deliver-to-file.sh`. It receives
   two arguments, the path to the message file and an id, and the raw message
   text is kept out of its environment. It must never run the message, and it
   must return promptly (enqueue the message and let the agent work on its own).
3. Create a config file at `~/.voice-bridge/config` that sets:
   - `BRIDGE_DELIVER` the full path to your hook (a single executable).
   - `BRIDGE_DIR` where messages, replies, and logs live (default
     `~/.voice-bridge`).
   - `BRIDGE_TIMEOUT` seconds to wait for a reply (default `240`).
   - `BRIDGE_MAX_BYTES` bytes kept from the message (default `4000`).

   Keep the file owned by you and not writable by group or others. The bridge
   refuses to read a config file that fails that check, and under SSH it only
   reads the fixed path above, never a path chosen by the caller.
4. Add one line to `~/.ssh/authorized_keys` from
   `examples/authorized_keys.example`, with your key, address, and the path to
   `bridge.sh`.
5. Test it: `./test.sh`. If you have `shellcheck`, also run
   `shellcheck bridge.sh test.sh examples/*.sh`.

Send a message with: `ssh <user>@<host> "your message here"`.

## How it works

1. SSH runs `bridge.sh` as the key's forced command. Your text arrives in the
   environment variable `SSH_ORIGINAL_COMMAND`.
2. `bridge.sh` removes control characters and truncates the whole message to
   `BRIDGE_MAX_BYTES` bytes. `head -c` counts bytes, so the limit is in bytes;
   the bridge then trims back to a whole character so the stored text stays valid
   UTF-8 (this last step uses `perl` if it is present).
3. It writes the text to a uniquely named file under `BRIDGE_DIR/messages`. The
   file name is the message id, so two messages can never share one.
4. It clears the raw text from the environment and calls your `BRIDGE_DELIVER`
   hook with the file path and the id. The text is never on the command line and
   is never evaluated.
5. Your agent reads the message as data and writes its reply atomically: first to
   `BRIDGE_DIR/replies/<id>.tmp`, then renames it to `BRIDGE_DIR/replies/<id>`
   on the same filesystem. The atomic rename means the bridge only ever sees a
   whole reply.
6. `bridge.sh` waits up to `BRIDGE_TIMEOUT` seconds for that reply, prints it,
   removes the delivered message and reply, and exits. If no reply comes in time,
   it says so and exits cleanly.

The input log at `BRIDGE_DIR/log/input.log` records one line per message: the
time, the id, and the byte length. It does not store the message text.

## What is kept, and cleaning up

- `BRIDGE_DIR/messages/<id>` holds each incoming message (mode 600). A delivered
  message is removed once its reply is printed. A message whose reply never
  arrived stays, so you can see what was asked.
- `BRIDGE_DIR/replies/<id>` holds a reply only until the bridge prints it, then
  it is removed.
- `BRIDGE_DIR/log/input.log` grows by one metadata line per message.
- If your delivery hook keeps its own copy, that copy is yours to clean. The
  example hook (`examples/deliver-to-file.sh`) copies each message into a queue
  directory (`BRIDGE_QUEUE`, default `~/.voice-bridge/queue`) and never removes
  it; your agent should delete each message once it has read it.

Sweep anything left behind on a schedule, for example a daily cron line (add the
queue directory only if your hook writes there):

    find "$HOME/.voice-bridge/messages" -type f -mtime +7 -delete
    find "$HOME/.voice-bridge/queue"    -type f -mtime +7 -delete

## Limits

- One message, one reply. There is no session or back-and-forth within a call.
- The reply is whatever your agent writes. The bridge does not change it.
- After the timeout, the bridge prints a short note and exits. A reply that
  arrives later is not sent back; asking again starts a new message, with a new
  id, not a retry of the first.
- The delivery hook runs in the foreground. It must return promptly; a hook that
  blocks holds the SSH call open, because `BRIDGE_TIMEOUT` covers only the wait
  for the reply, not the hook. A hook that exits non-zero fails the call at once
  with a plain message.
- The bridge needs `bash` and the tools `tr`, `head`, `date`, `mktemp`,
  `basename`, `cat`, `wc`, `mkdir`, `chmod`, `rm`, `sleep`, `find`, and `id`.
  `perl` is optional and only sharpens the UTF-8 truncation.

## License

MIT. See `LICENSE`.
