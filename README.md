# WordPress on Docker — infrastructure runbook

Two personal WordPress sites (`benoitchantre.com`, `startertheme.benoitchantre.com`)
running as isolated Docker Compose stacks behind a shared Caddy reverse proxy,
on a 1 vCPU / 2 GB Debian 13 VPS. See `/Users/benoit/.claude/plans/i-have-a-small-soft-milner.md`
for the full design rationale.

## Layout

```
host/bootstrap.sh          # one-time new-VPS setup (Phase 0 + 0.5)
caddy/                     # shared reverse proxy, auto-HTTPS
sites/
├── benoitchantre.com/               # classic WP layout
└── startertheme.benoitchantre.com/  # Bedrock-style layout
scripts/backup.sh, restore.sh
start.sh                   # bring up everything (or specific sites), in order
stop.sh                    # stop everything (or specific sites); --down / --volumes for more
```

This repo *is* what gets deployed to the VPS — there's no `infra/` wrapper
directory; everything below lives at repo root on both your machine and the
server.

Each site stack is fully independent: its own MariaDB, its own PHP-FPM +
nginx, its own `.env`. Only the `web` (nginx) container per site joins the
shared `web` Docker network that Caddy also sits on — databases are never
reachable from outside their own stack.

## First deploy, in order

1. **Provision the VPS** (Debian 13, 1 vCPU / 2 GB) and point DNS's `A`
   records at it — but keep Cloudflare in **DNS-only / grey-cloud** mode so
   Caddy can complete the Let's Encrypt HTTP-01 challenge directly.
2. **Bootstrap the host:**
   ```bash
   scp host/bootstrap.sh root@NEW_IP:/root/
   ssh root@NEW_IP bash /root/bootstrap.sh
   ```
   Some VPS providers (e.g. this one) don't expose root SSH at all — they
   provision a pre-existing sudo user instead (here, `debian`, with
   passwordless `sudo`). In that case, adjust:
   ```bash
   scp host/bootstrap.sh debian@NEW_IP:/home/debian/
   ssh debian@NEW_IP sudo bash /home/debian/bootstrap.sh
   ```
   The script's "create a non-root sudo user" step (step 2 inside the
   script) assumes it's starting from root and copies
   `/root/.ssh/authorized_keys` into the new account — when starting from an
   existing sudo user like `debian` instead, that step is redundant and can
   be skipped; just keep using that account.
   Follow the manual steps it prints at the end (verify SSH key login before
   disabling password auth).
3. **Copy this repo** to the new VPS (e.g. `rsync -av ./
   user@NEW_IP:~/docker-benoitchantre/`), or `git clone` it if you've pushed
   it to a repo.
4. **Migrate each site's data** before starting its stack:
   - `benoitchantre.com`: copy `wp-content/` into
     `sites/benoitchantre.com/wp-content/`, import the DB dump
     into the `db` container once it's up, fill in `.env` (copy from
     `.env.example`, preserve `WP_TABLE_PREFIX=wp_9b3iDK4g_`).
   - `startertheme.benoitchantre.com`: its Bedrock-style layout needs a
     slightly different file-copy process — see `README.local.md` for the
     `rsync`/`mysqldump` commands used to pull data from the old VPS.
5. **Bring up each site:**
   ```bash
   cd sites/benoitchantre.com && cp .env.example .env
   # fill in real DB passwords, then: chmod 600 .env
   docker compose up -d
   ```
   Repeat for the other site.
6. **Sanity-check the Caddyfile before (re)loading it**, any time you edit
   it: `docker exec caddy caddy validate --config /etc/caddy/Caddyfile`.
7. **Verify over HTTPS before cutting DNS** — see the Verification section
   of the plan file. Use a local `/etc/hosts` override pointing the real
   domain at the new VPS IP so you can test with a trusted cert.
8. **Cut DNS**, wait for propagation, confirm both sites live, then leave the
   old VPS untouched for 1–2 weeks as a rollback.

## Adding a new site later

