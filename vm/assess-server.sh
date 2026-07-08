#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# assess-server.sh — app deploy script (the <APP_NAME>.sh that vm-startup.sh
# clones and runs as a child at boot). It downloads the app's config FOLDER and
# the WAR from GCS, provisions the MySQL DB/user, installs the per-webapp Tomcat
# context (context.xml + properties + logback) into
# $CATALINA_HOME/conf/Catalina/localhost, and hot-deploys the WAR into the
# already-running Tomcat.
#
# Contract (see vm-startup.sh): invoked as `<APP_NAME>.sh APP_ENV`.
# APP_NAME is fixed to "assess-server" here (this IS that script); the single
# argument is APP_ENV ("$1").
#
# GCS layout (${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/):
#   conf/                          the whole config folder, copied verbatim:
#     install.properties             ALL deploy values (see the key list below)
#     <install.app.properties>       the app's runtime config
#     <install.app.context.path>.xml per-webapp Tomcat context.xml
#     <install.app.logback.file>     external logback config
#   <install.war>                  the versioned WAR
#
# install.properties is the single source of truth for the deploy; NOTHING is
# derived by this script. Keys used:
#   install.war                  WAR filename to download and deploy
#   install.catalina.home        target Tomcat home (CATALINA_HOME)
#   install.app.properties       app properties filename inside conf/
#   install.app.context.path     context name -> <ctx>.xml, <ctx>.war, path /<ctx>
#   install.app.logback.file     logback filename inside conf/
#   install.app.db               app database (schema) name to create
#   install.app.db.username      app DB user to create/grant
#   install.app.db.password      app DB user password
#   install.mysql.root.user      MySQL admin user (to provision the app DB/user)
#   install.mysql.root.password  MySQL admin password ("" => passwordless socket)
#
# Config model: the app no longer reads -Dconfig.dir/-Dlogs.dir (those were
# dropped from setenv.sh). Instead <ctx>.xml is installed as
#   $CATALINA_HOME/conf/Catalina/localhost/<ctx>.xml
# and its <Parameter> entries are read by the app's ServletContextListener at
# startup. Tomcat names the context by the file's basename, so <ctx>.xml ->
# context path /<ctx>. The conf files are installed VERBATIM: the absolute paths
# inside <ctx>.xml must already match install.catalina.home.
#
# The WAR is deployed under the stable name <ctx>.war, so it serves at /<ctx>
# regardless of the versioned filename in install.war.
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
#   sudo tail -f /home/tomcat/instance/logs/catalina.out
# -----------------------------------------------------------------------------

# =============================================================================
# Variable declarations
# =============================================================================
# All variables are declared here up front. Static values are set inline;
# values that depend on runtime input (the APP_ENV argument, or keys read from
# install.properties) are declared empty here and populated in main() as they
# become available. The comment on each explains where its value comes from.

# --- Fixed identity -----------------------------------------------------------
# This script IS the assess-server installer, so APP_NAME is fixed rather than
# taken from the launcher. (vm-startup.sh resolves this very file by that name —
# <clone>/vm/assess-server.sh — so the name is already implied.) Only APP_ENV
# varies (development/production) and is the sole argument.
readonly APP_NAME="assess-server"

# The 'tomcat' service the deployed WAR runs inside, and its file owner.
readonly TOMCAT_SERVICE="tomcat"
readonly TOMCAT_USER="tomcat"
readonly TOMCAT_GROUP="tomcat"

# Base GCS location that holds per-environment release artifacts. The conf/
# folder and the WAR for this deploy live under
# ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/.
readonly GCS_BASE_URL="gs://deployza-apps"

# --- Populated in main() from the APP_ENV argument ----------------------------
APP_ENV=""              # the single positional argument ("$1"): dev/production
CONF_URI=""             # ${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/conf
STAGE_DIR=""            # local staging dir for the downloaded conf files + WAR
INSTALL_PROPS=""        # ${STAGE_DIR}/install.properties

