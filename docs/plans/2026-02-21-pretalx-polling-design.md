# Pretalx Polling from n8n - Design Document

**Date:** 2026-02-21
**Status:** Approved

## Context

The current n8n workflow (`n8n-workflow.json`) triggers on a webhook POST from pretalx when a submission is confirmed. However, the pretalx webhook plugin (`efdevcon/pretalx-webhook-plugin`) only supports the `schedule_release` signal — it does NOT fire on individual submission confirmations. Plugin configuration also requires a `.cfg` file (no env var support), adding deployment complexity.

The solution is to replace the webhook trigger with polling from n8n to the pretalx REST API.

## Decisions

- **Polling frequency:** Every 5 minutes
- **Dedup strategy:** Double layer — n8n static data (fast cache) + pretix order check (robust fallback)
- **Webhook plugin:** Remove from Dockerfile (no longer needed)
- **Pipeline scope:** Identical to current — Telegram notification, pretix order + vouchers, email, Strapi speaker creation

## Design

### Trigger Change

Replace `Webhook - Pretalx` + `Respond 200 OK` + `IF - Confirmed from Accepted` with:

1. **Schedule Trigger** — fires every 5 minutes
2. **GET Confirmed Submissions** — calls `GET /api/events/{event}/submissions/?state=confirmed` with pretalx API auth
3. **Code - Filter New Submissions** — reads `$getWorkflowStaticData('global').processedCodes` (a Set of submission codes already processed). Returns only submissions whose code is NOT in the set.
4. **Split Items** — one execution per new confirmed submission

### Dedup Layer 1: Static Data

The `Code - Filter New Submissions` node:
- Reads `staticData.processedCodes` (array of strings)
- Filters out any submission whose `code` is already in the array
- Returns only genuinely new submissions

At the end of the pipeline (after all actions succeed), a `Code - Mark as Processed` node:
- Pushes the submission code into `staticData.processedCodes`
- This ensures failed executions are retried on next poll

### Dedup Layer 2: Pretix Order Check

Before creating the pretix order, query:
```
GET /api/v1/organizers/{org}/events/{event}/orders/?search=Speaker+entry+-+Auto-created+from+pretalx+({submission_code})
```

If results > 0, skip order creation (and downstream vouchers/email) for that speaker.

### Pipeline (unchanged from current)

```
GET Submission Details (?expand=speakers,track,submission_type,slots.room)
  ├→ Telegram - Announce Talk
  └→ Code - Split by Speaker
       → GET Speaker Email
       → Code - Merge Email
       → POST Create Pretix Order  ← (with dedup check before)
       → Code - Save Order Data
       ├→ POST Create Voucher 1
       └→ POST Create Voucher 2
           → Code - Merge Vouchers
           ├→ POST Send Email via Resend
           └→ GET Check Speaker in Strapi → IF Not Exists → Create in Strapi
```

### Dockerfile Change

Remove the webhook plugin installation:

```dockerfile
FROM pretalx/standalone:v2025.2.2
# Plugin removed — polling replaces webhook trigger
```

### Configuration

The polling workflow needs:
- **Event slug** — configured in the first Code node or as a workflow variable
- **Pretalx API token** — existing HTTP Header Auth credential in n8n

### Node Changes Summary

| Current Node | Action |
|---|---|
| `Webhook - Pretalx` | Delete → replace with Schedule Trigger (5 min) |
| `Respond 200 OK` | Delete |
| `IF - Confirmed from Accepted` | Delete |
| New: `GET Confirmed Submissions` | HTTP Request to pretalx API |
| New: `Code - Filter New Submissions` | Static data dedup |
| New: `Code - Mark as Processed` | Save code to static data after success |
| New: pretix order check | HTTP Request before POST Create Pretix Order |
| All other nodes | Unchanged |
