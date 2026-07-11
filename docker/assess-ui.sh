#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Container variant of assess-ui.sh.
#
# This is the DOCKER counterpart of vm/assess-ui.sh. It is intentionally a
# separate copy, not a shared script (see build-docs / the split rationale):
# the VM and container runtimes differ in ways that don't reduce to a flag.
#
# assess-ui is a STATIC UI WAR: no database, no app.properties, no external
# logback. Like the VM script, it downloads the app's config FOLDER and the WAR
# from GCS, installs the per-webapp Tomcat context (<ctx>.xml into
# conf/Catalina/localhost), and deploys the WAR.
#
# Contract (see docker-startup.sh): invoked as `<APP_NAME>.sh APP_ENV`.
# APP_NAME is fixed to "assess-ui" here (this IS that script); the single
# argument is APP_ENV ("$1").
#
# GCS layout (${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/):
#   conf/                          the whole config folder, copied verbatim:
#     install.properties             ALL deploy values (see the key list below)
#     <install.app.context.path>.xml per-webapp Tomcat context.xml
#   <install.war>                  the versioned WAR
#
# install.properties is the single source of truth for the deploy; NOTHING is
# derived by this script. Keys used:
#   install.war                  WAR filename to download and deploy
#   install.catalina.home        target Tomcat home (CATALINA_HOME)
#   install.app.context.path     context name -> <ctx>.xml, <ctx>.war, path /<ctx>
#
# The <ctx>.xml is installed as
#   $CATALINA_HOME/conf/Catalina/localhost/<ctx>.xml
# and Tomcat names the context by the file's basename, so <ctx>.xml -> context
# path /<ctx>. It is installed VERBATIM: the absolute paths inside <ctx>.xml must
# already match install.catalina.home. Unlike assess-server, there is NO
# conf/<ctx>/ dir — this app has no app.properties and no external logback.
#
# The WAR is deployed under the stable name <ctx>.war, so it serves at /<ctx>
# regardless of the versioned filename in install.war.
#
# Differences from vm/assess-ui.sh:
#   - No `tomcat` service user. In the container image Tomcat runs as the
#     container's main process (PID 1, as root); there is no separate 'tomcat'
#     user/group, so every `chown tomcat:tomcat` / `install -o tomcat` from the
#     VM script is dropped (they would fail with "invalid user: tomcat" and, under
#     `set -e`, abort the deploy and kill the container).
#   - Tomcat is already running (started by entrypoint.sh AFTER this script
#     returns) — so this is a pure deploy step: drop the WAR + write the context,
#     then return. There is no systemd service to coordinate with, and no need to
#     wait for a hot-deploy: Tomcat starts fresh right after and picks up whatever
#     is in webapps.
#   - Invoked by docker-startup.sh; it returns, and the entrypoint then execs
#     `catalina.sh run` to serve.
# -----------------------------------------------------------------------------

# -----------------------------
# Config
# -----------------------------
# This script IS the assess-ui installer, so APP_NAME is fixed rather than taken
# from the launcher. (docker-startup.sh resolves this very file by that name —
# <clone>/docker/assess-ui.sh — so the name is already implied.) Only APP_ENV
# varies (development/production) and is the sole argument.
APP_NAME="assess-ui"

# APP_ENV is the single positional argument ("$1") per the launcher contract
# (<APP_NAME>.sh APP_ENV). It is required — refuse to run without it rather than
# deploying to a wrong default environment.
APP_ENV="${1:-}"
if [[ -z "$APP_ENV" ]]; then
  echo "ERROR: APP_ENV is required." >&2
  echo "Usage: $0 APP_ENV" >&2
  exit 1
fi

# Base GCS location that holds per-environment release artifacts. The conf/ folder
# and the WAR for this deploy live under ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/.
GCS_BASE_URL="gs://deployza-apps"
CONF_URI="${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/conf"

# Local staging dir for the downloaded conf files and WAR. Cleared first so it
# holds only the current deploy's artifacts. The conf/ contents and the WAR share
# this one dir — the WAR's filename (install.war) never collides with a conf file.
# This app's own sibling of the clone under the shared deploy root (see
# vm-startup.sh): /tmp/deployza/repo is the clone, /tmp/deployza/<APP_NAME> is ours.
STAGE_DIR="/tmp/deployza/${APP_NAME}"

# -----------------------------
# Clear the previous download from /tmp
# -----------------------------
echo "Clearing previous ${APP_NAME} staging dir (${STAGE_DIR})..."
rm -rf "${STAGE_DIR:?}"
mkdir -p "$STAGE_DIR"

