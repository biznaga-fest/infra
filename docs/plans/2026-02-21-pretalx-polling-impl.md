# Pretalx Polling Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the webhook trigger in the n8n workflow with polling to pretalx REST API, and remove the unused webhook plugin from the Docker image.

**Architecture:** Two independent changes: (1) simplify Dockerfile by removing the webhook plugin, (2) rewrite the n8n workflow JSON to replace webhook+filter nodes with schedule trigger + polling + dedup nodes, keeping the rest of the pipeline intact.

**Tech Stack:** Docker, n8n workflow JSON, pretalx REST API, pretix REST API

---

### Task 1: Remove webhook plugin from Dockerfile

**Files:**
- Modify: `Dockerfile.pretalx`

**Step 1: Simplify the Dockerfile**

Replace the entire contents of `Dockerfile.pretalx` with:

```dockerfile
FROM pretalx/standalone:v2025.2.2
```

The `USER root`, `pip3 install`, and `USER pretalxuser` lines are all related to the webhook plugin and should be removed entirely.

**Step 2: Verify the Dockerfile is valid**

Run: `docker build --check -f Dockerfile.pretalx . 2>&1 || echo "docker not available, skipping validation"`
Expected: No syntax errors (or docker not available message).

**Step 3: Commit**

```bash
git add Dockerfile.pretalx
git commit -m "feat: remove pretalx webhook plugin from Docker image

Polling from n8n replaces the webhook trigger. The plugin only supported
schedule_release events, not submission confirmations."
```

---

### Task 2: Replace webhook trigger nodes with polling nodes in n8n workflow

This is the main task. We need to surgically modify `n8n-workflow.json` to:
- Remove 3 nodes: `Webhook - Pretalx` (id: node-webhook), `Respond 200 OK` (id: node-respond), `IF - Confirmed from Accepted` (id: node-filter)
- Add 3 new nodes: `Schedule Trigger`, `GET Confirmed Submissions`, `Code - Filter New Submissions`
- Remove connections from deleted nodes
- Add new connections for the new flow

**Files:**
- Modify: `n8n-workflow.json`

**Step 1: Remove the 3 old trigger nodes from the `nodes` array**

Remove these node objects from the `nodes` array:

1. The node with `"id": "node-webhook"` (name: "Webhook - Pretalx") — lines 4-18
2. The node with `"id": "node-respond"` (name: "Respond 200 OK") — lines 19-29
3. The node with `"id": "node-filter"` (name: "IF - Confirmed from Accepted") — lines 30-67

**Step 2: Add 3 new nodes at the beginning of the `nodes` array**

Insert these 3 nodes at the start of the `nodes` array (before `GET Submission Details`):

Node 1 — Schedule Trigger (every 5 minutes):
```json
{
  "parameters": {
    "rule": {
      "interval": [
        {
          "field": "minutes",
          "minutesInterval": 5
        }
      ]
    }
  },
  "id": "node-schedule",
  "name": "Schedule Trigger",
  "type": "n8n-nodes-base.scheduleTrigger",
  "typeVersion": 1.2,
  "position": [0, 0]
}
```

Node 2 — GET Confirmed Submissions (fetch all confirmed submissions from pretalx):
```json
{
  "parameters": {
    "method": "GET",
    "url": "=https://cfp.biznagafest.com/api/events/YOUR_PRETALX_EVENT_SLUG/submissions/?state=confirmed&limit=100",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "options": {
      "redirect": {
        "redirect": {
          "followRedirects": true
        }
      }
    }
  },
  "id": "node-get-confirmed",
  "name": "GET Confirmed Submissions",
  "type": "n8n-nodes-base.httpRequest",
  "typeVersion": 4.2,
  "position": [220, 0],
  "credentials": {
    "httpHeaderAuth": {
      "id": "PRETALX_CREDENTIAL_ID",
      "name": "pretalx API Token"
    }
  }
}
```

