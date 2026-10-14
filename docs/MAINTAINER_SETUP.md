# Maintainer setup: provider sign-in, releases and signing

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
| Google (Gmail, Calendar) | Google OAuth client, type **Desktop app** | The Desktop client's secret (Google requires it at the token endpoint; not confidential for installed apps) | Client ID and secret injected into the app at build time |

## Build-time injection

`scripts/build-app.sh` reads these variables from the environment, or from `config/providers.env`
(git-ignored; copy `config/providers.env.example`), and writes them into `Info.plist`. The script
only reads the keys listed below from the file and never executes it or prints the values.

| Variable | Value |
|---|---|
| `WREN_GOOGLE_CLIENT_ID` | `….apps.googleusercontent.com` |
| `WREN_GOOGLE_CLIENT_SECRET` | the same Desktop client's secret (`GOCSPX-…`) |
| `WREN_GOOGLE_STATUS` | `testing`, `unverified` or `verified` (what Wren tells users to expect) |

For releases, add the same names as repository secrets (`WREN_GOOGLE_CLIENT_ID`, `WREN_GOOGLE_CLIENT_SECRET`) and a variable (`WREN_GOOGLE_STATUS`). The Release workflow passes them to
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
4. Data access › Add or remove scopes: add `.../auth/gmail.readonly`, `.../auth/calendar.readonly`
   and, for the optional Mark as read, `.../auth/gmail.modify` (requested only when a user chooses
   "Allow Mark as read…"; Google has no narrower scope that can remove the UNREAD label).
5. Clients › Create client › Application type **Desktop app**, name "Wren for Mac". Copy the
   **client ID** and the **client secret**. Both go into the build (C).

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
  - secret `WREN_GOOGLE_CLIENT_SECRET` = the client secret;
  - variable `WREN_GOOGLE_STATUS` = `testing`, `unverified` or `verified`.
- Tag a release (`git tag v0.9.0-preview.1 && git push --tags`). The DMG the Release workflow builds
  contains the client ID, and `scripts/verify-dmg.sh` reports "Google included".
- Local builds read the same values from `config/providers.env`. `scripts/build-app.sh` warns when the
  client ID is set but the secret isn't.

**D. Check it**
Install the DMG, Connectors › Gmail › Connect Google, approve with a test account, and follow
docs/MANUAL_TESTS.md › Google.

Wren uses the installed-app flow (loopback redirect, PKCE and state) **and** sends the Desktop
client's secret to the token endpoint. Earlier builds sent no secret on the assumption that PKCE made
it optional; Google rejects that for Desktop clients. Verified 2026-10-11 against Wren's real client ID
with a deliberately invalid code: without a secret Google answers `invalid_request: client_secret is
missing.`, with a wrong one `invalid_client`. Google's documentation for installed apps treats this
secret as not confidential (it ships inside the app), so it's injected at build time like the client ID
and never committed. Without it, every Connect Google fails after the user approves, and Wren reports
it as a build problem, not the user's.

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
requests pending in macOS, `/voice-command?text=…` runs text through the voice command step, and `/voice`
presses the voice shortcut (the microphone really starts). `/command?text=…` logs `execute <Operation>`
for the routed operation. `wren-tools live-check chatgpt "<request>"` and the read-only
`wren-tools live-check gmail` (needs `WREN_GOOGLE_CLIENT_ID`/`_SECRET` in the environment) exercise the
real providers with the signed-in accounts in Wren's data folder and print counts only. Read the results with
`/usr/bin/log show --last 5m --predicate 'subsystem == "com.shibadityadeb.wren"'`. Logs never contain
tokens or request text.

Use a separate macOS user or a backup when testing a newer build: a newer Wren upgrades the database,
and older versions refuse to open it.

## Releases

1. Update `VERSION` and add a section to `CHANGELOG.md`.
2. Commit, then tag with the version in `VERSION`: `git tag "v$(cat VERSION)-preview.1"` (prerelease) or `git tag "v$(cat VERSION)"` (stable), and push the tag.
3. The **Release** workflow runs the full tests on Apple Silicon and Intel, builds the universal app, packages and verifies the DMG on both architectures, signs and notarizes when credentials exist, and publishes a GitHub Release with notes and checksums.

Rules: the tag must match `VERSION`. A **stable** tag is only published if the build is signed and notarized; unsigned builds can only be published under a `-preview`/`-beta`/`-rc` tag, marked as prerelease. **Run workflow** (manual dispatch) builds a release candidate as a downloadable artifact and never publishes.

Local packaging: `scripts/package-dmg.sh` (runs tests, builds universal, packages, verifies). `scripts/verify-dmg.sh <dmg>` re-checks any DMG.

### Provider sign-in

Google sign-in needs one app registration made by the maintainers and injected at build time. ChatGPT and Notion need none, because Wren registers itself with them. See the sections above. A build without them still works and shows Gmail and Google Calendar (direct) as "Maintainer setup required".

### Signing and notarization

Required for a frictionless public release. Add these **repository secrets** (Settings › Secrets and variables › Actions). Never commit them.

| Secret | What |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Your **Developer ID Application** certificate and private key, exported from Keychain Access as .p12, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the .p12 |
| `NOTARY_KEY_P8_BASE64` | An App Store Connect API key (Users and Access › Integrations › Team Keys, role Developer), the downloaded `AuthKey_XXXX.p8`, base64-encoded |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys list |

You need a paid Apple Developer Program membership to create a Developer ID Application certificate. The workflow imports the certificate into a temporary keychain, signs with the hardened runtime and a secure timestamp (no extra entitlements are needed), submits the DMG with `notarytool`, waits, staples the ticket and verifies it with `stapler validate` and `spctl` before publishing.
