#!/bin/bash
# Appbox entrypoint for BookOrbit (multi-service / s6-overlay pattern).
#
#   1. One-time setup that must finish before services start:
#      ownership, generated secrets, PostgreSQL initdb.
#   2. Appbox lifecycle in a background subshell: wait for the app, create the
#      admin user on a fresh install, then call the platform callback.
#   3. exec "$@"  ->  /init (s6-overlay), which supervises PostgreSQL and
#      BookOrbit, both as UID 1000.
#
# States:
#   fresh install : no /etc/app_configured, no /data/.appbox_configured
#   upgrade       : no /etc/app_configured, /data/.appbox_configured exists
#   restart       : /etc/app_configured exists -> lifecycle block is skipped
set -e

APP_USER="1000:1000"
CONFIG_FLAG="/etc/app_configured"
FRESH_MARKER="/data/.appbox_configured"
SECRETS_FILE="/data/.appbox-secrets.env"
LOCAL_URL="http://127.0.0.1:${PORT:-3000}"
PG_BIN="${PG_BIN:-/usr/libexec/postgresql18}"
PGDATA="${PGDATA:-/database/pgdata}"

wait_for_http() {
    local url="$1" attempts="${2:-300}" sleep_seconds="${3:-2}" i=0
    until curl -sf "${url}" >/dev/null 2>&1; do
        i=$((i + 1))
        if [[ "${i}" -ge "${attempts}" ]]; then
            echo "Timed out waiting for ${url}"
            return 1
        fi
        sleep "${sleep_seconds}"
    done
}

callback_installed() {
    if [[ "${SKIP_APPBOX_CALLBACK:-0}" == "1" ]]; then
        echo "Skipping Appbox callback because SKIP_APPBOX_CALLBACK=1"
        return 0
    fi

    local callback_url="https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}"
    local headers=(
        -H "Accept: application/json"
        -H "Content-Type: application/json"
    )
    if [[ -n "${CALLBACK_TOKEN:-}" ]]; then
        headers+=(-H "Authorization: Bearer ${CALLBACK_TOKEN}")
    fi

    until curl -fsS -o /dev/null "${headers[@]}" -X POST "${callback_url}"; do
        sleep 5
    done
}

# Create the first (superuser) account through BookOrbit's own setup API:
#   POST /api/v1/auth/setup   header x-setup-token: $SETUP_BOOTSTRAP_TOKEN
# The endpoint only works while no user exists, and is rate limited to
# 3 requests/minute, hence the slow retry.
#
# BookOrbit validates the email more strictly than the Appbox install form
# does. If it rejects the request (HTTP 400), retry once with a placeholder
# address so the install still ends with a working admin login; the real
# address can be set afterwards in BookOrbit's profile settings.
setup_request_body() {
    # Build the JSON with node so any character in the password is escaped.
    SETUP_EMAIL="$1" node -e 'process.stdout.write(JSON.stringify({
        username: process.env.USERNAME,
        name: process.env.USERNAME,
        email: process.env.SETUP_EMAIL,
        password: process.env.PASSWORD,
    }))'
}

create_admin_user() {
    local body status attempt used_placeholder=0
    body="$(setup_request_body "${EMAIL:-}")" || return 1

    for attempt in 1 2 3; do
        status="$(curl -sS -o /tmp/appbox-setup-response -w '%{http_code}' \
            -X POST "${LOCAL_URL}/api/v1/auth/setup" \
            -H "Content-Type: application/json" \
            -H "x-setup-token: ${SETUP_BOOTSTRAP_TOKEN}" \
            --data-binary "${body}")" || status="000"

        case "${status}" in
            2??)
                rm -f /tmp/appbox-setup-response
                echo "Admin user created."
                return 0
                ;;
            409)
                rm -f /tmp/appbox-setup-response
                echo "BookOrbit reports setup already completed; leaving the existing account alone."
                return 0
                ;;
        esac

        echo "Admin setup attempt ${attempt} failed with HTTP ${status}:"
        cat /tmp/appbox-setup-response 2>/dev/null || true
        echo

        if [[ "${status}" == "400" && "${used_placeholder}" == "0" ]]; then
            used_placeholder=1
            echo "Retrying with placeholder email ${USERNAME}@appbox.invalid"
            body="$(setup_request_body "${USERNAME}@appbox.invalid")" || return 1
            continue
        fi
        if [[ "${attempt}" -lt 3 ]]; then sleep 25; fi
    done
    rm -f /tmp/appbox-setup-response
    return 1
}

