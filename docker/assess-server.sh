#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Container variant of assess-server.sh.
#
# This is the DOCKER counterpart of vm/assess-server.sh. It is intentionally a
# separate copy, not a shared script (see build-docs / the split rationale):
# the VM and container runtimes differ in ways that don't reduce to a flag.
#
# Like the VM script, it downloads the WAR and its properties file from GCS,
# provisions the MySQL DB/user with the credentials found in that properties
# file, installs the properties for the app to read, and deploys the WAR.
#
# Contract (see docker-startup.sh): invoked as `<APP_NAME>.sh APP_NAME APP_ENV`.
# APP_NAME and APP_ENV arrive as "$1" and "$2".
#
# Downloads (from GCS_BASE_URL/APP_ENV/APP_NAME):
#   ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/${APP_NAME}.properties  (fixed name)
#   ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/<app.war.file>          (versioned)
#
# The WAR is VERSIONED (e.g. assess-server-1.0-SNAPSHOT.war). Its exact filename
# is read from the properties file (key: app.war.file), so releases can bump the
# WAR name without editing this script. The WAR is always deployed under the
# stable name ${APP_NAME}.war, so it serves at /${APP_NAME} regardless of version.
#
# The properties file is the app's config AND the source of the DB credentials:
# spring.datasource.username / spring.datasource.password are read out of it to
# create the MySQL user, and the whole file is installed to /etc/apps for the
# app to read via -Dconfig.dir (see setenv.sh).
#
# Differences from vm/assess-server.sh:
#   - No `tomcat` service user. In the container image Tomcat runs as the
#     container's main process (PID 1, as root); there is no separate 'tomcat'
#     user/group, so every `chown tomcat:tomcat` / `install -o tomcat` from the
#     VM script is dropped (they would fail with "invalid user: tomcat" and, under
#     `set -e`, abort the deploy and kill the container).
#   - Tomcat is already running (started by tomcat-entrypoint.sh AFTER this script
#     returns) — so this is a pure deploy step: drop the WAR + write config, then
#     return. There is no systemd service to coordinate with, and no need to wait
#     for a hot-deploy: Tomcat starts fresh right after and picks up whatever is
#     in webapps.
#   - Invoked by docker-startup.sh as `<APP_NAME>.sh APP_NAME APP_ENV`; it returns,
#     and the entrypoint then execs `catalina.sh run` to serve.
# -----------------------------------------------------------------------------

