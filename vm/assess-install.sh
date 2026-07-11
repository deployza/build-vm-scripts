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

    echo
    echo "--- Running ${child} (${app_env}) ---------------------------"
    bash "$child_path" "$app_env"
    echo "--- Finished ${child} ---------------------------------------"
  done

  echo
  echo "All assess apps deployed."
}

main "$@"