# ---------------------------------------------------------------------------
# One-time setup (before s6-overlay starts any service)
# ---------------------------------------------------------------------------

# initdb needs a passwd entry for UID 1000. The upstream image already has one
# ("node"); this is only a guard.
if ! getent passwd 1000 >/dev/null 2>&1; then
    echo "appuser:x:1000:1000::/data:/sbin/nologin" >> /etc/passwd
fi
if ! getent group 1000 >/dev/null 2>&1; then
    echo "appuser:x:1000:" >> /etc/group
fi

# Fresh volumes arrive root-owned. Recursive chown only on the first boot of a
# container (fresh install / upgrade); plain restarts just fix the top level.
mkdir -p /data /database /run/postgresql
if [[ ! -f "${CONFIG_FLAG}" ]]; then
    chown -R "${APP_USER}" /data /database
else
    chown "${APP_USER}" /data /database
fi
chown "${APP_USER}" /run/postgresql

# Secrets BookOrbit requires. Generated once per install and stored in the
# /data volume so they survive upgrades (changing JWT_SECRET would log everyone
# out; changing PODCAST_ENCRYPTION_KEY would make stored podcast URLs unreadable).
if [[ ! -s "${SECRETS_FILE}" ]]; then
    (
        umask 077
        {
            echo "JWT_SECRET=$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"
            echo "PODCAST_ENCRYPTION_KEY=$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')"
            echo "SETUP_BOOTSTRAP_TOKEN=$(node -e 'process.stdout.write(require("crypto").randomBytes(16).toString("hex"))')"
        } > "${SECRETS_FILE}.tmp"
    )
    mv "${SECRETS_FILE}.tmp" "${SECRETS_FILE}"
fi
chown "${APP_USER}" "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"

# PostgreSQL data directory. Authentication is "trust", but PostgreSQL only
# listens on 127.0.0.1 and a unix socket inside this container, and nothing
# from the database is published by appbox.yml.
if [[ ! -f "${PGDATA}/PG_VERSION" ]]; then
    echo "Initialising PostgreSQL data directory at ${PGDATA}"
    mkdir -p "${PGDATA}"
    chown "${APP_USER}" "${PGDATA}"
    chmod 700 "${PGDATA}"
    gosu "${APP_USER}" "${PG_BIN}/initdb" -D "${PGDATA}" \
        -U "${POSTGRES_USER:-bookorbit}" \
        -E UTF8 --locale=C.UTF-8 --auth=trust
fi

# ---------------------------------------------------------------------------
# Appbox lifecycle (background: /init takes over this process below)
# ---------------------------------------------------------------------------
if [[ ! -f "${CONFIG_FLAG}" ]]; then
    touch "${CONFIG_FLAG}"

    (
        set +e   # never let a timeout kill the subshell before the callback

        if [[ ! -f "${FRESH_MARKER}" ]]; then
            echo "Fresh install: waiting for BookOrbit to come up..."
            if wait_for_http "${LOCAL_URL}/api/v1/health" 300 2; then
                # shellcheck disable=SC1090
                . "${SECRETS_FILE}"
                if create_admin_user; then
                    gosu "${APP_USER}" touch "${FRESH_MARKER}"
                else
                    echo "WARNING: admin user was not created. Finish setup in the web UI with the"
                    echo "SETUP_BOOTSTRAP_TOKEN stored in ${SECRETS_FILE}."
                fi
            else
                echo "WARNING: BookOrbit did not become healthy; admin user was not created."
            fi
        else
            echo "Upgrade detected: existing install found, skipping admin user creation."
            # BookOrbit applies its own database migrations on startup.
            wait_for_http "${LOCAL_URL}/api/v1/health" 300 2
        fi

        callback_installed
    ) &
fi

# Hand off to s6-overlay (CMD is /init), which must be PID 1.
exec "$@"
