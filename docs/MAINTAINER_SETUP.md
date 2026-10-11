# Provider sign-in setup (maintainers only)

Wren's users connect their accounts by signing in on each provider's own page. They never create
OAuth clients, copy secrets, paste API keys or tokens, or edit configuration. Everything on this page
is done once by Wren's maintainers before a release. Nothing here belongs in user-facing docs.

If a provider below isn't configured for a build, that build shows **Not available in this build**
for it, with no setup steps for the user. That is the intended, honest fallback.

| Provider | Registration | Secret | Where it lives |
|---|---|---|---|
| ChatGPT | None: Sign in with ChatGPT registers Wren dynamically on first sign-in | None | Nothing to configure |
| Google (Gmail, Calendar) | Google OAuth client, type **Desktop app** | Desktop-client secret (non-confidential per Google) | Injected into the app at build time |
| Notion | Notion **public** integration | Client secret, confidential | Only in the Notion relay service |

## Build-time injection

`scripts/build-app.sh` reads these variables from the environment, or from `config/providers.env`
(git-ignored; copy `config/providers.env.example`), and writes them into `Info.plist`. The script
only reads these four keys from the file and never executes it or prints the values.

| Variable | Value |
|---|---|
| `WREN_GOOGLE_CLIENT_ID` | `….apps.googleusercontent.com` |
| `WREN_GOOGLE_CLIENT_SECRET` | The desktop client's secret |
| `WREN_NOTION_CLIENT_ID` | The public integration's OAuth client ID |
| `WREN_NOTION_OAUTH_RELAY` | HTTPS base URL of the deployed relay |

For releases, add the same four names as **repository secrets**. The Release workflow passes them to
packaging. `scripts/verify-dmg.sh` reports whether each provider is included without showing values.
Pull-request CI builds without them.

## ChatGPT (Sign in with ChatGPT)

Nothing to register. Wren implements OpenAI's documented protocol for open-source local apps
natively in Swift (`Sources/WrenCore/Connectors/ChatGPTAuth.swift`, `ChatGPTPlan.swift`):

- Discovery at `https://auth.openai.com/.well-known/openid-configuration`.
- First authorization uses `client_id=dynamic_agent_client`, `agent_name_hint=Wren` and a per-Mac
  `ext_agent_host_id`. OpenAI returns an issued `oaiapp_…` client ID, which Wren keeps (in the
  Keychain) and reuses. Disconnecting keeps it, so reconnecting doesn't register Wren again.
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

OpenAI's sign-in devkit (TypeScript) is under a noncommercial license. Wren does not include or
depend on it; it was used only as a reference for the documented protocol.

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
5. Put the client ID and secret in `config/providers.env` or the repository secrets.

Known blocker for public distribution: `gmail.readonly` is a **restricted** scope and
`calendar.readonly` is **sensitive**. Until Google verifies the app (restricted scopes also need an
annual third-party security assessment), only listed test users (up to 100) can connect, Google shows
an "unverified app" screen, and refresh tokens for test users expire after 7 days. These are Google's
rules; Wren reports the resulting expiry as "Permission denied, reconnect" rather than hiding it.

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
open -a "$PWD/build/Wren.app" "wren://debug/connectors"
```

`/connectors` logs every connector's state, `/chatgpt-connect` starts Sign in with ChatGPT (you still
sign in in the browser), `/chatgpt-status` logs the account state and listed models, and
`/chatgpt-ask?task=…` runs one confirmed request. Read the results with
`/usr/bin/log show --last 5m --predicate 'subsystem == "com.shibadityadeb.wren"'`. Logs never contain
tokens or request text.

Use a separate macOS user or a backup when testing a newer build: a newer Wren upgrades the database,
and older versions refuse to open it.