Node 3 — Code - Filter New Submissions (dedup via static data):
```json
{
  "parameters": {
    "jsCode": "// Dedup layer 1: filter out already-processed submissions using static data\nconst staticData = $getWorkflowStaticData('global');\nif (!staticData.processedCodes) {\n  staticData.processedCodes = [];\n}\n\nconst submissions = $input.first().json.results || [];\nconst newSubmissions = submissions.filter(\n  s => !staticData.processedCodes.includes(s.code)\n);\n\nif (newSubmissions.length === 0) {\n  return []; // Nothing new, stop execution\n}\n\n// Return one item per new submission with code and event slug\nreturn newSubmissions.map(s => ({\n  json: {\n    submission_code: s.code,\n    event_slug: s.event || 'YOUR_PRETALX_EVENT_SLUG'\n  }\n}));"
  },
  "id": "node-filter-new",
  "name": "Code - Filter New Submissions",
  "type": "n8n-nodes-base.code",
  "typeVersion": 2,
  "position": [440, 0]
}
```

**Step 3: Update the `GET Submission Details` node URL**

The current URL references `$('Webhook - Pretalx')` which no longer exists. Change the `url` field of node `node-get-submission` from:

```
={{ $('Webhook - Pretalx').item.json.body.pretalx_url || 'https://cfp.biznagafest.com' }}/api/events/{{ $json.event_slug || $json.submission.event }}/submissions/{{ $json.submission.code }}/?expand=speakers,track,submission_type,slots.room
```

To:

```
=https://cfp.biznagafest.com/api/events/{{ $json.event_slug }}/submissions/{{ $json.submission_code }}/?expand=speakers,track,submission_type,slots.room
```

**Step 4: Remove old connections and add new ones**

In the `connections` object:

Remove these connection entries entirely:
- `"Webhook - Pretalx"` (lines 415-430)
- `"IF - Confirmed from Accepted"` (lines 431-441)

Add these new connection entries:

```json
"Schedule Trigger": {
  "main": [
    [
      {
        "node": "GET Confirmed Submissions",
        "type": "main",
        "index": 0
      }
    ]
  ]
},
"GET Confirmed Submissions": {
  "main": [
    [
      {
        "node": "Code - Filter New Submissions",
        "type": "main",
        "index": 0
      }
    ]
  ]
},
"Code - Filter New Submissions": {
  "main": [
    [
      {
        "node": "GET Submission Details",
        "type": "main",
        "index": 0
      }
    ]
  ]
},
```

The `"GET Submission Details"` connection entry stays unchanged (it already connects to Telegram + Split by Speaker).

**Step 5: Verify the JSON is valid**

Run: `python3 -c "import json; json.load(open('n8n-workflow.json')); print('Valid JSON')" 2>&1`
Expected: `Valid JSON`

**Step 6: Commit**

```bash
git add n8n-workflow.json
git commit -m "feat(n8n): replace webhook trigger with polling to pretalx API

Adds Schedule Trigger (5 min) → GET confirmed submissions → filter new
via static data dedup. Removes Webhook, Respond, and IF nodes that
depended on the now-removed pretalx webhook plugin."
```

---

### Task 3: Add pretix order dedup check before order creation

**Files:**
- Modify: `n8n-workflow.json`

**Step 1: Add the pretix order check node**

Add this node to the `nodes` array (position it between Code - Merge Email and POST Create Pretix Order):

```json
{
  "parameters": {
    "method": "GET",
    "url": "=https://tickets.biznagafest.com/api/v1/organizers/YOUR_ORGANIZER_SLUG/events/YOUR_EVENT_SLUG/orders/?search={{ encodeURIComponent('Speaker entry - Auto-created from pretalx (' + $json.talk_code + ')') }}",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "options": {}
  },
  "id": "node-check-pretix-order",
  "name": "GET Check Existing Pretix Order",
  "type": "n8n-nodes-base.httpRequest",
  "typeVersion": 4.2,
  "position": [1430, 0],
  "credentials": {
    "httpHeaderAuth": {
      "id": "PRETIX_CREDENTIAL_ID",
      "name": "pretix API Token"
    }
  }
}
```

