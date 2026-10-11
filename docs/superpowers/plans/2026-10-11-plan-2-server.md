# Plan 2 — LiftServer (HTTP + MCP): build record

**Status:** built directly in the repo on `oshricohenme/7jtm2` (process change: build first, short record instead of a code-in-plan document). Spec: `docs/superpowers/specs/2026-10-11-lift-design.md` §10 (with §1, §4, §8, §11, §13, §14). Builds on Plan 1 (LiftCore).

## What was built

- **One port, two adapters over the same commands.**
  - `/v1/*` comes from the hand-written `Sources/LiftServer/openapi.yaml` through swift-openapi-generator 1.14.0 (types + server), served by hummingbird 2.27.1 through swift-openapi-hummingbird 2.1.0.
  - `/openapi.json` is the yaml as JSON. `/docs` is a Redoc 2.5.4 page (vendored `Resources/redoc.standalone.js` and its license files, MIT).
  - `/mcp` is MCP Streamable HTTP on swift-sdk 0.12.1: one `Server` + `StatefulHTTPServerTransport` per session.
- **MCP tools come from openapi.yaml.** There's one tool per operation, named by its operationId (the spec's `area_action` names), with the same arguments (path and query parameters plus the JSON body's properties). Parity therefore holds by construction, and a test pins the names to the spec table.
- **MCP resources:**
  - `lift://jobs/{id}` (JSON) and `lift://jobs/{id}/outputs/{file}` (blob)
  - `lift://models/{id}/install-log` (text) and `lift://resources` (JSON)
  - Subscriptions on jobs and resources.
  - `jobs_wait` sends progress notifications. Outputs come back as `{path, uri, url}` plus `resource_link`s.
- **`lift-mcp`**: an executable (swift-argument-parser 1.8.2) that bridges stdio ↔ `/mcp` with the SDK's own transports. Flags: `--url`, `--token` / `$LIFT_TOKEN`. When Lift isn't running it answers each request with JSON-RPC error `-32000`.
- **Auth:**
  - Loopback needs no token, but `Host`/`Origin` must be local (DNS-rebinding guard).
  - In LAN mode the server binds 0.0.0.0, and other machines need `Authorization: Bearer <token>` (compared in constant time).
  - The token is 32 random bytes in base64url, kept in the Keychain through KeychainAccess 4.2.2. The `SecretStore` protocol is injectable; tests use `MemorySecretStore`.
  - Rotate with `server_rotate_token`.
- **Port:** 7777 by default, else the next free port (up to 19 tries). `server_status` reports the port actually bound, the URLs and an `mcpServers` snippet.

## Where things live

| File | What |
|---|---|
| `Sources/LiftServer/openapi.yaml`, `openapi-generator-config.yaml` | the API: 39 operations = 39 MCP tools, plus `jobs_get_output` (`x-mcp: false`) |
| `Wire.swift` | snake_case JSON / ISO 8601; `JobOut` (JobView + outputs), list wrappers, `SettingsOut`, `MemoryWarningOut` |
| `Problem.swift` | `Problem` error body, `ConfirmationRequired`, `gated()`, `ProblemMiddleware` |
| `Inputs.swift` | `SubmitWire`; `<name>`/`<name>_path`/`<name>_base64`(+`_filename`)/multipart `steps[i].<name>` → paths |
| `Shared.swift` | submit, retry, recipes, move, wait, output: the only calls to LiftCore APIs that are still changing |
| `API.swift` | `APIProtocol`: one handler per operation; `LocationMiddleware` |
| `Access.swift` | `LiftContext`, `Access.check`, `AccessMiddleware` |
| `Docs.swift` | `OpenAPIDocument`, `/openapi.json`, `/docs` |
| `LiftServer.swift` | the server actor: bind, port fallback, LAN rebind, server_* commands, merged settings |
| `ServerSettings.swift` | `port`, `lan_mode` in `<workdir>/server.json` |
| `Secrets.swift` | `SecretKey`, `SecretStore`, `MemorySecretStore`, `KeychainSecretStore`, `hfTokenReader`, `SecretsStatus` |
| `Tools.swift` · `Resources.swift` · `MCPSessions.swift` | MCP tools and progress; resources and subscriptions; sessions and the `/mcp` route |
| `Sources/lift-mcp/LiftMCP.swift`, `Bridge.swift` | the bridge (a testable executable target) |

## Decisions (fold into the spec)

1. **Confirm gate = HTTP 409** with `{error: "confirmation_required", impact}`. 428 means "make the request conditional" (`If-Match`), so it doesn't fit. MCP returns the same JSON as an `isError` result.
2. **Memory warning (spec §8) is a non-error answer.**
   - `jobs_submit` / `jobs_retry` answer **200** `{memory_warning: {message, needed_gb, physical_gb, budget_gb, step}, hint}` and queue nothing.
   - A queued job is **202** (`jobs_retry` moved from 200 to 202 for this).
   - `accept_memory_warning: true` goes in the JSON body (multipart: inside the `job` part). Over MCP it's an argument.
   - MCP returns a plain-text line, then the JSON, with `isError` unset.
3. **One error body, `Problem`:** `{error, message, fields?, impact?, command?, exit_code?, tail?}`.
   - `422 invalid_input` (one entry per field; a body that doesn't match the schema is also 422, with its JSON path)
   - `404 not_found`
   - `409 invalid_state | prerequisite | confirmation_required`
   - `500 command_failed`
   - `401` / `403`
4. **Wire JSON:** snake_case keys, ISO 8601 dates, dictionary keys (setting keys, input names) untouched.
5. **File inputs:** see `Inputs.swift`. Uploads go to `<workdir>/uploads/<uuid>/` and are removed after submit. Multipart parts may have any content type.
6. **Server settings are LiftServer's own** (`<workdir>/server.json`: `port`, `lan_mode`), because Plan 2 doesn't edit LiftCore.
   - `settings_get` returns LiftCore's settings plus these two.
   - `settings_set` with `port` goes to the server (applied at the next start); `lan_mode` changes only through `server_set_lan` (confirm), which rebinds on the same port about 0.3 s later. Open MCP sessions end, and clients start a new one.
7. **Secrets are LiftServer's.**
   - `secrets_set_hf_token` → `LiftServer.secretsSetHFToken`.
   - The app gives LiftCore `LiftConfig(hfToken: secrets.hfTokenReader)`: the stored token, else `$HF_TOKEN`.
   - The LAN token is returned only by `server_set_lan` (enabling) and `server_rotate_token`. `lanToken()` is for the UI.
8. **Recipes:** only `recipes_list` (spec §4: no sources or URLs). Its `recipes` field is passed through as LiftCore returns it.
9. **`jobs_wait`** defaults to 30 s (at most 3600), below common HTTP client timeouts; `GET /v1/jobs/{id}/wait?timeout_seconds=`.
10. **MCP notifications.** swift-sdk 0.12.1 sends all server notifications (progress, resource updates) on the session's GET stream. A client that never opens it gets results but no progress, and notifications sent before the stream connects are not replayed.
11. **Implementation notes that matter.**
    - The server's ServiceGroup runs in a *detached* task: a LAN rebind happens inside a request to the old server, and ServiceLifecycle's task-local shutdown state would otherwise stop the new server at once.
    - The generator percent-encodes header values, so `LocationMiddleware` decodes `Location`.
    - Output names are split by `/`, not `URL`, which can decompose accents.

## Tests (`Tests/LiftServerTests`, Swift Testing)

- `WireTests`: inputs resolution, field errors, problems, snake_case.
- `AccessTests`: loopback, rebinding hosts, LAN and token.
- `HTTPTests`: a real server and real Test Cube install. Covers submit → wait → download; wait with timeout 0; multipart + base64; 422 per field; the confirm gate; docs/openapi; every read route against its schema; the settings round trip.
- `ServerControlTests`: a taken port moves on; the memory warning over HTTP; port and HF token as server settings; LAN mode needing the bearer token; token rotation.
- `MCPTests`: the tool list equals the spec table; submit + wait with progress and outputs as paths/URIs/resource links; resources read; subscriptions; results without the notification stream; gate and bad input as error results; the memory warning as a non-error result; a LAN rebind ending sessions. Also `ToolCatalogTests` (parity, argument derivation) and `ResourceURITests`.
- `BridgeTests`: a real MCP client over pipes ↔ `lift-mcp`'s bridge ↔ the server; the error reply when Lift is down.

Nothing reaches Hugging Face (`OfflineHub` metadata, temp HF cache), nothing touches the Keychain (`MemorySecretStore`), and LAN mode in tests listens on 127.0.0.1 only.

## Commits

Each commit is task-sized and has its tests. The full `swift test` was green before committing: 179 tests in 32 suites (LiftCore 145 + LiftServer 34), and 3 consecutive green runs in the prototype.

- `248b0f3` API document, wire JSON, problems, inputs, secret store, server settings (+ `WireTests`)
- `8ec5e93` HTTP server: `/v1`, `/docs`, auth, LAN + token, port fallback, memory warning (+ `AccessTests`, `HTTPTests`, `ServerControlTests`)
- `db6377c` MCP at `/mcp`: tools, resources, subscriptions, progress (+ `MCPTests`, `ToolCatalogTests`, `ResourceURITests`)
- `f01ba5f` `lift-mcp` bridge (+ `BridgeTests`)
- `96cb9ae` `Package.swift` / `Package.resolved`: the one additive manifest edit, committed alone and last, so every earlier commit's tree still builds. It activates the four commits above.

The CI workflow needs no change: `swift build --build-tests` and `swift test` pick up the new targets. An optional `.build/debug/lift-mcp --help` step was left out, because Plan 2 doesn't touch `.github/`.

## Not done here (owner)

- `models_get` attribution, `models_readme`, and `attribution` in job results (spec §4a). These come with Plan 4's `Recipe.attribution` / `modelsReadme`. Adapter: add the fields to the `ModelView`/`JobView` schemas (responses go through the generated types, so a field missing from the yaml is dropped), plus a `models_readme` operation and its `Tools.handlers` entry.
- `jobs_export` and `export` on `jobs_submit` → Plan 4 (same three places, plus `ToolCatalogTests.specTools`).
- `recipes_list` switches to `recipesList()` when Plan 1's fix pass lands: one line in `Shared.recipes()`.
- `jobs_cancel`'s confirm text ("stops the job immediately; progress is lost") is LiftCore's string (Plan 1).
- Starting the server in the app, copying `lift-mcp` into Lift.app (`bridgePath`), and `xcodebuild … -skipPackagePluginValidation` (OpenAPI generator plugin) → Plan 3.
