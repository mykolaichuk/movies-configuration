#!/bin/sh
# Managed by Ansible (movies-configuration/roles/certbot).
# Deploy hook: nginx picks up the renewed certificate without dropping connections.
set -e
nginx -t -q
systemctl reload nginx