**Step 2: Add IF node to check if order already exists**

Add this node after the check:

```json
{
  "parameters": {
    "conditions": {
      "options": {
        "caseSensitive": true,
        "leftValue": "",
        "typeValidation": "strict"
      },
      "conditions": [
        {
          "id": "cond-no-existing-order",
          "leftValue": "={{ $json.count }}",
          "rightValue": 0,
          "operator": {
            "type": "number",
            "operation": "equals"
          }
        }
      ],
      "combinator": "and"
    },
    "options": {}
  },
  "id": "node-if-no-order",
  "name": "IF No Existing Order",
  "type": "n8n-nodes-base.if",
  "typeVersion": 2,
  "position": [1540, 0]
}
```

**Step 3: Shift the POST Create Pretix Order position**

Update the `position` of `node-create-order` (POST Create Pretix Order) from `[1540, 0]` to `[1650, 0]`.

Also shift all downstream node positions by +110 on the x-axis to make room:
- `node-save-order`: `[1760, 0]` → `[1870, 0]`
- `node-voucher-1`: `[1980, -100]` → `[2090, -100]`
- `node-voucher-2`: `[1980, 100]` → `[2090, 100]`
- `node-merge-vouchers`: `[2200, 0]` → `[2310, 0]`
- `node-send-email`: `[2420, 0]` → `[2530, 0]`
- `node-strapi-check`: `[2420, 300]` → `[2530, 300]`
- `node-strapi-if`: `[2640, 300]` → `[2750, 300]`
- `node-strapi-download-avatar`: `[2860, 300]` → `[2970, 300]`
- `node-strapi-prepare`: `[3080, 300]` → `[3190, 300]`
- `node-strapi-create`: `[3300, 300]` → `[3410, 300]`
- `node-strapi-error-format`: `[3520, 500]` → `[3630, 500]`
- `node-strapi-error-telegram`: `[3740, 500]` → `[3850, 500]`
- `node-strapi-error-stop`: `[3960, 500]` → `[4070, 500]`

**Step 4: Update connections for dedup flow**

Change the connection from `"Code - Merge Email"` to point to the new check node instead of directly to POST Create Pretix Order:

Replace:
```json
"Code - Merge Email": {
  "main": [
    [
      {
        "node": "POST Create Pretix Order",
        "type": "main",
        "index": 0
      }
    ]
  ]
},
```

With:
```json
"Code - Merge Email": {
  "main": [
    [
      {
        "node": "GET Check Existing Pretix Order",
        "type": "main",
        "index": 0
      }
    ]
  ]
},
"GET Check Existing Pretix Order": {
  "main": [
    [
      {
        "node": "IF No Existing Order",
        "type": "main",
        "index": 0
      }
    ]
  ]
},
"IF No Existing Order": {
  "main": [
    [
      {
        "node": "POST Create Pretix Order",
        "type": "main",
        "index": 0
      }
    ]
  ]
},
```

**Step 5: Verify JSON is valid**

Run: `python3 -c "import json; json.load(open('n8n-workflow.json')); print('Valid JSON')" 2>&1`
Expected: `Valid JSON`

**Step 6: Commit**

```bash
git add n8n-workflow.json
git commit -m "feat(n8n): add pretix order dedup check before order creation

Queries pretix for existing orders matching the submission code comment.
Skips order creation if speaker already has a ticket, preventing
duplicates on workflow re-runs or static data resets."
```

---

### Task 4: Add "Mark as Processed" node at end of pipeline

**Files:**
- Modify: `n8n-workflow.json`

**Step 1: Add the Mark as Processed node**

Add this node to the `nodes` array. Position it after the email send node:

