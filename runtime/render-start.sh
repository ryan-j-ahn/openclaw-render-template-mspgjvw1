#!/bin/bash

# Signal-safe Render entrypoint for AlphaClaw + one GBrain autopilot owner.
# Render may replace the image entrypoint when it applies Docker Command. If
# that makes this shell PID 1, enter the image's tini explicitly before
# acquiring locks or starting children.

if (( $$ == 1 )); then
  if [[ ! -x /usr/bin/tini ]]; then
    printf '%s\n' '[gbrain-supervisor] /usr/bin/tini is required when the wrapper is PID 1' >&2
    exit 78
  fi
  exec /usr/bin/tini -- /bin/bash "$0" "$@"
fi

set -uo pipefail

readonly GBRAIN_RUNTIME_DIR=/data/.gbrain
readonly GBRAIN_BIN=/usr/local/bin/gbrain
readonly ENV_BRIDGE=/app/runtime/gbrain-env-bridge.sh
readonly GIT_ASKPASS=/app/runtime/git-askpass.sh
readonly AUTOPILOT_LOG="$GBRAIN_RUNTIME_DIR/autopilot.log"
readonly AUTOPILOT_PGID_FILE="$GBRAIN_RUNTIME_DIR/render-autopilot.pgid"
readonly AUTOPILOT_LOCK_FILE="$GBRAIN_RUNTIME_DIR/autopilot.lock"
readonly HTTP_RUN=/app/runtime/http-run.sh
readonly HTTP_LOG="$GBRAIN_RUNTIME_DIR/http.log"
readonly HTTP_PID_FILE="$GBRAIN_RUNTIME_DIR/render-http.pid"
readonly ALPHACLAW_BIN=/app/node_modules/.bin/alphaclaw
readonly RESTART_DELAY_SECONDS=300
readonly HTTP_RESTART_DELAY_SECONDS=5
readonly AUTOPILOT_DRAIN_SECONDS=23
readonly WRAPPER_SHUTDOWN_SECONDS=24

mkdir -p "$GBRAIN_RUNTIME_DIR"

exec 9>"$GBRAIN_RUNTIME_DIR/render-start.lock"
if ! flock -n 9; then
  printf '%s\n' '[gbrain-supervisor] another Render startup wrapper already owns the lifecycle lock' >&2
  exit 75
fi

if [[ ! -x "$GBRAIN_BIN" ]]; then
  printf '[gbrain-supervisor] missing executable: %s\n' "$GBRAIN_BIN" >&2
  exit 78
fi
if [[ ! -r "$ENV_BRIDGE" ]]; then
  printf '[gbrain-supervisor] missing env bridge: %s\n' "$ENV_BRIDGE" >&2
  exit 78
fi
if [[ ! -x "$GIT_ASKPASS" ]]; then
  printf '[gbrain-supervisor] missing executable: %s\n' "$GIT_ASKPASS" >&2
  exit 78
fi
if [[ ! -x "$HTTP_RUN" ]]; then
  printf '[gbrain-supervisor] missing executable: %s\n' "$HTTP_RUN" >&2
  exit 78
fi
if [[ ! -x "$ALPHACLAW_BIN" ]]; then
  printf '[gbrain-supervisor] missing executable: %s\n' "$ALPHACLAW_BIN" >&2
  exit 78
fi

if ! git -C /data/brain config --local core.askpass "$GIT_ASKPASS"; then
  printf '%s\n' '[gbrain-supervisor] failed to configure brain repo askpass' >&2
  exit 78
fi

