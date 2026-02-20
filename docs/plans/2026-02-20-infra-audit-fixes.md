# BiznagaFest Infra Audit Fixes - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all CRITICAL, HIGH, and MEDIUM issues found in the infrastructure audit.

**Architecture:** Config-only changes across Docker, git, and n8n workflow files. No application code. Each task is an independent fix committed separately.

**Tech Stack:** Docker Compose, Dockerfile, git, n8n workflow JSON

---

### Task 1: Create `.gitignore`

**Files:**
- Create: `.gitignore`

**Step 1: Create the `.gitignore` file**

```
# Environment secrets
.env

# Claude Code
.claude/

# IDE
.idea/
.vscode/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db

# Docker
docker-compose.override.yml
```

**Step 2: Verify `.env` is now ignored**

Run: `git status`
Expected: `.env` should NOT appear in untracked files. `.gitignore` should appear as new file.

**Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: add .gitignore to protect secrets and exclude IDE files"
```

---

### Task 2: Commit the pending synchronized changes

**Context:** `.env.example` has staged changes (POSTGRES_PASSWORD -> PRETIX_DB_PASSWORD, added Strapi vars). `docker-compose.yml` has the same rename as unstaged. They must be committed together.

**Step 1: Stage the unstaged docker-compose change**

Run: `git add docker-compose.yml`

**Step 2: Verify both files are staged together**

Run: `git diff --cached --stat`
Expected: Both `.env.example` and `docker-compose.yml` appear as staged.

**Step 3: Commit**

```bash
git commit -m "fix: rename POSTGRES_PASSWORD to PRETIX_DB_PASSWORD and add Strapi env vars

Syncs .env.example and docker-compose.yml to use per-service DB password
naming. Adds STRAPI_URL and STRAPI_API_TOKEN to .env.example for the
externally-managed Strapi CMS."
```

---

### Task 3: Remove obsolete `version` directive from docker-compose

**Files:**
- Modify: `docker-compose.yml:1-2`

**Step 1: Remove the `version: "3.8"` line and trailing blank line**

In `docker-compose.yml`, delete lines 1-2:
```
version: "3.8"

```

The file should now start with `services:`.

**Step 2: Validate compose syntax**

Run: `docker compose config --quiet 2>&1 || echo "WARN: docker compose not available, skip validation"`
Expected: No errors (or warning if docker not installed locally).

**Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "chore: remove obsolete version directive from docker-compose

Docker Compose V2 ignores this field. Removing reduces confusion."
```

---

### Task 4: Create `.dockerignore`

**Files:**
- Create: `.dockerignore`

**Step 1: Create the `.dockerignore` file**

```
.env
.env.example
.git
.gitignore
.dockerignore
.claude
docs
n8n-workflow.json
*.md
```

**Step 2: Commit**

```bash
git add .dockerignore
git commit -m "chore: add .dockerignore to exclude secrets and unnecessary files from build context"
```

---

### Task 5: Pin Dockerfile.pretalx plugin to specific commit

**Files:**
- Modify: `Dockerfile.pretalx:5-6`

**Step 1: Replace `@main` with the pinned commit SHA**

Change line 6 of `Dockerfile.pretalx` from:
```dockerfile
    "git+https://github.com/efdevcon/pretalx-webhook-plugin.git@main#egg=pretalx-webhook-plugin"
```

To:
```dockerfile
    "git+https://github.com/efdevcon/pretalx-webhook-plugin.git@21a8d2e5688df8f1a6e2791382d7e6bad1f1ac9f#egg=pretalx-webhook-plugin"
```

**Step 2: Commit**

```bash
git add Dockerfile.pretalx
git commit -m "fix: pin pretalx-webhook-plugin to commit SHA for reproducible builds

Pinned to 21a8d2e (latest main as of 2026-02-20). Avoids silent breakage
when upstream main changes."
```

---

### Task 6: Fix n8n workflow - add event_slug to Split by Speaker output

**Files:**
- Modify: `n8n-workflow.json` — node `node-split-speakers` (lines 109-117)

