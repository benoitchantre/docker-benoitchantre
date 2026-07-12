# Official WordPress php-fpm image (Alpine variant — ~150MB smaller than
# Debian, meaningful on a 1 vCPU/2GB VPS running two full site stacks) +
# msmtp, so wp_mail()/PHP mail() can relay outbound email through a real
# SMTP provider instead of trying (and failing/landing in spam) to send
# directly from the VPS IP.
#
# Also includes wp-cli, since DISABLE_WP_CRON is set (WordPress's own
# page-load-triggered pseudo-cron is unreliable on low-traffic sites) — a
# host crontab runs `docker exec <container> wp cron event run --due-now`
# every 5 minutes instead. See infra/scripts/wp-cron.sh.
FROM wordpress:php8.5-fpm-alpine

RUN apk add --no-cache msmtp ca-certificates curl less \
    && curl -o /usr/local/bin/wp -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp

# Template, not the live config: docker-entrypoint-msmtp.sh substitutes
# SMTP_* env vars into /etc/msmtprc (with 600 perms) at container start,
# since the real file will contain a plaintext password.
COPY msmtprc /etc/msmtprc.template
COPY docker-entrypoint-msmtp.sh /usr/local/bin/docker-entrypoint-msmtp.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-msmtp.sh

ENTRYPOINT ["docker-entrypoint-msmtp.sh"]
CMD ["php-fpm"]
