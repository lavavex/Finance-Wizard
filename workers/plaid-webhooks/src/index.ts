/**
 * Plaid webhook endpoint (Cloudflare Worker).
 *
 * Link tokens name this URL, and linked Items keep posting to it. The app gets its status
 * from /item/get and its data from Sync, so each webhook is acknowledged and discarded:
 * nothing is read, logged, or stored. A 200 stops Plaid retrying.
 */

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "POST" && url.pathname === "/plaid/webhook") {
      return json({ received: true });
    }

    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return json({ ok: true, service: "plaid-webhooks" });
    }

    return json({ error: "not_found" }, 404);
  },
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
