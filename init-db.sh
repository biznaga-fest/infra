#!/bin/bash
set -e
set -u

# This script runs on first PostgreSQL startup only.
# It creates additional databases for pretalx and n8n.
# The 'pretix' database is created automatically by POSTGRES_DB env var.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    CREATE USER pretalx_user WITH PASSWORD '${PRETALX_DB_PASSWORD}';
    CREATE DATABASE pretalx OWNER pretalx_user;
    GRANT ALL PRIVILEGES ON DATABASE pretalx TO pretalx_user;

    CREATE USER n8n WITH PASSWORD '${N8N_DB_PASSWORD}';
    CREATE DATABASE n8n OWNER n8n;
    GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
EOSQL
