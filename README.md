# BookOrbit for Appbox

Appbox package for [BookOrbit](https://github.com/bookorbit/bookorbit), a self-hosted library and reader for ebooks, audiobooks, PDFs and comics, built following the [Appbox example app](https://github.com/appbox-co/example-app).

Unofficial community package. It uses the official BookOrbit image as-is. BookOrbit is AGPL-3.0 with additional terms; see upstream.

## Layout

BookOrbit needs PostgreSQL with `vector`, `pg_trgm`, `uuid-ossp` and `unaccent`, and upstream runs it as a second container. Appbox allows one container per app, so this image adds PostgreSQL 18 to the official one and runs both under s6-overlay.

| File | Purpose |
| --- | --- |
| `appbox.yml` | Store listing, volumes, env, install form |
| `Dockerfile` | `ghcr.io/bookorbit/bookorbit` + PostgreSQL 18, pgvector, s6-overlay, bash, curl, gosu |
| `entrypoint.sh` | Ownership, secret generation, `initdb`, admin creation, Appbox callback, then `exec /init` |
| `svc-postgres-run` | s6 service: PostgreSQL as UID 1000, loopback only |
| `svc-bookorbit-run` | s6 service: waits for PostgreSQL, then runs BookOrbit's own entrypoint as UID 1000 |
| `moduser.sh` | `/moduser.sh <new_password>` resets the admin password |
| `icon.png` | 512x512 store icon (BookOrbit's own PWA icon) |

Notes for reviewers:

- **Volumes**: `data` -> `/data` (covers, app state, generated secrets) and `database` -> `/database` (PostgreSQL). The user's home is mounted read-write at `/APPBOX_DATA` for libraries, and the folder picker starts there.
- **Secrets**: `JWT_SECRET`, `PODCAST_ENCRYPTION_KEY` and `SETUP_BOOTSTRAP_TOKEN` are generated on first boot into `/data/.appbox-secrets.env` (mode 600), so they survive upgrades.
- **Database auth**: `trust`, with PostgreSQL bound to `127.0.0.1` and a unix socket inside the container. No port is published.
- **Admin account**: created through BookOrbit's `POST /api/v1/auth/setup` using the bootstrap token. Public registration is off by default in BookOrbit.
- **Memory**: 2 GB, the same as the store's Grimmory and Immich packages. The Node.js heap is set at start-up to half of the container's memory limit (256 MB to 4 GB), leaving the rest for PostgreSQL, so it grows when the user applies App Boost. Set `NODE_MAX_OLD_SPACE_SIZE` to override.
- **Email fallback**: the install form accepts some addresses that BookOrbit rejects (e.g. `a@b.c`). If setup is rejected with HTTP 400, the entrypoint retries once with `<username>@appbox.invalid` so the install still ends with a working login.
- **Public URL**: `APP_URL` is derived from the platform-injected `VIRTUAL_HOST` as `https://<host>`.
- **Upgrades**: bump `BOOKORBIT_VERSION` in the `Dockerfile` and `image.version` / `image.tag` in `appbox.yml`. BookOrbit migrates its database on start.

## Build and test

```bash
docker build --platform linux/amd64 -t bookorbit-appbox .

docker volume create bo-data && docker volume create bo-db

# Fresh install
docker run -d --name bookorbit --platform linux/amd64 \
  -e USERNAME=admin -e EMAIL=you@example.com -e PASSWORD='TestPass123!' \
  -e INSTANCE_ID=test -e SKIP_APPBOX_CALLBACK=1 \
  -e APP_URL=http://localhost:3000 \
  -v bo-data:/data -v bo-db:/database -v "$PWD/books:/APPBOX_DATA" \
  -p 3000:3000 bookorbit-appbox
docker logs -f bookorbit
# open http://localhost:3000 and log in (skip initial setup)

# Restart
docker restart bookorbit

# Upgrade (same volumes, new container; must skip admin creation)
docker rm -f bookorbit   # then repeat the docker run above

# Processes should be UID 1000 under s6
docker exec bookorbit ps -o pid,user,args

# Password reset
docker exec bookorbit /moduser.sh 'NewPass456!'
docker exec bookorbit /moduser.sh; echo "exit=$?"   # usage, non-zero

# Clean shutdown within 10s, PostgreSQL logs "database system is shut down"
time docker stop bookorbit
```

Then work through `TESTING.md` in the example app repository.
