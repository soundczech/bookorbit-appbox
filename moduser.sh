#!/bin/bash
# /moduser.sh <new_password>
#
# Appbox password recovery: unconditionally overwrites the password of the
# default (admin) account. BookOrbit has no password-reset CLI, so this
# writes a bcrypt hash (cost 12, same as BookOrbit) straight to the database.
# Also clears lockouts and signs out that user's existing sessions.

NEW_PASSWORD="$1"

if [[ -z "${NEW_PASSWORD}" || $# -ne 1 ]]; then
    echo "Usage: /moduser.sh <new_password>"
    exit 1
fi

PG_BIN="${PG_BIN:-/usr/libexec/postgresql18}"

cd /app || exit 1

# Pass the password through the environment, not the command line.
HASH="$(NEW_PASSWORD="${NEW_PASSWORD}" node -e '
const { hashSync } = require("bcryptjs");
process.stdout.write(hashSync(process.env.NEW_PASSWORD, 12));
')" || { echo "Failed to hash the new password"; exit 1; }

if [[ "${HASH}" != \$2* ]]; then
    echo "Failed to hash the new password"
    exit 1
fi

UPDATED="$(gosu 1000:1000 "${PG_BIN}/psql" -h /run/postgresql \
    -U "${POSTGRES_USER:-bookorbit}" -d "${POSTGRES_DB:-bookorbit}" \
    -v ON_ERROR_STOP=1 -v hash="${HASH}" -v uname="${USERNAME:-}" -qtA <<'SQL'
UPDATE users
   SET password_hash = :'hash',
       is_default_password = false,
       failed_login_attempts = 0,
       locked_until = NULL,
       active = true,
       token_version = token_version + 1
 WHERE id = (
        SELECT id FROM users
         WHERE is_superuser
         ORDER BY (lower(username) = lower(:'uname')) DESC, id ASC
         LIMIT 1)
RETURNING username;
SQL
)" || { echo "Database update failed"; exit 1; }

if [[ -z "${UPDATED}" ]]; then
    echo "No admin account found to update"
    exit 1
fi

echo "Password updated for user: ${UPDATED}"