# --- Populated in main() from install.properties ------------------------------
APP_WAR_FILE=""         # install.war             WAR filename to download/deploy
CATALINA_HOME=""        # install.catalina.home   target Tomcat home
APP_PROPS_FILE=""       # install.app.properties  app properties filename
CONTEXT_PATH=""         # install.app.context.path  context name (/<ctx>)
APP_DB=""               # install.app.db          app database (schema) name
APP_DB_USER=""          # install.app.db.username app DB user to create/grant
APP_DB_PASSWORD=""      # install.app.db.password app DB user password
LOGBACK_FILE=""         # install.app.logback.file  logback filename
MYSQL_ROOT_USER=""      # install.mysql.root.user   MySQL admin user
MYSQL_ROOT_PASSWORD=""  # install.mysql.root.password  ("" => passwordless socket)

# --- Derived in main() from CATALINA_HOME / the conf keys ---------------------
TOMCAT_WEBAPPS=""       # ${CATALINA_HOME}/webapps
CATALINA_LOCALHOST=""   # ${CATALINA_HOME}/conf/Catalina/localhost
STAGED_APP_PROPS=""     # ${STAGE_DIR}/${APP_PROPS_FILE}
STAGED_CONTEXT_XML=""   # ${STAGE_DIR}/${CONTEXT_PATH}.xml
STAGED_LOGBACK=""       # ${STAGE_DIR}/${LOGBACK_FILE}
TMP_WAR=""              # ${STAGE_DIR}/${APP_WAR_FILE}  (real versioned name)
WAR_URI=""              # GCS URI of the WAR
WAR_PATH=""             # ${TOMCAT_WEBAPPS}/${CONTEXT_PATH}.war (deployed name)
EXPLODED_DIR=""         # ${TOMCAT_WEBAPPS}/${CONTEXT_PATH}     (Tomcat-exploded)

# =============================================================================
# Functions
# =============================================================================

# read_prop <key>: prints the value of the last matching line in
# install.properties, trimmed of surrounding whitespace AND surrounding
# single/double quotes (values like install.mysql.root.user="root" are quoted
# in the file).
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

# parse_args: validate the launcher contract and set APP_ENV.
# APP_ENV is required — refuse to run without it rather than deploying to a
# wrong default environment.
parse_args() {
  APP_ENV="${1:-}"
  if [[ -z "$APP_ENV" ]]; then
    echo "ERROR: APP_ENV is required." >&2
    echo "Usage: $0 APP_ENV" >&2
    exit 1
  fi
}

# prepare_staging: (re)create a clean staging dir so it holds only the current
# deploy's artifacts. The conf/ contents and the WAR share this one dir — the
# WAR's filename (install.war) never collides with a conf file.
prepare_staging() {
  echo "Clearing previous ${APP_NAME} staging dir (${STAGE_DIR})..."
  rm -rf "${STAGE_DIR:?}"
  mkdir -p "$STAGE_DIR"
}

# download_conf: recursive copy of the whole conf/ folder into STAGE_DIR.
# Trailing '/*' copies its contents straight into STAGE_DIR (rather than nesting
# a conf/ dir inside it). Verifies install.properties landed.
download_conf() {
  echo "Downloading conf folder for ${APP_NAME} (${APP_ENV})..."
  echo "  conf: ${CONF_URI}/"
  gsutil -m cp -r "${CONF_URI}/*" "$STAGE_DIR/"

  if [[ ! -f "$INSTALL_PROPS" ]]; then
    echo "ERROR: install.properties missing after download: $INSTALL_PROPS" >&2
    exit 1
  fi
}

