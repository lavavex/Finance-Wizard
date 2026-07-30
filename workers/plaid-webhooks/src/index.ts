/**
 * Plaid webhook receiver (Cloudflare Worker).
 *
 * Configure in Plaid Dashboard → Team Settings → Webhooks:
 *   https://<worker-host>/plaid/webhook
 *
 * Free-tier friendly: no Plaid secrets on this Worker. It only records
 * that an Item has pending updates so a future app poll can prompt Sync.
 *
 * Optional KV binding `WEBHOOKS` stores last event per item_id.
 * Without KV, events are accepted and logged (console) only.
 */

export interface Env {
  WEBHOOKS?: KVNamespace;
  /** Optional shared secret: require header X-Finance-Wizard-Key */
  WEBHOOK_INGEST_KEY?: string;
}

interface PlaidWebhookBody {
  webhook_type?: string;
  webhook_code?: string;
  item_id?: string;
  error?: { error_code?: string; error_message?: string } | null;
  initial_update_complete?: boolean;
  historical_update_complete?: boolean;
  environment?: string;
}

interface StoredEvent {
  webhook_type: string;
  webhook_code: string;
  item_id: string;
  error_code?: string;
  received_at: string;
  needs_sync: boolean;
  needs_relink: boolean;
  historical_update_complete?: boolean;
  initial_update_complete?: boolean;
}

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, X-Finance-Wizard-Key",
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // Health
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return json({ ok: true, service: "plaid-webhooks" });
    }

    // Plaid POSTs here
    if (request.method === "POST" && url.pathname === "/plaid/webhook") {
      return handleWebhook(request, env);
    }

    // App can poll: GET /pending?item_id=xxx&item_id=yyy
    if (request.method === "GET" && url.pathname === "/pending") {
      if (!authorizeOptional(request, env)) {
        return json({ error: "unauthorized" }, 401);
      }
      return handlePending(url, env);
    }

    return json({ error: "not_found" }, 404);
  },
};

function authorizeOptional(request: Request, env: Env): boolean {
  if (!env.WEBHOOK_INGEST_KEY) return true;
  return request.headers.get("X-Finance-Wizard-Key") === env.WEBHOOK_INGEST_KEY;
}

async function handleWebhook(request: Request, env: Env): Promise<Response> {
  let body: PlaidWebhookBody;
  try {
    body = (await request.json()) as PlaidWebhookBody;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const itemId = body.item_id ?? "";
  const webhookType = body.webhook_type ?? "UNKNOWN";
  const webhookCode = body.webhook_code ?? "UNKNOWN";
  const errorCode = body.error?.error_code;

  const needsRelink =
    webhookType === "ITEM" &&
    (webhookCode === "ERROR" ||
      webhookCode === "PENDING_EXPIRATION" ||
      webhookCode === "USER_PERMISSION_REVOKED" ||
      errorCode === "ITEM_LOGIN_REQUIRED");

  const needsSync =
    needsRelink ||
    webhookCode === "SYNC_UPDATES_AVAILABLE" ||
    webhookCode === "DEFAULT_UPDATE" ||
    webhookCode === "INITIAL_UPDATE" ||
    webhookCode === "HISTORICAL_UPDATE" ||
    webhookCode === "TRANSACTIONS_REMOVED" ||
    webhookCode === "RECURRING_TRANSACTIONS_UPDATE" ||
    webhookType === "TRANSACTIONS";

  const event: StoredEvent = {
    webhook_type: webhookType,
    webhook_code: webhookCode,
    item_id: itemId,
    error_code: errorCode,
    received_at: new Date().toISOString(),
    needs_sync: needsSync,
    needs_relink: needsRelink,
    historical_update_complete: body.historical_update_complete,
    initial_update_complete: body.initial_update_complete,
  };

  console.log("plaid_webhook", JSON.stringify(event));

  if (env.WEBHOOKS && itemId) {
    await env.WEBHOOKS.put(`item:${itemId}`, JSON.stringify(event), {
      expirationTtl: 60 * 60 * 24 * 14, // 14 days
    });
    // Keep a short rolling index of recently touched items
    const indexKey = "index:recent";
    const prev = (await env.WEBHOOKS.get(indexKey, "json")) as string[] | null;
    const next = [itemId, ...(prev ?? []).filter((id) => id !== itemId)].slice(0, 200);
    await env.WEBHOOKS.put(indexKey, JSON.stringify(next), {
      expirationTtl: 60 * 60 * 24 * 14,
    });
  }

  // Always 200 so Plaid does not retry forever on our side.
  return json({ received: true });
}

async function handlePending(url: URL, env: Env): Promise<Response> {
  if (!env.WEBHOOKS) {
    return json({
      items: [],
      note: "KV not bound — webhooks are logged only. Bind WEBHOOKS KV for persistence.",
    });
  }

  const ids = url.searchParams.getAll("item_id").filter(Boolean);
  if (ids.length === 0) {
    const recent = ((await env.WEBHOOKS.get("index:recent", "json")) as string[] | null) ?? [];
    const items: StoredEvent[] = [];
    for (const id of recent.slice(0, 50)) {
      const raw = await env.WEBHOOKS.get(`item:${id}`);
      if (raw) items.push(JSON.parse(raw) as StoredEvent);
    }
    return json({ items });
  }

  const items: StoredEvent[] = [];
  for (const id of ids) {
    const raw = await env.WEBHOOKS.get(`item:${id}`);
    if (raw) items.push(JSON.parse(raw) as StoredEvent);
  }
  return json({ items });
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders,
    },
  });
}
