# Provider sign-in setup (maintainers only)

Wren's users connect their accounts by signing in on each provider's own page. They never create
OAuth clients, copy secrets, paste API keys or tokens, or edit configuration. Everything on this page
is done once by Wren's maintainers before a release. Nothing here belongs in user-facing docs.

If a provider below isn't configured for a build, that build shows **Not available in this build**
for it, with no setup steps for the user. That is the intended, honest fallback.

| Provider | Registration | Secret | Where it lives |
|---|---|---|---|
| ChatGPT | None: Sign in with ChatGPT registers Wren dynamically on first sign-in | None | Nothing to configure |
| Google (Gmail, Calendar) | Google OAuth client, type **Desktop app** | None: public client, loopback + PKCE | Client ID injected into the app at build time |
| Notion | Notion **public** integration | Client secret, confidential | Only in the Notion relay service |

## Build-time injection

`scripts/build-app.sh` reads these variables from the environment, or from `config/providers.env`
(git-ignored; copy `config/providers.env.example`), and writes them into `Info.plist`. The script
only reads these four keys from the file and never executes it or prints the values.

| Variable | Value |
|---|---|
| `WREN_GOOGLE_CLIENT_ID` | `….apps.googleusercontent.com` |
| `WREN_NOTION_CLIENT_ID` | The public integration's OAuth client ID |
| `WREN_NOTION_OAUTH_RELAY` | HTTPS base URL of the deployed relay |

For releases, add the same three names as **repository secrets**. The Release workflow passes them to
packaging. `scripts/verify-dmg.sh` reports whether each provider is included without showing values.
Pull-request CI builds without them.

## ChatGPT (Sign in with ChatGPT)

Nothing to register. Wren implements OpenAI's documented protocol for open-source local apps
natively in Swift (`Sources/WrenCore/Connectors/ChatGPTAuth.swift`, `ChatGPTPlan.swift`):

- Discovery at `https://auth.openai.com/.well-known/openid-configuration`.
- First authorization uses `client_id=dynamic_agent_client`, `agent_name_hint=Wren` and a per-Mac
  `ext_agent_host_id`. OpenAI returns an issued `oaiapp_…` client ID, which Wren keeps (in the
  credentials file) and reuses. Disconnecting keeps it, so reconnecting doesn't register Wren again.
- PKCE (S256), `state`, `nonce`, loopback redirect `http://127.0.0.1:<port>/auth/callback`.
- ID tokens are verified (RS256) against the issuer's JWKS: issuer, audience, expiry, nonce.
- Plan usage is enabled only if the granted scopes include `chatgpt.tokens.use.direct`.
- Models come from `GET https://api.openai.com/v1/models` (`visibility == "list"`); none are hardcoded.
- Inference is `POST https://api.openai.com/v1/responses` with `store: false, stream: true`; only
  `response.completed` counts as success.

Eligibility and terms, as documented by OpenAI: the open-source path covers open-source and personal
local apps, used by people on ChatGPT Plus or Pro. Requests must come from Wren's own functionality on
the user's Mac, attributable to that user; Wren sends plan requests only for requests the user starts
and confirms, never from background tasks. A commercial or hosted distribution would need a client ID
requested from OpenAI instead of dynamic registration.

**Why not the devkit itself.** OpenAI's sign-in devkit (`@siwc/local`) is a TypeScript library for Node
and Electron apps, under a noncommercial license. Wren is a single native Swift process with no
JavaScript runtime. Embedding the devkit would mean shipping a Node runtime inside the app and
running the credentials in a second process. Instead, Wren implements the same documented methods in
its trusted app process:
- dynamic registration with `dynamic_agent_client` and `agent_name_hint`, reusing the issued client ID;
- PKCE, state and nonce over a loopback callback;
- ID-token verification against the issuer's JWKS;
- refresh with rotation, and revocation;
- model listing, and streamed Responses requests.

No devkit code is copied. If OpenAI publishes a native or C-callable runtime, Wren can switch to it
behind the same `ChatGPTConnector`.

## Google (Gmail and Google Calendar)

1. In a Google Cloud project owned by the maintainers, enable the **Gmail API** and the
   **Google Calendar API**.
2. Google Auth Platform › Branding: app name **Wren**, support email, home page, privacy policy.
   Audience: **External**.
3. Data access: add only `https://www.googleapis.com/auth/gmail.readonly` and
   `https://www.googleapis.com/auth/calendar.readonly`. Wren requests each one separately, from its
   own connector, and checks the granted scope.
