// node --test services/notion-oauth-relay/relay.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { handle } from "./relay.mjs";

const env = { NOTION_CLIENT_ID: "client-1", NOTION_CLIENT_SECRET: "shh-secret", PUBLIC_URL: "https://relay.example/" };
const STATE = "54321." + "a".repeat(32);

function post(path, body, type = "application/json") {
  return new Request("https://relay.example" + path, { method: "POST", headers: { "content-type": type }, body: typeof body === "string" ? body : JSON.stringify(body) });
}

function fakeNotion(status, data) {
  const calls = [];
  const impl = async (url, init) => { calls.push({ url, init, body: JSON.parse(init.body) }); return new Response(JSON.stringify(data), { status }); };
  return { calls, impl };
}

test("callback bounces only to the loopback port in a well-formed state", async () => {
  const ok = await handle(new Request(`https://relay.example/notion/callback?code=abc-123&state=${STATE}`), env);
  assert.equal(ok.status, 302);
  const loc = new URL(ok.headers.get("location"));
  assert.equal(loc.origin, "http://127.0.0.1:54321");
  assert.equal(loc.pathname, "/notion/callback");
  assert.equal(loc.searchParams.get("code"), "abc-123");
  assert.equal(loc.searchParams.get("state"), STATE);
  assert.equal(ok.headers.get("cache-control"), "no-store");

  const denied = await handle(new Request(`https://relay.example/notion/callback?error=access_denied&state=${STATE}`), env);
  assert.equal(new URL(denied.headers.get("location")).searchParams.get("error"), "access_denied");

  for (const bad of ["evil.com/x", "80." + "a".repeat(32), "54321.short", `${STATE}&state=${STATE}`, "99999." + "a".repeat(32)]) {
    const r = await handle(new Request(`https://relay.example/notion/callback?code=x&state=${bad}`), env);
    assert.equal(r.status, 400, bad);
    assert.equal(r.headers.get("location"), null);
  }
});

test("token exchange uses the secret server-side and returns only needed fields", async () => {
  const n = fakeNotion(200, { access_token: "AT", refresh_token: "RT", bot_id: "b", workspace_id: "w", workspace_name: "Acme", owner: { type: "user", user: { name: "Sam", person: { email: "sam@example.com" } } }, extra: "x" });
  const r = await handle(post("/notion/token", { code: "C1", redirect_uri: "https://attacker.example" }), env, n.impl);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { access_token: "AT", refresh_token: "RT", bot_id: "b", workspace_id: "w", workspace_name: "Acme", owner_name: "Sam" });
  assert.equal(n.calls[0].url, "https://api.notion.com/v1/oauth/token");
  assert.equal(n.calls[0].init.headers.authorization, "Basic " + btoa("client-1:shh-secret"));
  assert.equal(n.calls[0].init.headers["notion-version"], "2026-03-11");
  assert.deepEqual(n.calls[0].body, { grant_type: "authorization_code", code: "C1", redirect_uri: "https://relay.example/notion/callback" }, "redirect_uri is fixed, not taken from the client");
});

test("errors pass through without leaking details", async () => {
  const bad = fakeNotion(400, { error: "invalid_grant", error_description: "secret detail" });
  const r = await handle(post("/notion/token", { code: "old" }), env, bad.impl);
  assert.equal(r.status, 400);
  assert.deepEqual(await r.json(), { error: "invalid_grant", error_description: "Notion rejected the request." });
  const down = fakeNotion(503, {});
  assert.equal((await handle(post("/notion/refresh", { refresh_token: "RT" }), env, down.impl)).status, 502);
  const offline = await handle(post("/notion/revoke", { token: "AT" }), env, async () => { throw new Error("offline"); });
  assert.equal(offline.status, 502);
});

test("refresh and revoke", async () => {
  const n = fakeNotion(200, { access_token: "AT2", refresh_token: "RT2", expires_in: 3600 });
  const r = await handle(post("/notion/refresh", { refresh_token: "RT1" }), env, n.impl);
  assert.deepEqual(await r.json(), { access_token: "AT2", refresh_token: "RT2", expires_in: 3600 });
  assert.deepEqual(n.calls[0].body, { grant_type: "refresh_token", refresh_token: "RT1" });
  const v = fakeNotion(200, { request_id: "x" });
  const rv = await handle(post("/notion/revoke", { token: "AT2" }), env, v.impl);
  assert.equal(rv.status, 200);
  assert.equal(v.calls[0].url, "https://api.notion.com/v1/oauth/revoke");
});

test("rejects everything else", async () => {
  const n = fakeNotion(200, {});
  assert.equal((await handle(new Request("https://relay.example/notion/token"), env, n.impl)).status, 404);
  assert.equal((await handle(post("/other", {}), env, n.impl)).status, 404);
  assert.equal((await handle(post("/notion/token", "code=x", "application/x-www-form-urlencoded"), env, n.impl)).status, 400);
  assert.equal((await handle(post("/notion/token", { code: "x".repeat(5000) }), env, n.impl)).status, 400);
  assert.equal((await handle(post("/notion/token", { code: "has spaces" }), env, n.impl)).status, 400);
  assert.equal((await handle(post("/notion/token", { code: "C" }), { ...env, PUBLIC_URL: "http://insecure" }, n.impl)).status, 503);
  assert.equal(n.calls.length, 0, "Notion never called for rejected requests");
});