1. `cp -r sites/benoitchantre.com sites/newsite.example.com` as a starting
   template (it's the simpler, "classic layout" shape).
2. Update `container_name`s (must be unique host-wide), `.env`, `nginx.conf`
   `server_name`.
3. Add a new site block to `caddy/Caddyfile` pointing
   `reverse_proxy` at the new `web` container name.
4. `docker compose up -d` the new stack, reload Caddy
   (`docker exec caddy caddy reload --config /etc/caddy/Caddyfile`).

## Deploying changes / git on the VPS

The VPS checkout is owned by the deploy user (`debian`), **not root** — plain
`git pull` works with no `sudo`. Two things to avoid:

- **Never run git as root** (`sudo git pull`, `sudo git reset`, etc.) on this
  checkout. Every file git writes ends up owned by whoever ran the command —
  a root `git pull` silently flips tracked files back to `root:root`,
  including the two files that live inside a site's `wp-content/`
  (`wp-content/mu-plugins/configure-email.php` on each site), which need to
  stay owned by uid 82 (`www-data`, the php-fpm worker user) or WordPress
  can't read/write around them correctly. If that ever happens again:
  ```bash
  sudo chown 82:82 sites/*/wp-content/mu-plugins/configure-email.php
  ```
- **Never run `git reset --hard`** on the VPS checkout — it silently
  discards any uncommitted local changes (including one-off hotfixes made
  directly on the server that haven't been committed/pushed yet). Use plain
  `git pull`; if it refuses due to local changes, look at what's different
  before discarding anything.

More broadly: `wp-content/` itself **and everything under it** should be
owned by uid 82, not `debian` — that's the directory WordPress/php-fpm
actually writes into (uploads, cache, `upgrade-temp-backup/`, etc.), and
anything left `debian`-owned there (e.g. from a raw `scp`/`rsync` transfer
during migration, or from a `mv`/rename that leaves the directory itself at
its old ownership even after its contents are fixed) will show up as
WordPress site-health write-permission errors, or as a surprise FTP/SSH
credentials prompt when deleting/installing a plugin from wp-admin (that
prompt means `get_filesystem_method()` fell back from `direct` because the
direct-write check failed — almost always this). Check **the directory
itself**, not just its contents:
```bash
stat -c "%u:%g %n" sites/<site>/wp-content
find sites/<site>/wp-content -not -uid 82
```
and fix with `sudo chown -R 82:82 sites/<site>/wp-content` if anything
shows up (safe to run any time — it only touches ownership, not content).

## Day-to-day operations

**Start / stop everything** (or specific sites), in the right order:
```bash
./start.sh                        # network/volume + Caddy + all sites
./start.sh benoitchantre.com      # shared infra + just this site
./stop.sh                         # stop containers (fast to start.sh again)
./stop.sh benoitchantre.com       # stop just one site, leave Caddy/other sites up
./stop.sh --down                  # stop + remove containers/networks (DB volumes kept)
./stop.sh --down --volumes        # also DELETE named volumes — destructive, asks to confirm per service
```
`start.sh` assumes each site's database already has data (fresh install or
prior migration) — it does not import dumps. Caddy failures are reported but
don't block bringing the sites back up.

**Logs:**
```bash
# WordPress/PHP (app errors, warnings):
docker logs -f benoit_wp
docker logs -f startertheme_wp

# nginx (per-site HTTP requests/errors):
docker logs -f benoit_web

# Caddy (shared edge — every request across all sites, access + TLS):
docker logs -f caddy
docker exec caddy tail -f /data/logs/benoitchantre.com.log   # per-site JSON access log
```

**WordPress cron:** `DISABLE_WP_CRON` is set on both sites — WordPress's
default pseudo-cron only fires on page loads, which is unreliable on
low-traffic personal sites (scheduled posts, backups, plugin maintenance can
lag for hours). A host crontab runs the real thing every 5 minutes instead:
```bash
./scripts/wp-cron.sh                     # all sites
./scripts/wp-cron.sh benoitchantre.com   # one site
```
Crontab (every 5 minutes, as the deploy user):
```
*/5 * * * * cd /home/benoit/docker-benoitchantre && ./scripts/wp-cron.sh >> /home/benoit/docker-benoitchantre/wp-cron.log 2>&1
```
Both site images include `wp-cli` for this (see `Dockerfile.php` in each
site). Safe to run even if a container isn't up yet (skips with a warning).

**Backups** (manual run or via cron):
```bash
./scripts/backup.sh                    # all sites
./scripts/backup.sh benoitchantre.com  # one site
```
Cron (daily at 02:00, as the deploy user):
```
0 2 * * * cd /home/benoit/docker-benoitchantre/scripts && ./backup.sh >> /home/benoit/docker-benoitchantre/backups/backup.log 2>&1
```

**Restore:**
```bash
./scripts/restore.sh benoitchantre.com backups/benoitchantre.com/benoitchantre.com-db-<ts>.sql.gz
```
Prompts for confirmation before overwriting the live DB. Test restores into a
scratch environment periodically, not just when disaster strikes.

**Updating an image** (e.g. bump WordPress/PHP/MariaDB version):
```bash
cd sites/benoitchantre.com
docker compose pull
docker compose up -d
```
Take a backup first. Since `PHP 8.5` is new, if a plugin breaks, the fallback
is a one-line change: edit the `image:` tag (or `Dockerfile.php` FROM line
for the Bedrock site) to `php8.4-fpm` / `php:8.4-fpm`, rebuild, and restart.

**WordPress auto-updates:** core minor/security releases and configured
plugins update themselves in place (writes land on the bind-mounted
`wp-content`/`public/wp-content`) — no container rebuild needed for those.
Major WP/PHP version bumps are deliberately manual (image tag change) so
they're never a surprise.

## Keeping things patched

Patching happens on **three separate lanes** — the common mistake is assuming
host patches cover the sites. They don't: your WordPress/PHP/nginx/MariaDB run
in containers with their own libraries baked into the images, so a host
openssl patch does *not* fix openssl inside `benoit_wp`.

**Lane 1 — host reboot (kernel updates).** `unattended-upgrades` installs the
patches; a kernel update only takes effect after a reboot. `bootstrap.sh`
configures an automatic reboot at 04:00 *only when one is actually pending*
(`/etc/apt/apt.conf.d/51unattended-reboot`), so most nights it's a no-op. To
check by hand whether a reboot is queued:
```bash
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs
```
The OS drops that file when a reboot is needed — that's the signal, you don't
have to guess.

**Lane 2 — host service restart (shared-library updates).** When a patch
updates a shared library (openssl, glibc, ...), the fix isn't live until every
process that loaded the old copy restarts — usually a service restart, not a
full reboot. `needrestart` (installed by `bootstrap.sh`, configured to restart
automatically — `$nrconf{restart} = 'a'` in
`/etc/needrestart/conf.d/50-autorestart.conf`) detects these and restarts them
after apt runs, no prompt. Check manually with:
```bash
sudo needrestart
```

**Lane 3 — container images (what your sites actually run on).** This is the
one nothing automates — see "Updating an image" above. Host patching never
touches the PHP/WordPress/nginx/MariaDB inside the containers. Pull rebuilt
images deliberately (take a backup first):
```bash
./scripts/backup.sh
cd sites/benoitchantre.com && docker compose pull && docker compose up -d --build
# For the Bedrock site's apt layer (gd, mysqli, ...), occasionally rebuild
# without cache so those packages refresh too, not just the base image:
cd ../startertheme.benoitchantre.com && docker compose build --no-cache wp && docker compose up -d
```
`php8.5-fpm` / `wordpress:php8.5-fpm` are floating tags — `pull` picks up new
PHP 8.5 patch releases when Docker Hub rebuilds them. A monthly reminder to do
this is the recommended cadence; keep it manual (you're present to eyeball the
sites afterward) until you have a reason to automate it. Major PHP/WP bumps
(8.5 → 8.6) stay deliberately manual — see "Updating an image".

**Don't add a blanket scheduled reboot** (e.g. weekly cron): it costs
availability for no benefit on most nights. The conditional 04:00 reboot above
is the right version — it reboots only when the OS says one is required.

## Email

WordPress needs outbound email for password resets, notifications, etc.
Sending directly from a VPS IP gets filtered/blocked by major providers, so
each site's PHP image relays through **msmtp** to a real SMTP account (set
`SMTP_HOST`/`SMTP_USER`/`SMTP_PASSWORD`/`SMTP_FROM` in that site's `.env`).
msmtp is a small, focused sendmail-replacement — no inbound mail handling,
no local MTA to maintain, just a relay client. `sendmail_path` in each
site's `uploads.ini` points PHP at it.

## Security posture summary

- Only Caddy publishes ports (80/443); every DB is unreachable from outside
  its own stack.
- Non-root containers, dropped Linux capabilities, `no-new-privileges`,
  per-container memory/PID caps.
- `/xmlrpc.php` blocked at the edge (Caddy) and again at nginx (defense in
  depth).
- Secrets in `chmod 600`, git-ignored `.env` files — never commit real
  credentials; `.env.example` files are the committed templates.
- `unattended-upgrades` patches the host OS; WordPress patches itself for
  core/plugin security releases.
- Sensitive/metadata files (`wp-cli.yml`, `composer.json`/`.lock`,
  `package.json`/`.lock`, `.git`, editor swap/backup files) blocked at
  Caddy and again at nginx.
- **`startertheme.benoitchantre.com` is IP-allowlisted end to end**
  (ported from the original VPS's nginx vhost) — `deny all` at the nginx
  `server` level, applied before any location block so it covers PHP
  requests too, not just static files. Allowed IPs live in that site's
  `nginx.conf`. **If this site suddenly 403s for a legitimate visitor,
  check that file before assuming something else broke** — this is
  intentional access control, not a bug.

## Known constraints (by design)

- **1 vCPU / 2 GB RAM total** — 2 GB swap is provisioned, per-container
  memory limits keep any one stack from starving the others, and the Surge
  full-page cache plugin is what makes this workable (most requests never
  touch PHP/MySQL). If it ever feels tight, resizing the VPS is the easy
  lever — no architecture change needed.
- **PHP 8.5 on both sites** — newer than most WP installs run; watch for
  plugin incompatibilities post-migration (see verification checklist in the
  plan file) and fall back to 8.4 per-site if needed.
- Redis object cache, offsite backup shipping, and re-enabling Cloudflare's
  proxied mode are intentionally out of scope for this first pass — see the
  plan file's "Explicitly out of scope" section for the reasoning.
