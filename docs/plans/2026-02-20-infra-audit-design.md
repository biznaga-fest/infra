# BiznagaFest Infra Audit - Design Document

**Date:** 2026-02-20
**Status:** Approved

## Context

BiznagaFest infrastructure repo with 3 Docker services (pretix, pretalx, n8n) deployed via Coolify. PostgreSQL, Redis and Strapi are managed externally by Coolify. An n8n workflow automates the speaker pipeline (pretalx -> pretix -> Strapi -> email/Telegram).

## Findings

### CRITICAL

1. **No `.gitignore`** - `.env` with secrets could be committed accidentally. No exclusion for `.claude/`, IDE files, etc.
2. **Uncommitted changes out of sync** - `.env.example` has staged changes (POSTGRES_PASSWORD -> PRETIX_DB_PASSWORD, added Strapi vars), `docker-compose.yml` has the same rename unstaged. Must be committed together.

### HIGH

3. **`version: "3.8"` obsolete** - Docker Compose V2 ignores this directive. Remove it.
4. **No `.dockerignore`** - `Dockerfile.pretalx` uses `context: .`, sending entire repo (including `.env`, `.git/`) as build context.
5. **Dockerfile pins to `@main` branch** - `pip3 install "git+...@main"` makes builds non-reproducible.

### MEDIUM

6. **n8n workflow full of hardcoded placeholders** - 10+ `YOUR_*` placeholders. URLs hardcoded instead of using n8n variables/credentials.
7. **Voucher 2 connection broken** - Only Voucher 1 connects to "Code - Merge Vouchers". Voucher 2 output is lost.
8. **Fragile event slug extraction** - `$json.talk_code.split('-')[0]` assumes talk code format. Should pass event_slug explicitly.

### LOW

9. **No healthcheck for external dependencies** - Services depend on PG/Redis but no wait logic beyond `restart: unless-stopped`.
10. **No resource limits** - No `mem_limit`/`cpus` on any service.

## Decisions

- Fix all CRITICAL and HIGH issues.
- Fix MEDIUM issues in n8n workflow (placeholders are documentation, voucher connection is a bug, event slug is fragile).
- LOW issues are optional improvements - include if straightforward.
- Pin Dockerfile plugin to latest commit SHA at time of fix.
- `.gitignore` follows standard Docker/Node patterns.
