# Local testing (OrbStack)

This infra can be fully rehearsed locally — real content, domain routing
through Caddy on local-only `.test` domains, real HTTPS (via Caddy's
internal CA) — before ever touching the real VPS. This document is what was
actually run to validate the stack end-to-end, and the bugs it caught.

## One-time setup

1. **`/etc/hosts`** — point local-only domains at localhost. Deliberately
   **not** the real TLDs: a stray browser tab, bookmark, or forgotten
   `/etc/hosts` entry pointing `benoitchantre.com` at your laptop would be
   indistinguishable from the live site and easy to forget about. `.test` is
   IANA-reserved for testing (RFC 6761) and never resolves publicly:
   ```
   127.0.0.1 benoitchantre.test
   127.0.0.1 www.benoitchantre.test
   127.0.0.1 startertheme.test
   ```
2. **Shared network + volume:**
   ```bash
   docker network create web
   docker volume create caddy_logs
   ```
3. **Pull real data from the old VPS** (adjust paths/host as needed):
   ```bash
   rsync -avz --rsync-path="sudo rsync" \
     vps.benoitchantre.com:/var/www/html/benoitchantre.com/wp-content/ \
     sites/benoitchantre.com/wp-content/

   rsync -avz --rsync-path="sudo rsync" --exclude='*.sql' \
     vps.benoitchantre.com:/var/www/html/startertheme.benoitchantre.com/public/ \
     sites/startertheme.benoitchantre.com/data/public/

   ssh vps.benoitchantre.com \
     'sudo mysqldump --single-transaction --quick --no-tablespaces -u root fJ1fD4_benoitchantre' \
     > _migration_dumps/benoitchantre.sql
   ssh vps.benoitchantre.com \
     'sudo mysqldump --single-transaction --quick --no-tablespaces -u root pr6gs_startertheme' \
     > _migration_dumps/startertheme.sql
   ```
4. **Per-site `.env`** — copy `.env.example` → `.env` in each site dir, fill
   in generated DB passwords (dummy SMTP values are fine locally — msmtp
   will just fail to send, harmlessly).

5. **WordPress `siteurl`/`home`** — the migrated DB dumps have these set to
   the real production domains. After importing each dump (step below),
   update them to the local domain so WP-generated links/redirects/cookies
   point at `benoitchantre.test` / `startertheme.test`, not production:
   ```bash
   docker exec benoit_wp wp option update siteurl https://benoitchantre.test --allow-root
   docker exec benoit_wp wp option update home https://benoitchantre.test --allow-root
   docker exec startertheme_wp wp option update siteurl https://startertheme.test --allow-root
   docker exec startertheme_wp wp option update home https://startertheme.test --allow-root
   ```

## Bring-up order

```bash
# 1. Each site's DB first, then import the dump:
cd sites/benoitchantre.com && docker compose up -d db
# wait for healthy, then:
source .env
docker exec -i benoit_db mariadb -u root -p"$DB_ROOT_PASSWORD" "$DB_NAME" \
  < ../../_migration_dumps/benoitchantre.sql

# 2. Rest of the site stack, with the local overlay (server_name matches
#    the .test domain instead of the real TLD):
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build

# repeat for startertheme.benoitchantre.com

# 3. Caddy, with the local overlay (internal CA, routes benoitchantre.test /
#    startertheme.test instead of the real TLDs):
cd ../../caddy
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

Browser will show a cert warning unless you trust Caddy's local root CA —
either click through it, or trust it:
```bash
docker exec caddy cat /data/caddy/pki/authorities/local/root.crt > /tmp/caddy-local-ca.crt
# macOS: Keychain Access → File → Import Items → System → Always Trust
```

## What this rehearsal caught (already fixed in the infra files)

Real bugs found only by actually running the stack, not by reading the
compose files:

1. **`cap_drop: ALL` was too aggressive on the `wp` service.** The official
   WordPress image's entrypoint `tar`-extracts core into a fresh volume on
   first boot and `chmod`/`chown`s the result — that needs `FOWNER` and
   `FSETID`, which weren't in the original `cap_add` list. Without them the
   entrypoint's tar extraction failed outright. Fixed in both sites'
   `docker-compose.yml`.

2. **Missing `HTTPS` fastcgi param caused a redirect loop.** Caddy
   terminates TLS and forwards plain HTTP to nginx; nginx was passing that
   straight to PHP without telling it the original request was HTTPS. WP's
   `is_ssl()`-based force-HTTPS redirect then saw "not secure" and
   redirected to `https://` again — Caddy → nginx → PHP → redirect → Caddy →
   ... forever. Fixed by adding a `map $http_x_forwarded_proto $fastcgi_https`
   + `fastcgi_param HTTPS $fastcgi_https` to both sites' `nginx.conf`. This
   would have caused a real outage on the actual VPS deploy if untested.

3. **`opcache` in `docker-php-ext-install` fails on PHP 8.5.** It ships
   built into the base image already; re-running the installer finds no
   module output and the whole `apt-get`/build layer fails. Removed from
   `startertheme.benoitchantre.com/Dockerfile.php` (opcache tuning still
   happens via the mounted `opcache.ini`, which works regardless).

4. **Caddy's healthcheck used `localhost`, which resolves to `::1` first**
   inside the container — but Caddy's admin API only binds `127.0.0.1`
   (IPv4). The healthcheck failed forever even though Caddy was serving
   traffic correctly the whole time. Fixed by using `127.0.0.1` explicitly
   in `caddy/docker-compose.yml`'s healthcheck.

## Verification performed

- Both sites reachable over HTTPS through Caddy with correct page content
  (`<title>` matches each site).
- `/xmlrpc.php` → 403 on both.
- `wp-login.php` → 200 (reachable) on both.
- A real migrated upload (`.webp` image) served with correct
  `Content-Type` and 200.
- Migrated `wp_users` row intact (admin login preserved).
- Migrated `active_plugins` option intact (all 10 original plugins present).
- `scripts/backup.sh` produces a valid gzip DB dump + tar of `data/`.
- `scripts/restore.sh` round-trip: restored the dump back in, site still
  returned 200 with the same post count (284) afterward.
- All 7 containers (`db`/`wp`/`web` × 2 sites + `caddy`) survive a full
  `docker restart` and both sites come back up without manual intervention
  (`restart: unless-stopped` verified).

## Tearing down

```bash
cd sites/benoitchantre.com && docker compose -f docker-compose.yml -f docker-compose.local.yml down
cd ../startertheme.benoitchantre.com && docker compose -f docker-compose.yml -f docker-compose.local.yml down
cd ../../caddy && docker compose -f docker-compose.yml -f docker-compose.local.yml down
```
Add `-v` to also drop the DB volumes if you want a truly clean slate before
the real deploy (the `data/` bind mounts and `_migration_dumps/` are
untouched either way — remove those manually if desired).

## Differences from the real VPS deploy

- Local uses `.test` domains (`benoitchantre.test`, `startertheme.test`)
  instead of the real TLDs, and each site's `docker-compose.local.yml`
  overlay + `nginx.local.conf` route accordingly. **Never point `/etc/hosts`
  at the real production domains** — see the "One-time setup" section above
  for why.
- Local uses `Caddyfile.local` (`tls internal`) instead of the real
  `Caddyfile` (Let's Encrypt) — the real deploy needs the production file,
  not this override.
- `startertheme.test`'s local `nginx.local.conf` drops the production
  IP-allowlist (`nginx.conf` restricts that site to a handful of real-world
  IPs) — it would otherwise 403 every local request.
- SMTP used dummy/local values — real credentials go in `.env` before the
  real deploy (see the "Email" section of `README.md`).
