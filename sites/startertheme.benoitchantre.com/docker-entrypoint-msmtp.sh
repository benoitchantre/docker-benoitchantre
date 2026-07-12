#!/bin/bash
# Substitutes SMTP_* env vars into /etc/msmtprc (msmtp has no native env-var
# expansion), tightens its permissions (it will contain a plaintext
# password), then hands off to php:fpm's default entrypoint.
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
chmod 600 /etc/msmtprc

exec docker-php-entrypoint "$@"