# Reconcile GBrain's persistent PID-only autopilot lock.
# This wrapper already owns the lifecycle flock before reaching this point.
# Remove locks whose PID is dead or has been reused by another process.
# Fail closed if the PID appears to be an actual live GBrain autopilot.
reconcile_gbrain_autopilot_lock() {
  local lock_pid=''
  local cmdline=''

  [[ -e "$AUTOPILOT_LOCK_FILE" ]] || return 0

  lock_pid=$(tr -d '[:space:]' <"$AUTOPILOT_LOCK_FILE" 2>/dev/null || true)

  if [[ ! "$lock_pid" =~ ^[0-9]+$ ]] || (( lock_pid <= 1 )); then
    printf '[gbrain-supervisor] removing malformed stale autopilot lock\n' >&2
    rm -f "$AUTOPILOT_LOCK_FILE"
    return 0
  fi

  if ! kill -0 "$lock_pid" 2>/dev/null; then
    printf '[gbrain-supervisor] removing stale autopilot lock for dead pid=%s\n' "$lock_pid" >&2
    rm -f "$AUTOPILOT_LOCK_FILE"
    return 0
  fi

  if [[ ! -r "/proc/$lock_pid/cmdline" ]]; then
    # The process may have exited after kill -0; re-check before failing closed.
    if ! kill -0 "$lock_pid" 2>/dev/null; then
      printf '[gbrain-supervisor] removing stale autopilot lock for pid=%s that exited during reconciliation\n' "$lock_pid" >&2
      rm -f "$AUTOPILOT_LOCK_FILE"
      return 0
    fi

    printf '[gbrain-supervisor] refusing startup: lock pid=%s is alive but cannot be identified\n' "$lock_pid" >&2
    exit 78
  fi

  cmdline=$(tr '\0' ' ' <"/proc/$lock_pid/cmdline" 2>/dev/null || true)

  if [[ "$cmdline" == *"gbrain autopilot"* ]]; then
    printf '[gbrain-supervisor] refusing startup: live autopilot already owns lock pid=%s\n' "$lock_pid" >&2
    exit 78
  fi

  printf '[gbrain-supervisor] removing stale autopilot lock: pid=%s belongs to another process\n' "$lock_pid" >&2
  rm -f "$AUTOPILOT_LOCK_FILE"
}

reconcile_gbrain_autopilot_lock

# Discard stale runtime markers before this lock-holding owner starts.
: >"$AUTOPILOT_PGID_FILE"
: >"$HTTP_PID_FILE"

read_autopilot_group() {
  local group_id=''
  IFS= read -r group_id <"$AUTOPILOT_PGID_FILE" || return 1
  [[ "$group_id" =~ ^[0-9]+$ ]] && (( group_id > 1 )) || return 1
  printf '%s\n' "$group_id"
}

signal_current_autopilot_group() {
  local signal=$1
  local group_id=''
  group_id=$(read_autopilot_group) || return 0
  kill "-$signal" -- "-$group_id" 2>/dev/null || true
}

autopilot_group_exists() {
  local group_id=$1
  kill -0 -- "-$group_id" 2>/dev/null
}

drain_autopilot_group() {
  local group_id=$1
  local ticks=$((AUTOPILOT_DRAIN_SECONDS * 4))
  local tick=0

  # Render disk-backed services enforce a fixed 30-second outer deadline.
  # Give the isolated group up to 23 seconds, then force-clean it so the
  # top-level wrapper can finish within its 24-second hard budget.
  kill -TERM -- "-$group_id" 2>/dev/null || true
  while autopilot_group_exists "$group_id" && (( tick < ticks )); do
    sleep 0.25
    ((tick += 1))
  done
  if autopilot_group_exists "$group_id"; then
    printf '[gbrain-supervisor] autopilot group exceeded %ss drain; sending SIGKILL\n' \
      "$AUTOPILOT_DRAIN_SECONDS" >>"$AUTOPILOT_LOG"
    kill -KILL -- "-$group_id" 2>/dev/null || true
  fi
}

read_http_pid() {
  local http_pid=''
  IFS= read -r http_pid <"$HTTP_PID_FILE" || return 1
  [[ "$http_pid" =~ ^[0-9]+$ ]] && (( http_pid > 1 )) || return 1
  printf '%s\n' "$http_pid"
}

signal_current_http_process() {
  local signal=$1
  local http_pid=''
  http_pid=$(read_http_pid) || return 0
  kill "-$signal" "$http_pid" 2>/dev/null || true
}