# -----------------------------
# Config
# -----------------------------
# APP_NAME / APP_ENV arrive as positional args from docker-startup.sh. Both are
# required — refuse to run without them rather than deploying a wrong default.
if [[ $# -lt 2 || -z "${1:-}" || -z "${2:-}" ]]; then
  echo "ERROR: APP_NAME and APP_ENV are required." >&2
  echo "Usage: $0 APP_NAME APP_ENV" >&2
  exit 1
fi
APP_NAME="$1"
APP_ENV="$2"

# Base GCS location that holds per-environment release artifacts. The WAR and
# properties file for this deploy live under ${GCS_BASE_URL}/${APP_ENV}/.
GCS_BASE_URL="gs://deployza-apps"

# Matches the tomcat docker image (build-docker/tomcat-dockerfile):
#   - Tomcat installed under /opt/tomcat, WARs dropped into its default appBase.
#   - Config externalized to /etc/apps (setenv.sh passes -Dconfig.dir=/etc/apps).
TOMCAT_WEBAPPS="/opt/tomcat/webapps"
CONFIG_DIR="/etc/apps"

# MySQL admin credentials used to provision the app DB/user. The baked image
# installs MySQL with NO root password (see install-mysql.sh), so this is empty
# by default; an empty password means the -p flag is omitted below.
MYSQL_ROOT_USER="root"
MYSQL_ROOT_PASSWORD=""

# The app's own DB name, user, and password are all read from the downloaded
# properties file below (schema from spring.datasource.url, credentials from
# spring.datasource.username/.password), so the properties file is the single
# source of truth and cannot drift from what the app connects to.

# Both artifacts live in the per-app subfolder ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/.
# The properties file has a fixed name (${APP_NAME}.properties); the WAR name is
# VERSIONED and is read from the properties file (key: app.war.file), so it can
# change per release without touching this script. The properties URI is derived
# here; the WAR URI is derived below once the filename is known.
PROPS_URI="${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/${APP_NAME}.properties"

# The WAR is downloaded to /tmp under its real versioned filename (set once
# app.war.file is known), so /tmp shows exactly which artifact was deployed.
# The previous download is cleared first (see below), so only the current
# deploy's WAR + properties remain.
TMP_PROPS="/tmp/${APP_NAME}.properties"

# -----------------------------
# Clear the previous download from /tmp
# -----------------------------
# Remove this app's prior WAR(s) and properties so /tmp holds only the current
# deploy. Glob covers any earlier version (${APP_NAME}-*.war), so we don't need
# to know the old filename. nullglob keeps the rm harmless when nothing matches.
echo "Clearing previous ${APP_NAME} download from /tmp..."
shopt -s nullglob
rm -f /tmp/"${APP_NAME}"-*.war /tmp/"${APP_NAME}".properties
shopt -u nullglob

# -----------------------------
# Download properties (drives WAR discovery + DB provisioning)
# -----------------------------
echo "Downloading properties for ${APP_NAME} (${APP_ENV})..."
echo "  props: ${PROPS_URI}"

gsutil cp "$PROPS_URI" "$TMP_PROPS"

read_prop() {
  # $1 = property key. Prints the trimmed value of the last matching line.
  local key="$1"
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$TMP_PROPS" \
    | tail -n1 \
    | sed 's/[[:space:]]*$//'
}

# -----------------------------
# Resolve + download the versioned WAR
# -----------------------------
# The uploaded WAR is versioned, e.g. assess-server-1.0-SNAPSHOT.war. Its exact
# filename lives in the properties file (app.war.file), so the source object is
#   ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/${APP_WAR_FILE}
# but it is deployed under the stable name ${APP_NAME}.war (context path
# /${APP_NAME}) regardless of version.
APP_WAR_FILE="$(read_prop 'app.war.file')"
if [[ -z "$APP_WAR_FILE" ]]; then
  echo "ERROR: 'app.war.file' not set in ${TMP_PROPS}; cannot resolve WAR filename." >&2
  exit 1
fi

# Download to the real versioned filename so /tmp shows exactly what was
# deployed. Prior downloads for this app were already cleared above.
TMP_WAR="/tmp/${APP_WAR_FILE}"
WAR_URI="${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/${APP_WAR_FILE}"
echo "Downloading WAR ${APP_WAR_FILE}..."
echo "  WAR: ${WAR_URI}"
gsutil cp "$WAR_URI" "$TMP_WAR"

# -----------------------------
# Extract DB credentials from the properties file
# -----------------------------
# The downloaded properties file is the source of truth for the DB name and
# user/password. Read the spring.datasource.username / .password keys (tolerating
# surrounding whitespace and an optional space around '='). We do NOT print the
# password.
echo "Reading DB credentials from ${TMP_PROPS}..."

APP_DB_USER="$(read_prop 'spring.datasource.username')"
APP_DB_PASSWORD="$(read_prop 'spring.datasource.password')"

if [[ -z "$APP_DB_USER" || -z "$APP_DB_PASSWORD" ]]; then
  echo "ERROR: could not read spring.datasource.username/password from ${TMP_PROPS}" >&2
  exit 1
fi
echo "  DB user resolved: ${APP_DB_USER}"

# The schema name is derived from spring.datasource.url so it always matches the
# schema the app connects to. The URL looks like
#   jdbc:mysql://host:port/<schema>?param=...
# Strip everything up to and including the last '/', then drop any '?...' query
# string. This keeps the script and the app in sync with a single source of truth.
APP_DB_URL="$(read_prop 'spring.datasource.url')"
if [[ -z "$APP_DB_URL" ]]; then
  echo "ERROR: 'spring.datasource.url' not set in ${TMP_PROPS}; cannot resolve DB schema name." >&2
  exit 1
fi
APP_DB="${APP_DB_URL##*/}"   # drop everything up to the last '/'
APP_DB="${APP_DB%%\?*}"      # drop the '?query=string' if present
if [[ -z "$APP_DB" ]]; then
  echo "ERROR: could not parse schema name from spring.datasource.url ('${APP_DB_URL}')." >&2
  exit 1
fi
echo "  DB schema resolved: ${APP_DB}"

# -----------------------------
# Create MySQL DB and user
# -----------------------------
echo "Creating MySQL database and user..."

# Only pass -p when a root password is actually set; with an empty password we
# omit the flag entirely so auth goes over the passwordless local socket.
MYSQL_AUTH_ARGS=(-u"${MYSQL_ROOT_USER}")
if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
  MYSQL_AUTH_ARGS+=(-p"${MYSQL_ROOT_PASSWORD}")
fi

mysql "${MYSQL_AUTH_ARGS[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${APP_DB}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'localhost'
  IDENTIFIED BY '${APP_DB_PASSWORD}';

ALTER USER '${APP_DB_USER}'@'localhost'
  IDENTIFIED BY '${APP_DB_PASSWORD}';

GRANT ALL PRIVILEGES ON \`${APP_DB}\`.* TO '${APP_DB_USER}'@'localhost';

FLUSH PRIVILEGES;
SQL

# -----------------------------
# Install application properties BEFORE deploying the WAR
# -----------------------------
# The image exports CONFIG_DIR=/etc/apps and passes -Dconfig.dir=/etc/apps to the
# JVM (see setenv.sh). The app reads its config from there, so the downloaded
# properties file must be in place before the WAR starts up.
echo "Installing application properties to ${CONFIG_DIR}/${APP_NAME}.properties..."

install -d -m 750 "$CONFIG_DIR"

PROPS_FILE="${CONFIG_DIR}/${APP_NAME}.properties"
install -m 640 "$TMP_PROPS" "$PROPS_FILE"

# -----------------------------
# Deploy WAR to Tomcat's appBase
# -----------------------------
# Tomcat is not running yet in this container (the entrypoint execs
# `catalina.sh run` AFTER this script returns), so this is a plain file drop —
# no hot-deploy race, no service restart. Remove any prior deployment first so
# the new one is picked up as a fresh deploy.
echo "Removing old deployment..."
rm -rf "${TOMCAT_WEBAPPS:?}/${APP_NAME}"
rm -f "${TOMCAT_WEBAPPS}/${APP_NAME}.war"

echo "Deploying new WAR..."
cp "$TMP_WAR" "${TOMCAT_WEBAPPS}/${APP_NAME}.war"

echo "Deployment staged. Tomcat will explode and serve /${APP_NAME} on startup."
