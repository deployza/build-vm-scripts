#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# assess-server.sh — app deploy script (the <APP_NAME>.sh that vm-startup.sh
# clones and runs as a child at boot). It downloads the WAR and its properties
# file from GCS, provisions the MySQL DB/user with the credentials found in that
# properties file, installs the properties for the app to read, and hot-deploys
# the WAR into the already-running Tomcat.
#
# Contract (see vm-startup.sh): invoked as `<APP_NAME>.sh APP_NAME APP_ENV`.
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
# Logs — this script only echoes to stdout/stderr; it is NOT its own systemd
# unit. Where its output lands depends on how it is invoked:
#   * At boot (launched by vm-startup.sh): its output is inherited by the
#     vm-startup.service unit, so it lands in that journal:
#       sudo journalctl -u vm-startup.service -b -f
#   * Run manually over SSH: output goes to your terminal; capture with
#       sudo bash assess-server.sh <APP_NAME> <APP_ENV> 2>&1 | tee /tmp/assess.log
#
# This script only DEPLOYS the WAR — the app then runs inside the separate
# 'tomcat' service, whose logs are elsewhere:
#   sudo journalctl -u tomcat -f
#   sudo tail -f /opt/tomcat/logs/catalina.out
# -----------------------------------------------------------------------------

# -----------------------------
# Config
# -----------------------------
# APP_NAME / APP_ENV arrive as positional args from vm-startup.sh; fall back to
# sane defaults if run standalone.
APP_NAME="${1:-myapp}"
APP_ENV="${2:-development}"

TOMCAT_SERVICE="tomcat"

# Base GCS location that holds per-environment release artifacts. The WAR and
# properties file for this deploy live under ${GCS_BASE_URL}/${APP_ENV}/.
GCS_BASE_URL="gs://deployza-apps"

# These match the tomcat-mysql image (build-vm-images):
#   - Tomcat installed under /opt/tomcat, WARs dropped into its default appBase.
#   - Config externalized to /etc/apps and exposed to the app as -Dconfig.dir.
# See scripts/ubuntu/{install-tomcat.sh,setenv.sh,tomcat.service}.
TOMCAT_WEBAPPS="/opt/tomcat/webapps"
CONFIG_DIR="/etc/apps"
TOMCAT_USER="tomcat"
TOMCAT_GROUP="tomcat"

# MySQL admin credentials used to provision the app DB/user.
MYSQL_ROOT_USER="root"
MYSQL_ROOT_PASSWORD="root_password_here"

# The app's own DB name. The user/password are read from the downloaded
# properties file below.
APP_DB="${APP_NAME}db"

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
# The downloaded properties file is the source of truth for the DB user/password.
# Read the spring.datasource.username / .password keys (tolerating surrounding
# whitespace and an optional space around '='). We do NOT print the password.
echo "Reading DB credentials from ${TMP_PROPS}..."

APP_DB_USER="$(read_prop 'spring.datasource.username')"
APP_DB_PASSWORD="$(read_prop 'spring.datasource.password')"

if [[ -z "$APP_DB_USER" || -z "$APP_DB_PASSWORD" ]]; then
  echo "ERROR: could not read spring.datasource.username/password from ${TMP_PROPS}" >&2
  exit 1
fi
echo "  DB user resolved: ${APP_DB_USER}"

# -----------------------------
# Create MySQL DB and user
# -----------------------------
echo "Creating MySQL database and user..."

mysql -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}" <<SQL
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
# properties file must be in place before the WAR starts up for the first time.
echo "Installing application properties to ${CONFIG_DIR}/${APP_NAME}.properties..."

install -d -o "$TOMCAT_USER" -g "$TOMCAT_GROUP" -m 750 "$CONFIG_DIR"

PROPS_FILE="${CONFIG_DIR}/${APP_NAME}.properties"
install -o "$TOMCAT_USER" -g "$TOMCAT_GROUP" -m 640 "$TMP_PROPS" "$PROPS_FILE"

# -----------------------------
# Deploy WAR to Tomcat (hot deploy, no service restart)
# -----------------------------
# Tomcat's default host has autoDeploy="true" and unpackWARs="true", so dropping a
# WAR into the appBase makes Tomcat explode and deploy it live — no restart needed.
# Remove the previous exploded dir and WAR first so the new one is picked up as a
# fresh deploy.
echo "Removing old deployment..."
rm -rf "${TOMCAT_WEBAPPS:?}/${APP_NAME}"
rm -f "${TOMCAT_WEBAPPS}/${APP_NAME}.war"

echo "Deploying new WAR..."
# Copy to a temp name in the same dir, then rename, so Tomcat's watcher never sees
# a partially-written WAR.
cp "$TMP_WAR" "${TOMCAT_WEBAPPS}/.${APP_NAME}.war.tmp"
chown "$TOMCAT_USER":"$TOMCAT_GROUP" "${TOMCAT_WEBAPPS}/.${APP_NAME}.war.tmp"
mv "${TOMCAT_WEBAPPS}/.${APP_NAME}.war.tmp" "${TOMCAT_WEBAPPS}/${APP_NAME}.war"

echo "Waiting for Tomcat to explode and deploy the WAR..."
for _ in $(seq 1 60); do
  if [[ -d "${TOMCAT_WEBAPPS}/${APP_NAME}" ]]; then
    echo "WAR exploded to ${TOMCAT_WEBAPPS}/${APP_NAME}"
    break
  fi
  sleep 2
done

if [[ ! -d "${TOMCAT_WEBAPPS}/${APP_NAME}" ]]; then
  echo "WARNING: WAR not exploded after timeout. Check ${TOMCAT_SERVICE} logs." >&2
fi

echo "Deployment complete."
echo "App should be available at: /${APP_NAME}"
