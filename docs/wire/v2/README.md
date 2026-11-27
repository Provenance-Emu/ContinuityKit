# Continuity v2 wire specification

This Step 1 review draft defines the wire independently of the Swift API. It follows the [merged three-app design](https://github.com/Provenance-Emu/Provenance/pull/3834). The fixtures are new, synthetic examples for interoperability tests.

## Discovery

Publish one Bonjour service per running app under `_pvcontinuity._tcp` in `local.`. Deduplicate on `(pid, app)`. Advertisements are hints. Confirm identity and supported features through the handshake before trusting a peer.

| TXT key | Encoding |
| --- | --- |
| `v` | Required. ASCII `2`. Ignore an advertisement with a different major. |
| `app` | Required. `provenance`, `ifly`, or `icube`. |
| `pid` | Required. Lowercase SHA-256 hex of the raw 32-byte Ed25519 public key. |
| `dt` | Optional. `ip`, `pd`, `tv`, or `mc` for iPhone, iPad, Apple TV, or Mac. Unknown values use a generic icon. |
| `cap` | Optional. Concatenated flags `l` (library), `c` (continue), `s` (saves). Ignore unknown flags. No flags means presence only. |
| `sys`, `sys1`… | Optional. Comma-separated compact PVSystems identifiers, formed by removing `com.provenance.`. Use consecutive keys starting at `sys`, each with at most 240 UTF-8 value bytes. Split only between identifiers. Advertise the union of offered systems. |
| `cv` | Optional. First eight lowercase hex digits of the current catalogue version. |
| `u0`…`u3` | Ordered LAN HTTP origin candidates, starting at `u0`, with any .local candidate last. Omit for presence-only records with no listener. |
| `gs`, `gk`, `gt` | Optional as a group. Compact system identifier, opaque key and title of the running game. Send only with `c` while a game is running. Truncate title at a character boundary so the entire TXT item fits. |

Each UTF-8 `key=value` item fits within 255 bytes. Order is immaterial. Ignore unknown keys and reject duplicate known keys. Never advertise tokens or account identifiers. For browse, display a peer only if it offers the library capability and an intersecting system. The running-game fields are metadata separate from each app's existing Handoff activity type.

## HTTP

All paths start with `/continuity/v2`. JSON uses UTF-8, `application/json`, lower camel case keys, RFC 4648 padded Base64 for binary fields, lowercase hex for digests, nonnegative integer byte counts and UTC ISO 8601 dates. Optional fields may be omitted. Ignore unknown JSON fields and query items. Reject duplicate known query parameters. Percent-decode query values once. Identifiers described as opaque must be echoed without interpretation.

`GET hello` returns `app`, `appVersion`, `protocolMinor` (initially 0), `systems` (full PVSystems identifiers), `features` and `limits` (`maxPageSize` and `tokenLifetimeSeconds`). Optional `saveFormats` is an array of supported manifest save-kind strings. Feature names are `library`, `continue`, `saves`, `codePairing` and `sameOwner`. Advertise only implemented features. Reserve `tls` for an authenticated transport profile.

All protected routes use `Authorization: Bearer <token>`. Tokens are opaque, peer/app scoped and carry the granted scopes on the host. Expire them after one hour, retain only digests and cap active tokens at 16 per listener. Check grants, trust and sharing settings on every protected request. Never follow a redirect with a bearer token. Use `Cache-Control: private, no-store` for auth and manifests. The signed auth challenge proves client key possession to the server. Plain HTTP provides neither server authentication nor confidentiality or channel integrity. Checksums validate received bytes against a manifest and do not authenticate that manifest. Treat LAN URLs as untrusted and enforce LAN-only connections on both sides.

### Auth and pairing

A peer object contains `pid`, `app`, `name` and `publicKey`. Derive and verify each PID from its key, and reject a key that conflicts with a trusted identity. Trust is stored per device key. Grants are scoped by remote app within the serving app. Keep approval and capability checks local to the host.

| Request | Body | Success |
| --- | --- | --- |
| `POST auth/start` | `client` peer, `scopes`, optional `saveFormats` | `authId`, `server` peer, `nonce` (32 random bytes) and `expiresAt` |
| `POST auth/complete` | `authId`, `clientSignature` | Token response or approval pending |
| `POST pair/start` | `client` peer | `pairId`, `server` peer, `nonce` and `expiresAt` |
| `POST pair/complete` | `pairId`, profile-defined code proof and identity signature | `paired: true` and profile-defined server proof. Obtain scoped authorization via auth afterward. |

Scopes are `browse`, `copy`, `saves`, `continue`. Request scopes and save formats as sorted, unique arrays of ASCII strings. The token response contains `token`, `scopes` (the granted subset) and `expiresAt`. An unrecognized scope grants no access. For compatibility checks the serving peer uses the formats bound to the receiver's auth request, rather than calling back into a receiver that may have no listener.

Transcript encoding uses an ASCII domain prefix followed by fields. Each field is prefixed with its byte length as a four-byte unsigned big-endian integer. Text is UTF-8 and keys and nonce use raw bytes. For auth, use `pvcontinuity-auth-v2|` followed by `authId`, client PID, client app, client key, server PID, server app, server key, nonce, comma-joined scopes and comma-joined save formats (empty if omitted). Sign those bytes with the client Ed25519 key. Bind the challenge to one exchange, expire it, and allow only an identical completion to poll a pending decision. Issue the token once and invalidate pending exchanges on revocation. Consent is shown only after verifying the identity signature.

For pairing, the envelope and domain `pvcontinuity-pair-v2|` are reserved. The pairing profile must bind `pairId`, both peer IDs, app IDs, keys and the nonce, and prove possession of the six-digit code without exposing an offline code check. [SPAKE2](https://www.rfc-editor.org/rfc/rfc9382.html) is one candidate for review. The code proof, identity-signature bytes and mutual confirmation need their own agreed vectors before enabling `codePairing`. Same-owner proof and authenticated TLS also need separate profiles. Fixtures for the envelope do not advertise any of these features.

### Catalogue, transfers and continue

| Request | Scope | Response |
| --- | --- | --- |
| `GET catalog?systems=&q=&limit=&cursor=` | `browse` | `catalogVersion`, `entries`, optional `nextCursor`. Require a nonempty CSV of full system IDs. Optional search, limit and cursor. |
| `GET art?key=` | `browse` | Image bytes with the appropriate media type and an ETag. |
| `GET manifest?key=&include=` | `copy` | Manifest. Optional CSV `include` selects `saves`, `bios`, `extras`. Server applies grants and format compatibility. |
| `GET file?key=&path=` | The scope that authorized the manifest | Approved file bytes. |
| `GET session` | `continue` | Running game's `key` and `identity`. |
| `POST session/mint` | `continue` | Request body `key` as returned by session. Mint a fresh state and return the manifest for that same running game. |

Catalogue entries contain `key`, `identity` and `hasArtwork`. The identity contains required `system`, `title` and `sizeBytes`, with optional `md5`, `crc32`, `serial`, `gameId`, `discNumber` (zero-based), and `revision`. The receiver also filters by supported systems. Play history fields `lastPlayedAt`, `playCount` and `favorite` are optional entry metadata restricted to same-owner devices. Cursors are opaque and bound to the token, filter, search, limit and catalogue revision. A stale revision returns 409 and the client starts without a cursor. Catalogue and artwork support `If-None-Match` and 304 with an empty body. The catalogue validator identifies the exact response page and scope-dependent metadata.

A manifest contains `key`, `identity` and ordered `files`. Each file has `path`, `kind`, `sizeBytes`, `sha256` and `required`. Put the primary game file first, then companions. Download order may prioritize small files. Kinds are `game`, `artwork`, `bios`, `extra.*`, `save.battery.<format>` and `save.state.<core>.<version>`. Optional unknown kinds may be skipped. Abort if a required kind is unsupported. For an offline package, `manifest.json` is at the ZIP root and descriptors refer to entries below `files/`.

Paths are unique, game-relative UTF-8 paths with slash separators. Reject absolute paths, backslashes, empty segments, NULs and dot segments. Reject collisions on the receiving filesystem and stage under a receiver-owned directory. Match each file request against a manifest issued for the token and key. Do not expand the authorization using a guessed path. A response including saves needs an explicit saves grant and an advertised compatible format. Never send whole multi-game card or NAND images to another person. BIOS requires a same-owner opt-in.

Support single byte ranges, including `bytes=N-`. On 206 use `Content-Range` and confirm the offset, length and total against the descriptor. On 416 send `Content-Range: bytes */<size>`. A 200 in response to a range starts the file over. On an invalid 206 or 416, discard the invalid resume offset. Cap restarts at two. Keep partial files out of importer paths and verify length and SHA-256 before publishing. Reuse the cached manifest for retries where the grant remains valid.

### Status and retries

Errors use `{"error":{"code":"stableIdentifier","message":"Human-readable detail"}}`. The message is optional. Decide behavior from the status and code. Use 400 `invalidRequest`, 401 `invalidToken`, 403 `denied`, 404 `unavailable`, 409 `catalogChanged` or `sessionChanged`, 410 `challengeExpired`, 416 `invalidRange`, and 429 `rateLimited`. A 202 approval response has `{"status":"pending"}` and a `Retry-After` delay in seconds. Repeat the identical request. Pending manifest retries reuse one decision and charge at most one copy per logical request. A 429 may include `Retry-After`.

## Fixtures

`fixtures/discovery-*.txt` are decoded TXT items, one UTF-8 item per line, without DNS length octets. `fixtures/*.json` use HTTP envelopes with a method/path or status, optional headers and either a JSON body or binary `bodyBase64`. They are HTTP examples at the application layer and omit routine framing headers. The auth fixture includes a transcript and signature vector outside the HTTP envelopes. Only the examples in `fixtures/rejected.json` are deliberately invalid. Examples share synthetic identities and assets and can be consumed without running a server.