4. Clients › Create client › **Desktop app**. Loopback redirects on any port are allowed for this
   type; no redirect URI is entered.
5. Put the client ID in `config/providers.env` or the repository secrets. Don't add the client secret
   anywhere: Wren is a public client (loopback redirect + PKCE), and Google documents `client_secret`
   as optional for installed apps, so none is shipped or sent.

### Google verification: what's needed before ordinary users can connect

`gmail.readonly` is a **restricted** scope and `calendar.readonly` is a **sensitive** scope. Google's rules:

- **While the app is in Testing**, only test users listed in the console (up to 100) can connect. They
  see a warning screen, and their refresh tokens expire after 7 days. Wren reports that expiry as
  "Reauthorization required" and offers Reconnect.
- **To publish to everyone**, the app needs Google's OAuth verification:
  - a verified domain, with a home page and a privacy policy on it;
  - a scope justification and a demo video of the consent flow and features;
  - compliance with the Google API Services User Data Policy, including the Limited Use requirements
    for Gmail data.
- **The third-party security assessment (CASA)** for restricted scopes applies to apps that can access
  the data "from or through a third-party server". Wren reads Gmail directly from the user's Mac and
  stores nothing on any server, so this should not apply. Keep it that way: don't proxy Gmail data
  through a Wren server, and don't send Gmail content to AI services, unless the verification and
  Limited Use review cover it.
- **Exceptions:** personal use or a handful of users, and internal Workspace apps, don't need
  verification.

Until verification is granted, ship builds with Google either excluded (users see "Maintainer setup
required") or for listed testers only. Don't work around the consent screen.

## Notion (public integration and relay)

Notion's token, refresh and revoke endpoints require the integration's client secret, so the secret
lives in a small relay (`services/notion-oauth-relay/relay.mjs`) instead of the app. The relay is a
dependency-free fetch handler. It stores nothing, logs no bodies, forwards Notion's redirect to the
user's loopback listener using the port Wren puts in `state`, and returns only the token fields Wren
uses. Wren still checks `state` itself.

1. Deploy the relay, for example on Cloudflare Workers:
   ```bash
   cd services/notion-oauth-relay
   cp wrangler.toml.example wrangler.toml
   wrangler secret put NOTION_CLIENT_ID
   wrangler secret put NOTION_CLIENT_SECRET
   wrangler secret put PUBLIC_URL
   wrangler deploy
   ```
   `PUBLIC_URL` is the relay's own HTTPS base URL.
2. At notion.so/profile/integrations create a **Public** integration. Capabilities: read content and
   insert content. Redirect URI: `<PUBLIC_URL>/notion/callback`. Fill in the company, website, privacy
   policy and terms fields Notion asks for.
3. Set the relay's secrets from the integration's OAuth client ID and secret.
4. Put `WREN_NOTION_CLIENT_ID` and `WREN_NOTION_OAUTH_RELAY` (= `PUBLIC_URL`) in
   `config/providers.env` or the repository secrets. The client secret never goes there.

Tests: `node --test services/notion-oauth-relay/relay.test.mjs`.

## Verifying a build

With a debug build (`scripts/build-app.sh debug`), these hooks exist only in DEBUG and are refused by
`scripts/verify-dmg.sh` in release images. Send them with the absolute app path so an installed copy
doesn't receive them:

```bash
open -a "$PWD/build/Wren Dev.app" "wren-dev://debug/connectors"
```

Build it as **Wren Dev** (`scripts/build-app.sh debug --dev-identity`) so it runs beside an installed
Wren with its own data, preferences, credentials and the `wren-dev://` scheme. A normal debug
build is still Wren: the single-instance check and the data lock stop it from running next to the
installed copy.

`/connectors` logs every connector's state, `/chatgpt-connect` starts Sign in with ChatGPT (you still
sign in in the browser), `/chatgpt-status` logs the account state and listed models, and
`/chatgpt-ask?task=…` runs one confirmed request, `/reminders` reconciles and lists the reminder
requests pending in macOS, `/voice-command?text=…` runs text through the voice command step, `/voice`
presses the voice shortcut, and `/wake?on=1` turns "Hey Wren" on. Read the results with
`/usr/bin/log show --last 5m --predicate 'subsystem == "com.shibadityadeb.wren"'`. Logs never contain
tokens or request text.

Use a separate macOS user or a backup when testing a newer build: a newer Wren upgrades the database,
and older versions refuse to open it.