autopilot_supervisor() {
  local autopilot_pid=''
  local child_rc=0
  local delay_pid=''

  stop_autopilot_child() {
    trap - TERM INT
    if [[ -n "$delay_pid" ]]; then
      kill -TERM "$delay_pid" 2>/dev/null || true
      wait "$delay_pid" 2>/dev/null || true
    fi
    if [[ -n "$autopilot_pid" ]]; then
      drain_autopilot_group "$autopilot_pid"
      wait "$autopilot_pid" 2>/dev/null || true
    fi
    exit 0
  }
  trap stop_autopilot_child TERM INT

  while true; do
    # A dedicated session/process group lets us signal and reap the managed
    # worker even if the GBrain parent exits before that worker finishes.
    # Load GBrain's least-privilege environment only inside this child so
    # AlphaClaw keeps the image's original HOME and environment behavior.
    (
      export HOME=/data
      source "$ENV_BRIDGE"
      exec setsid "$GBRAIN_BIN" autopilot --repo /data/brain
    ) >>"$AUTOPILOT_LOG" 2>&1 &
    autopilot_pid=$!
    printf '%s\n' "$autopilot_pid" >"$AUTOPILOT_PGID_FILE"
    wait "$autopilot_pid"
    child_rc=$?

    # A parent crash must not leave an orphan worker before the next owner.
    drain_autopilot_group "$autopilot_pid"
    wait "$autopilot_pid" 2>/dev/null || true
    : >"$AUTOPILOT_PGID_FILE"
    autopilot_pid=''

    printf '[gbrain-supervisor] autopilot exited rc=%s; restarting in %ss\n' \
      "$child_rc" "$RESTART_DELAY_SECONDS" >>"$AUTOPILOT_LOG"

    sleep "$RESTART_DELAY_SECONDS" &
    delay_pid=$!
    wait "$delay_pid" 2>/dev/null || true
    delay_pid=''
  done
}

http_supervisor() {
  local http_pid=''
  local child_rc=0
  local delay_pid=''

  stop_http_child() {
    trap - TERM INT
    if [[ -n "$delay_pid" ]]; then
      kill -TERM "$delay_pid" 2>/dev/null || true
      wait "$delay_pid" 2>/dev/null || true
    fi
    if [[ -n "$http_pid" ]]; then
      kill -TERM "$http_pid" 2>/dev/null || true
      wait "$http_pid" 2>/dev/null || true
    fi
    : >"$HTTP_PID_FILE"
    exit 0
  }
  trap stop_http_child TERM INT

  while true; do
    "$HTTP_RUN" >>"$HTTP_LOG" 2>&1 &
    http_pid=$!
    printf '%s\n' "$http_pid" >"$HTTP_PID_FILE"

    wait "$http_pid"
    child_rc=$?

    : >"$HTTP_PID_FILE"
    http_pid=''

    printf '[gbrain-supervisor] HTTP server exited rc=%s; restarting in %ss\n' \
      "$child_rc" "$HTTP_RESTART_DELAY_SECONDS" >>"$HTTP_LOG"

    sleep "$HTTP_RESTART_DELAY_SECONDS" &
    delay_pid=$!
    wait "$delay_pid" 2>/dev/null || true
    delay_pid=''
  done
}

autopilot_supervisor &
supervisor_pid=$!

http_supervisor &
http_supervisor_pid=$!

"$ALPHACLAW_BIN" start &
alphaclaw_pid=$!

shutdown_all() {
  local deadline_pid=''

  trap - TERM INT
  # Forward immediately to AlphaClaw and both managed GBrain processes.
  # Signal both supervisors too so neither can restart during shutdown.
  kill -TERM "$supervisor_pid" 2>/dev/null || true
  kill -TERM "$http_supervisor_pid" 2>/dev/null || true
  kill -TERM "$alphaclaw_pid" 2>/dev/null || true

  # Render will SIGKILL the container at 30 seconds. Force-clean all owned
  # children at 24 seconds, leaving six seconds for reaping and shell exit.
  (
    sleep "$WRAPPER_SHUTDOWN_SECONDS"
    signal_current_autopilot_group KILL
    signal_current_http_process KILL
    kill -KILL "$supervisor_pid" "$http_supervisor_pid" "$alphaclaw_pid" 2>/dev/null || true
  ) &
  deadline_pid=$!

  wait "$supervisor_pid" 2>/dev/null || true
  wait "$http_supervisor_pid" 2>/dev/null || true
  wait "$alphaclaw_pid" 2>/dev/null || true
  kill "$deadline_pid" 2>/dev/null || true
  wait "$deadline_pid" 2>/dev/null || true
}
trap 'shutdown_all; exit 0' TERM INT

wait "$alphaclaw_pid"
alphaclaw_rc=$?

shutdown_all
exit "$alphaclaw_rc"
