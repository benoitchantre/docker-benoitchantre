#!/bin/bash
# Wraps the official WordPress entrypoint: substitutes SMTP_* env vars into
# /etc/msmtprc (msmtp has no native env-var expansion), tightens its
# permissions (it will contain a plaintext password), then hands off.
set -euo pipefail

: "${SMTP_HOST:?SMTP_HOST is required}"
: "${SMTP_PORT:=587}"
: "${SMTP_USER:?SMTP_USER is required}"
: "${SMTP_PASSWORD:?SMTP_PASSWORD is required}"
: "${SMTP_FROM:?SMTP_FROM is required}"

sed -e "s/__SMTP_HOST__/${SMTP_HOST}/" \
    -e "s/__SMTP_PORT__/${SMTP_PORT}/" \
    -e "s/__SMTP_USER__/${SMTP_USER}/" \
    -e "s/__SMTP_PASSWORD__/${SMTP_PASSWORD}/" \
    -e "s/__SMTP_FROM__/${SMTP_FROM}/" \
    /etc/msmtprc.template > /etc/msmtprc
# php-fpm workers run as www-data, not root — msmtp is invoked from PHP's
# sendmail_path in that worker context, so the config (and its logfile)
# must be writable by www-data, not just root.
chown www-data:www-data /etc/msmtprc
chmod 600 /etc/msmtprc
touch /var/log/msmtp.log
chown www-data:www-data /var/log/msmtp.log

exec docker-entrypoint.sh "$@"