# -----------------------------
# Download the conf/ folder
# -----------------------------
echo "Downloading conf folder for ${APP_NAME} (${APP_ENV})..."
echo "  conf: ${CONF_URI}/"

# Recursive copy of the whole conf/ folder. Trailing '/*' copies its contents
# straight into STAGE_DIR (rather than nesting a conf/ dir inside it).
gsutil -m cp -r "${CONF_URI}/*" "$STAGE_DIR/"

INSTALL_PROPS="${STAGE_DIR}/install.properties"
if [[ ! -f "$INSTALL_PROPS" ]]; then
  echo "ERROR: install.properties missing after download: $INSTALL_PROPS" >&2
  exit 1
fi

# read_prop <key>: prints the value of the last matching line in install.properties,
# trimmed of surrounding whitespace AND surrounding single/double quotes (values
# like install.catalina.home="..." may be quoted in the file).
read_prop() {
  local key="$1" val
  val="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$INSTALL_PROPS" \
    | tail -n1 \
    | sed 's/[[:space:]]*$//')"
  val="${val%\"}"; val="${val#\"}"   # strip a matching pair of double quotes
  val="${val%\'}"; val="${val#\'}"   # strip a matching pair of single quotes
  printf '%s' "$val"
}

# require_prop <var> <key>: read a key that must be non-empty, or abort.
require_prop() {
  local __var="$1" __key="$2" __val
  __val="$(read_prop "$__key")"
  if [[ -z "$__val" ]]; then
    echo "ERROR: required key '${__key}' not set in ${INSTALL_PROPS}." >&2
    exit 1
  fi
  printf -v "$__var" '%s' "$__val"
}

# -----------------------------
# Read every deploy value straight from install.properties
# -----------------------------
require_prop APP_WAR_FILE      'install.war'
require_prop CATALINA_HOME     'install.catalina.home'
require_prop CONTEXT_PATH      'install.app.context.path'

TOMCAT_WEBAPPS="${CATALINA_HOME}/webapps"
CATALINA_LOCALHOST="${CATALINA_HOME}/conf/Catalina/localhost"

# Staged conf file, by the name install.properties declared.
STAGED_CONTEXT_XML="${STAGE_DIR}/${CONTEXT_PATH}.xml"

if [[ ! -f "$STAGED_CONTEXT_XML" ]]; then
  echo "ERROR: expected context file missing after download: $STAGED_CONTEXT_XML" >&2
  exit 1
fi

# -----------------------------
# Download the WAR
# -----------------------------
# Downloaded to the staging dir under its real versioned filename so the staging
# dir shows exactly what was deployed. Deployed under the stable name
# <CONTEXT_PATH>.war.
TMP_WAR="${STAGE_DIR}/${APP_WAR_FILE}"
WAR_URI="${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/${APP_WAR_FILE}"
echo "Downloading WAR ${APP_WAR_FILE}..."
echo "  WAR: ${WAR_URI}"
gsutil cp "$WAR_URI" "$TMP_WAR"

# -----------------------------
# Install the per-webapp context BEFORE the WAR
# -----------------------------
# Files are installed VERBATIM — the absolute paths inside <CONTEXT_PATH>.xml
# must already match install.catalina.home. <CONTEXT_PATH>.xml IS the Tomcat
# context descriptor (its basename sets the context path) ->
# conf/Catalina/localhost/, the dir Tomcat scans. This is a static UI, so there
# is no app.properties or logback to install alongside it.
echo "Installing context descriptor to ${CATALINA_LOCALHOST}/..."
install -d -m 750 "$CATALINA_LOCALHOST"
install -m 640 "$STAGED_CONTEXT_XML" "${CATALINA_LOCALHOST}/${CONTEXT_PATH}.xml"

# -----------------------------
# Deploy WAR to Tomcat's appBase
# -----------------------------
# Tomcat is not running yet in this container (the entrypoint execs
# `catalina.sh run` AFTER this script returns), so this is a plain file drop —
# no hot-deploy race, no service restart. Remove any prior deployment first so
# the new one is picked up as a fresh deploy.
echo "Removing old deployment..."
rm -rf "${TOMCAT_WEBAPPS:?}/${CONTEXT_PATH}"
rm -f "${TOMCAT_WEBAPPS}/${CONTEXT_PATH}.war"

echo "Deploying new WAR..."
cp "$TMP_WAR" "${TOMCAT_WEBAPPS}/${CONTEXT_PATH}.war"

echo "Deployment staged. Tomcat will explode and serve /${CONTEXT_PATH} on startup."