**Context:** The "GET Speaker Email" node uses `$json.talk_code.split('-')[0]` to guess the event slug. This is fragile. The fix is to pass `event_slug` explicitly from the "Code - Split by Speaker" node, which has access to the submission's event field.

**Step 1: Update the jsCode in `node-split-speakers`**

In the `jsCode` field of node `node-split-speakers`, add `event_slug` to the speaker output object. Add this line after `speaker_count`:

```javascript
  // Event slug for downstream API calls
  event_slug: submission.event || submission.slot?.event || 'biznagafest-2026',
```

The full speakers.map should produce objects with `event_slug` as a field.

**Step 2: Update the URL in `node-get-speaker-email`**

Change the `url` field of node `node-get-speaker-email` (line 121) from:
```
=https://cfp.biznagafest.com/api/events/{{ $json.talk_code.split('-')[0] || 'biznagafest-2026' }}/speakers/{{ $json.speaker_code }}/
```

To:
```
=https://cfp.biznagafest.com/api/events/{{ $json.event_slug }}/speakers/{{ $json.speaker_code }}/
```

**Step 3: Commit**

```bash
git add n8n-workflow.json
git commit -m "fix(n8n): pass event_slug explicitly instead of parsing talk code

Extracts event_slug from submission data in Split by Speaker node.
Removes fragile talk_code.split('-')[0] hack in GET Speaker Email."
```

---

### Task 7: Fix n8n workflow - add Voucher 2 connection to Merge Vouchers

**Files:**
- Modify: `n8n-workflow.json` — `connections` section (around line 517-527)

**Context:** Currently only "POST Create Voucher 1" connects to "Code - Merge Vouchers". "POST Create Voucher 2" has no output connection, so its result is silently lost.

**Step 1: Add the missing connection**

In the `connections` object, after the `"POST Create Voucher 1"` entry (lines 517-527), add:

```json
    "POST Create Voucher 2": {
      "main": [
        [
          {
            "node": "Code - Merge Vouchers",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
```

**Step 2: Commit**

```bash
git add n8n-workflow.json
git commit -m "fix(n8n): connect Voucher 2 output to Merge Vouchers node

Voucher 2 result was silently lost. Both voucher nodes now feed into
the merge step."
```

---

### Task 8: Add placeholder documentation comments to n8n workflow

**Files:**
- Modify: `n8n-workflow.json` — add a `notes` field at top level

**Context:** The workflow has 10+ `YOUR_*` placeholders that need to be configured in n8n. Rather than changing the JSON structure, add a top-level `notes` field documenting what needs to be configured.

**Step 1: Add notes field to the workflow JSON**

Add this field at the top level of the JSON object (after `"name"`):

```json
"notes": "SETUP REQUIRED: Before activating this workflow, configure these values in n8n credentials and node settings:\n\n1. PRETALX_CREDENTIAL_ID - Create HTTP Header Auth credential with pretalx API token\n2. PRETIX_CREDENTIAL_ID - Create HTTP Header Auth credential with pretix API token\n3. RESEND_CREDENTIAL_ID - Create HTTP Header Auth credential with Resend API key\n4. STRAPI_CREDENTIAL_ID - Create HTTP Header Auth credential with Strapi API token\n5. YOUR_ORGANIZER_SLUG - Replace in nodes: POST Create Pretix Order, POST Create Voucher 1/2, Code - Save Order Data, Code - Merge Vouchers\n6. YOUR_EVENT_SLUG - Replace in same nodes as above\n7. YOUR_SPEAKER_ITEM_ID - Pretix item ID for speaker tickets (POST Create Pretix Order)\n8. YOUR_GUEST_ITEM_ID - Pretix item ID for guest vouchers (POST Create Voucher 1/2)\n9. YOUR_TELEGRAM_CHAT_ID - Telegram group/channel ID for notifications\n10. YOUR_BOT_TOKEN - Telegram bot token (or set in n8n credentials as telegramBotToken)",
```

**Step 2: Commit**

```bash
git add n8n-workflow.json
git commit -m "docs(n8n): add setup notes documenting all required placeholder values"
```