# load_props: read every deploy value straight from install.properties and
# derive the paths that depend on those values. install.properties is the single
# source of truth — nothing here is derived from anything but its keys.
load_props() {
  require_prop APP_WAR_FILE      'install.war'
  require_prop CATALINA_HOME     'install.catalina.home'
  require_prop APP_PROPS_FILE    'install.app.properties'
  require_prop CONTEXT_PATH      'install.app.context.path'
  require_prop APP_DB            'install.app.db'
  require_prop APP_DB_USER       'install.app.db.username'
  require_prop APP_DB_PASSWORD   'install.app.db.password'
  require_prop LOGBACK_FILE      'install.app.logback.file'
  require_prop MYSQL_ROOT_USER   'install.mysql.root.user'

  # NOT require_prop: an empty root password is valid — it means "authenticate
  # over the passwordless local socket" (the baked image installs MySQL with no
  # root password), and the -p flag is then omitted below.
  MYSQL_ROOT_PASSWORD="$(read_prop 'install.mysql.root.password')"

  # Tomcat locations derived from CATALINA_HOME.
  TOMCAT_WEBAPPS="${CATALINA_HOME}/webapps"
  CATALINA_LOCALHOST="${CATALINA_HOME}/conf/Catalina/localhost"

  # Staged conf files, by the names install.properties declared.
  STAGED_APP_PROPS="${STAGE_DIR}/${APP_PROPS_FILE}"
  STAGED_CONTEXT_XML="${STAGE_DIR}/${CONTEXT_PATH}.xml"
  STAGED_LOGBACK="${STAGE_DIR}/${LOGBACK_FILE}"

  # WAR: staged under its real versioned name; deployed under <CONTEXT_PATH>.war.
  TMP_WAR="${STAGE_DIR}/${APP_WAR_FILE}"
  WAR_URI="${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/${APP_WAR_FILE}"
  WAR_PATH="${TOMCAT_WEBAPPS}/${CONTEXT_PATH}.war"
  EXPLODED_DIR="${TOMCAT_WEBAPPS:?}/${CONTEXT_PATH}"
}

# verify_conf_files: fail early if any conf file install.properties named is
# missing from the staging dir.
verify_conf_files() {
  local f
  for f in "$STAGED_APP_PROPS" "$STAGED_CONTEXT_XML" "$STAGED_LOGBACK"; do
    if [[ ! -f "$f" ]]; then
      echo "ERROR: expected conf file missing after download: $f" >&2
      exit 1
    fi
  done
}

# download_war: fetch the WAR into the staging dir under its real versioned
# filename so the staging dir shows exactly what was deployed.
download_war() {
  echo "Downloading WAR ${APP_WAR_FILE}..."
  echo "  WAR: ${WAR_URI}"
  gsutil cp "$WAR_URI" "$TMP_WAR"
}

# provision_mysql: create the app DB and user. DB name and app user/password
# come straight from install.properties.
provision_mysql() {
  echo "Creating MySQL database '${APP_DB}' and user '${APP_DB_USER}'..."

  # Only pass -p when a root password is actually set; with an empty password we
  # omit the flag entirely so auth goes over the passwordless local socket.
  local mysql_auth_args=(-u"${MYSQL_ROOT_USER}")
  if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
    mysql_auth_args+=(-p"${MYSQL_ROOT_PASSWORD}")
  fi

  mysql "${mysql_auth_args[@]}" <<SQL
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
}

# install_context: install the per-webapp context (context.xml + properties +
# logback) BEFORE the WAR. The app resolves its config/log locations from
# <CONTEXT_PATH>.xml's <Parameter> entries (read by its ServletContextListener),
# so these files must be in place under $CATALINA_HOME/conf/Catalina/localhost
# before the WAR starts up for the first time. Files are installed VERBATIM —
# the absolute paths inside <CONTEXT_PATH>.xml must already match
# install.catalina.home.
install_context() {
  echo "Installing per-webapp context to ${CATALINA_LOCALHOST}/..."

  install -d -o "$TOMCAT_USER" -g "$TOMCAT_GROUP" -m 750 "$CATALINA_LOCALHOST"

  # <CONTEXT_PATH>.xml IS the Tomcat context descriptor (its basename sets the
  # context path). The properties + logback it points at are installed alongside
  # it under the names install.properties declared.
  install -o "$TOMCAT_USER" -g "$TOMCAT_GROUP" -m 640 \
    "$STAGED_CONTEXT_XML" "${CATALINA_LOCALHOST}/${CONTEXT_PATH}.xml"
  install -o "$TOMCAT_USER" -g "$TOMCAT_GROUP" -m 640 \
    "$STAGED_APP_PROPS" "${CATALINA_LOCALHOST}/${APP_PROPS_FILE}"
  install -o "$TOMCAT_USER" -g "$TOMCAT_GROUP" -m 640 \
    "$STAGED_LOGBACK" "${CATALINA_LOCALHOST}/${LOGBACK_FILE}"
}

