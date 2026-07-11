#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# assess-install.sh — ORCHESTRATOR. This is the <APP_NAME>.sh that vm-startup.sh
# clones and runs as a child at boot (APP_NAME="assess-install"). It does NOT
# deploy anything itself; it installs all three assess apps onto the same Tomcat
# instance by invoking, in order:
#
#   1. assess-server.sh    the assess backend WAR (DB + app.properties + logback)
#   2. assess-ui.sh        the static UI WAR
#   3. assess-exam.sh      the exam WAR
#
# Each child is a self-contained deploy script with its own install.properties,
# context path, and GCS artifacts. They run against the same live Tomcat, so
# each hot-deploys its own context (/<ctx>) without touching the others.
#
# Contract (see vm-startup.sh): invoked as `assess-install.sh APP_ENV`.
# APP_NAME is fixed to "assess-install" here (vm-startup.sh resolves this file by
# that name — <clone>/vm/assess-install.sh); the single argument is APP_ENV,
# which is passed through verbatim to every child.
#
# Ordering: the backend goes first so its DB/context are in place before the UI
# and exam apps come up. If any child fails, `set -e` aborts the whole run (a
# partial deploy is surfaced rather than hidden).
#
# Logs — like the child scripts, this only echoes to stdout/stderr. At boot its
# output (and the children's) is inherited by vm-startup.service:
#   sudo journalctl -u vm-startup.service -b -f
# Run manually over SSH:
#   sudo bash assess-install.sh <APP_ENV> 2>&1 | tee /tmp/assess.log
# -----------------------------------------------------------------------------

# Directory this script lives in, so the children are found regardless of CWD
# (the launcher clones to /tmp/deployza/repo and runs us from there).
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The child deploy scripts, run in this order.
readonly CHILD_SCRIPTS=(
  "assess-server.sh"
  "assess-ui.sh"
  "assess-exam.sh"
)

# Log dir owned solely by this orchestrator (a sibling of the clone under the
# deploy root: /tmp/deployza/repo is the clone, /tmp/deployza/logs is ours). The
# child scripts know NOTHING about logging — they just echo to stdout/stderr as
# before; this orchestrator decides where that output lands by redirecting each
# child's stream (see run_child) to its own per-child log file. This keeps
# logging policy in one place instead of duplicated across four scripts.
readonly LOG_DIR="/tmp/deployza/logs"

# Whether a usable log dir exists (set by init_logging). When false, we skip the
# per-child redirection and let output pass straight through to stdout/stderr, so
# a log-dir failure never blocks a deploy.
LOGGING=false

# init_logging: create the shared log dir once, best-effort, and start teeing this
# orchestrator's OWN output (its banners) to assess-install.log while still
# passing it to stdout. If the dir can't be created we warn and leave
# LOGGING=false rather than aborting under `set -e`; children then run
# unredirected (see run_child) and everything goes to stdout only.
init_logging() {
  if mkdir -p "$LOG_DIR" 2>/dev/null; then
    LOGGING=true
    exec > >(tee -a "${LOG_DIR}/assess-install.log") 2>&1
  else
    echo "WARNING: could not create ${LOG_DIR}; child output goes to stdout only." >&2
  fi
}

# run_child: invoke one child deploy script with APP_ENV, sending its combined
# stdout+stderr to that child's own log file (${LOG_DIR}/<basename>.log) AND on
# to our stdout, so the boot-time vm-startup.service journal still sees the whole
# run. Falls back to a plain (unredirected) run when logging is unavailable.
# `bash "$child_path"` needs only read permission, so the execute bit is not
# load-bearing; we do not chmod the child here.
run_child() {
  local child_path="$1" app_env="$2"
  if [[ "$LOGGING" == true ]]; then
    local child_log="${LOG_DIR}/$(basename "${child_path%.sh}").log"
    bash "$child_path" "$app_env" 2>&1 | tee -a "$child_log"
  else
    bash "$child_path" "$app_env"
  fi
}

# parse_args: validate the launcher contract and echo APP_ENV.
# APP_ENV is required — refuse to run without it rather than deploying to a
# wrong default environment.
parse_args() {
  local app_env="${1:-}"
  if [[ -z "$app_env" ]]; then
    echo "ERROR: APP_ENV is required." >&2
    echo "Usage: $0 APP_ENV" >&2
    exit 1
  fi
  printf '%s' "$app_env"
}

main() {
  local app_env
  app_env="$(parse_args "$@")"
  init_logging          # create ${LOG_DIR}; per-child output is teed in run_child

  echo "==============================================================="
  echo "assess-install orchestrator: deploying all assess apps (${app_env})"
  echo "==============================================================="

  local child
  for child in "${CHILD_SCRIPTS[@]}"; do
    local child_path="${SCRIPT_DIR}/${child}"
    if [[ ! -f "$child_path" ]]; then
      echo "ERROR: child deploy script missing: $child_path" >&2
      exit 1
    fi

    # We invoke children via `bash "$child_path"` (in run_child), which needs only
    # read permission — the execute bit is not load-bearing here. Set it anyway so
    # a child stays runnable standalone (`./assess-server.sh`), mirroring the +x
    # vm-startup.sh applies to this orchestrator.
    chmod +x "$child_path" 2>/dev/null || true

    echo
    echo "--- Running ${child} (${app_env}) ---------------------------"
    run_child "$child_path" "$app_env"
    echo "--- Finished ${child} ---------------------------------------"
  done

  echo
  echo "All assess apps deployed."
}

main "$@"
