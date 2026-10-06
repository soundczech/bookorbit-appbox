# Official BookOrbit image plus an embedded PostgreSQL, since Appbox only runs one container per app.
# Build: docker build --platform linux/amd64 -t bookorbit-appbox .

ARG BOOKORBIT_VERSION=3.2.0
FROM ghcr.io/bookorbit/bookorbit:${BOOKORBIT_VERSION}

USER root

# s6-overlay supervises Postgres and BookOrbit. -contrib provides uuid-ossp,
# pg_trgm and unaccent; pgvector provides vector.
RUN apk add --no-cache \
        bash curl gosu s6-overlay \
        postgresql18 postgresql18-client postgresql18-contrib postgresql-pgvector

# Sanity check: fail the build if the packages don't land where the scripts
# expect them (e.g. pgvector built against a different Postgres major).
RUN test -x /init && \
    test -x /usr/libexec/postgresql18/postgres && \
    test -x /usr/libexec/postgresql18/initdb && \
    test -x /usr/libexec/postgresql18/psql && \
    find /usr/lib/postgresql18 /usr/share/postgresql18 -name 'vector.control' | grep -q . && \
    find /usr/lib/postgresql18 /usr/share/postgresql18 -name 'unaccent.control' | grep -q . && \
    [ "$(id -u node)" = "1000" ]

# svc-bookorbit depends on svc-postgres.
COPY svc-postgres-run  /etc/s6-overlay/s6-rc.d/svc-postgres/run
COPY svc-bookorbit-run /etc/s6-overlay/s6-rc.d/svc-bookorbit/run
RUN set -e; d=/etc/s6-overlay/s6-rc.d; \
    for s in svc-postgres svc-bookorbit; do \
        echo longrun > "$d/$s/type"; \
        mkdir -p "$d/$s/dependencies.d" "$d/user/contents.d"; \
        touch "$d/$s/dependencies.d/base" "$d/user/contents.d/$s"; \
        chmod +x "$d/$s/run"; \
    done; \
    touch "$d/svc-bookorbit/dependencies.d/svc-postgres"; \
    # SIGINT is Postgres' fast shutdown.
    echo SIGINT > "$d/svc-postgres/down-signal"

COPY entrypoint.sh /entrypoint.sh
COPY moduser.sh /moduser.sh
RUN sed -i 's/\r$//' /entrypoint.sh /moduser.sh \
        /etc/s6-overlay/s6-rc.d/svc-postgres/run /etc/s6-overlay/s6-rc.d/svc-bookorbit/run && \
    chmod +x /entrypoint.sh /moduser.sh && \
    mkdir -p /data /database /run/postgresql && \
    chown 1000:1000 /data /database /run/postgresql

# S6_KEEP_ENV passes Appbox's env vars (USERNAME, VIRTUAL_HOST, ...) on to the services.
ENV S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    PG_BIN=/usr/libexec/postgresql18 \
    PGDATA=/database/pgdata \
    PORT=3000 \
    POSTGRES_HOST=127.0.0.1 \
    POSTGRES_PORT=5432 \
    POSTGRES_USER=bookorbit \
    POSTGRES_DB=bookorbit \
    POSTGRES_PASSWORD=unused-local-trust-auth \
    PUID=1000 \
    PGID=1000

# Upstream's healthcheck still applies.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/init"]
EXPOSE 3000
