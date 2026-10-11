# Provider sign-in setup (maintainers only)

Wren's users connect their accounts by signing in on each provider's own page. They never create
OAuth clients, copy secrets, paste API keys or tokens, or edit configuration. Everything on this page
is done once by Wren's maintainers before a release. Nothing here belongs in user-facing docs.

If a provider below isn't configured for a build, that build shows **Not available in this build**
for it, with no setup steps for the user. That is the intended, honest fallback.

| Provider | Registration | Secret | Where it lives |
|---|---|---|---|
| ChatGPT | None: Sign in with ChatGPT registers Wren dynamically on first sign-in | None | Nothing to configure |
| Notion | None: Notion MCP registers Wren dynamically at sign-in | None | Nothing to configure |
| Calendar (this Mac) | None: macOS Calendars permission | None | Nothing to configure |
| Google (Gmail, Calendar) | Google OAuth client, type **Desktop app** | None: public client, loopback + PKCE | Client ID injected into the app at build time |

## Build-time injection

`scripts/build-app.sh` reads these variables from the environment, or from `config/providers.env`
(git-ignored; copy `config/providers.env.example`), and writes them into `Info.plist`. The script
only reads these four keys from the file and never executes it or prints the values.

| Variable | Value |
|---|---|
| `WREN_GOOGLE_CLIENT_ID` | `….apps.googleusercontent.com` |
| `WREN_GOOGLE_STATUS` | `testing`, `unverified` or `verified` (what Wren tells users to expect) |

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

## Google (Gmail and Google Calendar): the 15-minute setup

Users see one **Connect Google**. Wren makes one sign-in with both read-only scopes, or the subset the
user ticks, and uses `include_granted_scopes=true`. It turns on only the features whose scope Google
granted, and only after a real read succeeds. Most people get their calendars through
**Calendar (this Mac)** instead, which needs no Google app at all.

You do this once. Everyone who downloads the DMG then just clicks Connect Google.

**A. Create the app (Google Cloud Console, signed in as the owner)**
1. Create a project named "Wren". APIs & Services › Library: enable **Gmail API** and
   **Google Calendar API**.
2. Google Auth Platform › Branding: app name **Wren**, the Wren logo, your support email, a home page
   (the GitHub page is fine) and a privacy policy URL (for example, a page in the repo describing
   docs/privacy).
3. Audience: **External**.
4. Data access › Add or remove scopes: add only `.../auth/gmail.readonly` and
   `.../auth/calendar.readonly`.
5. Clients › Create client › Application type **Desktop app**, name "Wren for Mac". Copy the
   **client ID**. Ignore the client secret: Wren never uses it.

**B. Choose who can connect**
- **Just you and a few people:** Audience › Test users › add their Gmail addresses (up to 100). Set
  `WREN_GOOGLE_STATUS=testing`. Google asks them to reconnect every 7 days.
- **Anyone who downloads the DMG (recommended for a small app):** Audience › **Publish app**.
  Without verification, Google shows "Google hasn't verified this app". Users choose
  **Advanced › Go to Wren**, there's no 7-day reconnect, and Google caps it at 100 users. Set
  `WREN_GOOGLE_STATUS=unverified`. Wren shows users exactly that instruction before they connect.
- **Everyone, no warning:** submit for verification (next section). Set
  `WREN_GOOGLE_STATUS=verified` only after Google approves.

**C. Put it in the DMG**
- GitHub › Settings › Secrets and variables › Actions:
  - secret `WREN_GOOGLE_CLIENT_ID` = the client ID;
  - variable `WREN_GOOGLE_STATUS` = `testing`, `unverified` or `verified`.
- Tag a release (`git tag v0.9.0-preview.1 && git push --tags`). The DMG the Release workflow builds
  contains the client ID, and `scripts/verify-dmg.sh` reports "Google included".
- Local builds read the same two values from `config/providers.env`.

**D. Check it**
Install the DMG, Connectors › Gmail › Connect Google, approve with a test account, and follow
docs/MANUAL_TESTS.md › Google.

Wren is a public client (loopback redirect, PKCE and state). Google documents `client_secret` as
optional for installed apps, so none is shipped or sent.

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

## Notion (nothing to register)

Wren connects through Notion's hosted MCP server (`https://mcp.notion.com/mcp`), using Notion's
OAuth for MCP clients:
- At each sign-in, Wren registers itself (RFC 7591) as a public client for that exact loopback
  address.
- It uses PKCE and state, and checks the issuer.
- It exchanges the code and refreshes tokens with Notion directly.

There's no Notion integration, client secret, relay or server of Wren's own. Wren reads and writes
through Notion's MCP tools: `notion-get-self`, `notion-search`, `notion-fetch` and
`notion-create-pages`. The last one is used only after the user confirms.

Checked against the live service (2026-10-11):
- the metadata at `/.well-known/oauth-authorization-server` advertises dynamic registration,
  `token_endpoint_auth_method: none` and S256;
- registering with an `http://127.0.0.1:<port>/notion/callback` redirect is accepted;
- the authorize endpoint then forwards to Notion's normal consent page, while a made-up client ID is
  rejected.

A full sign-in needs a person with a Notion account.

Notion refresh tokens end after 180 days, or after 30 days unused; Wren then shows "Reauthorization
required".

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