# undeploy_previous: undeploy the previous app cleanly if present.
# Tomcat's default host has autoDeploy="true" and unpackWARs="true", so its
# HostConfig watcher reacts to changes in the appBase on the live server — no
# restart needed.
#
# Rather than rm -rf'ing the exploded dir out from under a running context
# (which skips the app's shutdown lifecycle and can race Tomcat's own redeploy
# thread), we delete ONLY <CONTEXT_PATH>.war and let Tomcat undeploy the context
# itself: it stops the context (running the app's contextDestroyed / @PreDestroy
# hooks) and then removes the exploded <CONTEXT_PATH>/ directory. The exploded
# dir disappearing is our signal that the undeploy has completed, so we wait for
# that before dropping the replacement — otherwise Tomcat could delete the
# freshly-exploded new app while finishing the old undeploy.
undeploy_previous() {
  if [[ ! -e "$WAR_PATH" && ! -d "$EXPLODED_DIR" ]]; then
    return
  fi

  echo "Undeploying existing ${CONTEXT_PATH} (removing ${CONTEXT_PATH}.war, waiting for Tomcat to stop the context)..."
  rm -f "$WAR_PATH"

  # Wait for Tomcat to finish undeploying: it removes the exploded dir once the
  # context is stopped. If autoDeploy is somehow off (no watcher), fall back to
  # removing the exploded dir ourselves after the timeout so the deploy proceeds.
  local undeployed=false _
  for _ in $(seq 1 60); do
    if [[ ! -d "$EXPLODED_DIR" ]]; then
      undeployed=true
      echo "Tomcat undeployed ${CONTEXT_PATH}."
      break
    fi
    sleep 2
  done

  if [[ "$undeployed" != true ]]; then
    echo "WARNING: Tomcat did not undeploy ${CONTEXT_PATH} within timeout; removing exploded dir directly." >&2
    rm -rf "$EXPLODED_DIR"
  fi
}

# deploy_war: drop the new WAR in and wait for Tomcat to explode it.
# Copy to a temp name in the same dir, then rename, so Tomcat's watcher never
# sees a partially-written WAR. The file is owned tomcat:tomcat before it becomes
# visible under its final name.
deploy_war() {
  echo "Deploying new WAR..."
  cp "$TMP_WAR" "${TOMCAT_WEBAPPS}/.${CONTEXT_PATH}.war.tmp"
  chown "$TOMCAT_USER":"$TOMCAT_GROUP" "${TOMCAT_WEBAPPS}/.${CONTEXT_PATH}.war.tmp"
  mv "${TOMCAT_WEBAPPS}/.${CONTEXT_PATH}.war.tmp" "$WAR_PATH"

  echo "Waiting for Tomcat to explode and deploy the WAR..."
  local _
  for _ in $(seq 1 60); do
    if [[ -d "$EXPLODED_DIR" ]]; then
      echo "WAR exploded to ${EXPLODED_DIR}"
      break
    fi
    sleep 2
  done

  if [[ ! -d "$EXPLODED_DIR" ]]; then
    echo "WARNING: WAR not exploded after timeout. Check ${TOMCAT_SERVICE} logs." >&2
  fi
}

# =============================================================================
# Main
# =============================================================================
main() {
  parse_args "$@"

  # Paths that depend only on APP_ENV / APP_NAME.
  CONF_URI="${GCS_BASE_URL}/${APP_ENV}/${APP_NAME}/conf"
  # Staging dir is this app's own sibling of the clone under the shared deploy
  # root (see vm-startup.sh): /tmp/deployza/repo is the clone, /tmp/deployza/
  # <APP_NAME> is ours. Same path whether launched by vm-startup.sh at boot or
  # run standalone over SSH.
  STAGE_DIR="/tmp/deployza/${APP_NAME}"
  INSTALL_PROPS="${STAGE_DIR}/install.properties"

  prepare_staging
  download_conf
  load_props            # reads install.properties, derives the rest of the paths
  verify_conf_files
  download_war
  provision_mysql
  install_context       # context files must land BEFORE the WAR is deployed
  undeploy_previous
  deploy_war

  echo "Deployment complete."
  echo "App should be available at: /${CONTEXT_PATH}"
}

main "$@"