```json
{
  "parameters": {
    "jsCode": "// Mark this submission as processed in static data\nconst staticData = $getWorkflowStaticData('global');\nif (!staticData.processedCodes) {\n  staticData.processedCodes = [];\n}\n\n// Get the submission code from earlier in the pipeline\nconst talkCode = $json.talk_code || $('Code - Filter New Submissions').first().json.submission_code;\n\nif (talkCode && !staticData.processedCodes.includes(talkCode)) {\n  staticData.processedCodes.push(talkCode);\n}\n\nreturn [{ json: { marked: talkCode, total_processed: staticData.processedCodes.length } }];"
  },
  "id": "node-mark-processed",
  "name": "Code - Mark as Processed",
  "type": "n8n-nodes-base.code",
  "typeVersion": 2,
  "position": [2750, 0]
}
```

**Step 2: Connect email send to the mark-as-processed node**

The `POST Send Email via Resend` node currently has no downstream connection in the main pipeline. Add this connection:

```json
"POST Send Email via Resend": {
  "main": [
    [
      {
        "node": "Code - Mark as Processed",
        "type": "main",
        "index": 0
      }
    ]
  ]
},
```

**Step 3: Verify JSON is valid**

Run: `python3 -c "import json; json.load(open('n8n-workflow.json')); print('Valid JSON')" 2>&1`
Expected: `Valid JSON`

**Step 4: Commit**

```bash
git add n8n-workflow.json
git commit -m "feat(n8n): add mark-as-processed node after email send

Saves submission code to workflow static data after the full pipeline
completes. Failed executions will be retried on next poll cycle."
```

---

### Task 5: Update workflow notes and setup documentation

**Files:**
- Modify: `n8n-workflow.json`

**Step 1: Update the `notes` field**

Replace the current `notes` string with:

```
SETUP REQUIRED: Before activating this workflow, configure these values in n8n credentials and node settings:\n\n1. PRETALX_CREDENTIAL_ID - Create HTTP Header Auth credential with pretalx API token (Header Name: Authorization, Header Value: Token YOUR_PRETALX_TOKEN)\n2. PRETIX_CREDENTIAL_ID - Create HTTP Header Auth credential with pretix API token (Header Name: Authorization, Header Value: Token YOUR_PRETIX_TOKEN)\n3. RESEND_CREDENTIAL_ID - Create HTTP Header Auth credential with Resend API key (Header Name: Authorization, Header Value: Bearer YOUR_RESEND_KEY)\n4. STRAPI_CREDENTIAL_ID - Create HTTP Header Auth credential with Strapi API token (Header Name: Authorization, Header Value: Bearer YOUR_STRAPI_TOKEN)\n5. YOUR_PRETALX_EVENT_SLUG - Replace in nodes: GET Confirmed Submissions, Code - Filter New Submissions\n6. YOUR_ORGANIZER_SLUG - Replace in nodes: POST Create Pretix Order, POST Create Voucher 1/2, Code - Save Order Data, Code - Merge Vouchers, GET Check Existing Pretix Order\n7. YOUR_EVENT_SLUG - Replace in same nodes as above (this is the pretix event slug)\n8. YOUR_SPEAKER_ITEM_ID - Pretix item ID for speaker tickets (POST Create Pretix Order)\n9. YOUR_GUEST_ITEM_ID - Pretix item ID for guest vouchers (POST Create Voucher 1/2)\n10. YOUR_TELEGRAM_CHAT_ID - Telegram group/channel ID for notifications\n11. YOUR_BOT_TOKEN - Telegram bot token (or set in n8n credentials as telegramBotToken)\n\nTRIGGER: This workflow polls pretalx every 5 minutes for confirmed submissions.\nDEDUP: Double-layer - static data cache + pretix order existence check.\nRETRY: Failed submissions are retried on next poll (not marked as processed until email is sent).
```

**Step 2: Verify JSON is valid**

Run: `python3 -c "import json; json.load(open('n8n-workflow.json')); print('Valid JSON')" 2>&1`
Expected: `Valid JSON`

**Step 3: Commit**

```bash
git add n8n-workflow.json
git commit -m "docs(n8n): update workflow notes for polling trigger setup

Adds YOUR_PRETALX_EVENT_SLUG placeholder, documents the polling trigger,
dedup strategy, and retry behavior."
```
