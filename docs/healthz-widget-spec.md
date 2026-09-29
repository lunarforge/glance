# Spec: health monitoring enhancements

Status: **draft** · Branch: `feat/healthz-widget-spec` · Date: 2026-09-29
Related: [glance-health-prompt.md](glance-health-prompt.md) (contract `healthz/v1`, §0)

Two independent changes to this fork:

| | Change | Size | Purpose |
|---|---|---|---|
| **A** | `custom-api`: per-request `allow-failure` | small | One failing subrequest must not blank the whole widget. Useful beyond health. |
| **B** | New native widget `type: healthz` | medium | First-class renderer for `healthz/v1`: per-app failure isolation, status sort, expandable rows, history strip. Replaces the §2 template approach. |

A and B ship as separate PRs. B does not depend on A.

---

## 1. Problem

The prompt pack's §2 builds the "Services" overview as one `custom-api` widget with one
subrequest per app. In the current code that fails at the first outage:

- [widget-custom-api.go:299-338](../internal/glance/widget-custom-api.go#L299-L338) runs the
  primary request and all subrequests under one `context.WithCancel`. The **first error cancels
  every other request**, and the widget renders an error box. So a single unreachable app
  blanks the overview, which is the moment it's needed most.
- [widget-custom-api.go:265-277](../internal/glance/widget-custom-api.go#L265-L277) turns any
  non-2xx response into an error, so the template can't show "503 from app X".
- The template has to sort apps by status, count failing checks, build a 60-cell strip and
  map enums to colours in Go template syntax. That's fragile, hard to test, and has to be
  duplicated for every app on the Details page.
- `--color-warning` doesn't exist, so `degraded` has no native colour (§2 Step 2.3).

§2's own fallback (one `custom-api` widget per app) works around the blanking but loses sorting
and the single-glance overview.

---

## 2. Part A: `custom-api` `allow-failure`

### 2.1 Config

New boolean on `CustomAPIRequest`. It's valid on the primary request and on each subrequest.
The default is `false`, so existing configs behave exactly as before.

```yaml
- type: custom-api
  url: https://api.example.com/main
  subrequests:
    orders:
      url: http://orders:8080/healthz
      allow-failure: true
    payments:
      url: http://payments:8080/healthz
      allow-failure: true
```

### 2.2 Semantics

| Request outcome | `allow-failure: false` (today) | `allow-failure: true` |
|---|---|---|
| 2xx, valid JSON | data | data, `.Failed = false` |
| non-2xx, valid JSON body | widget error | data with body **and** `.Response.StatusCode`, `.Failed = true`, `.Error = "503 Service Unavailable"` |
| non-2xx, empty or non-JSON body | widget error | zero-value `.JSON`, status code kept, `.Failed = true` |
| 2xx, invalid JSON | widget error | zero-value `.JSON`, `.Failed = true`, `.Error = "invalid response JSON"` |
| transport error or timeout | widget error | zero-value `.JSON`, `.Response.StatusCode = 0`, `.Failed = true`, `.Error = <err>` |

- A request with `allow-failure: true` never triggers the shared `cancel()`, and its failure
  never sets the widget-level `err`.
- Requests with `allow-failure: false` keep today's behaviour, including cancelling the others.
- `.Response` must never be `nil`, so templates can read `.Response.StatusCode` without
  guarding. Use a synthetic `&http.Response{}` as the zero-value path at
  [widget-custom-api.go:241-244](../internal/glance/widget-custom-api.go#L241-L244) already does.
- Failures still log through `slog`, at `Warn` rather than `Error`.

### 2.3 Template API additions

Two new fields on `customAPIResponseData`:

```go
Failed bool   // true when the request failed and allow-failure absorbed it
Error  string // human-readable reason; "" when Failed is false
```

Example:

```gohtml
{{ $orders := .Subrequest "orders" }}
{{ if $orders.Failed }}<span class="color-negative">unreachable: {{ $orders.Error }}</span>
{{ else }}{{ $orders.JSON.String "status" }}{{ end }}
```

### 2.4 Out of scope

- A per-request `timeout`. `defaultClientTimeout` (5s) applies. Add it later if needed.
- Retry or backoff.

### 2.5 Tests (`widget-custom-api_test.go`)

- A table covering all five rows of §2.2 × `allow-failure` true and false, using an
  `httptest.Server`.
- A mixed case: one request with `allow-failure: true` fails and one normal request succeeds.
  The widget renders, and the failed request exposes `.Failed` and `.Error`.
- A mixed case: a normal request fails. The widget errors as today, which proves backward
  compatibility.
- A slow allowed-failure request, cut off by the client timeout, doesn't delay or cancel its
  siblings beyond that timeout.

### 2.6 Docs

`docs/configuration.md`: add `allow-failure` to the `custom-api` property table (~line 1584)
and a short `##### allow-failure` subsection after `subrequests` (~line 1736) with the example
from §2.3.

---

## 3. Part B: native `healthz` widget

### 3.1 Config

```yaml
- type: healthz
  title: Services               # default "Services"
  cache: 1m                     # default 1m
  collapse-after: 8             # rows before "show more"; -1 = never; default 8
  sort: status                  # status (default) | config
  history-cells: 60             # strip length; default 60, max 240
  stale-after: 5m               # checked_at older than this → stale badge; default 5m, 0 = off
  expand: failing               # which rows open by default: none | failing (default) | all
  apps:
    - slug: orders              # required, unique within the widget, [a-z0-9-]+
      name: Orders API          # optional; falls back to body.name, then slug
      url: http://orders:8080/healthz # required
      dashboard: http://orders:8081/  # optional; used when body.dashboard_url is absent
      mode: healthz             # healthz (default) | status-code
      allow-insecure: false
      timeout: 5s               # default 5s, max 30s
    - slug: legacy-billing
      url: http://billing:8080/health
      mode: status-code
```

Validation happens in `initialize()` and is a config error that fails load (same as other
widgets):

- `apps` is empty.
- A `slug` is duplicated or doesn't match `[a-z0-9-]+`.
- `url` isn't absolute http(s).
- `mode`, `sort` or `expand` isn't one of the listed values.
- `history-cells` is outside 1..240, or `timeout` is outside 1s..30s.

### 3.2 Fetch

- One fetch per app per update, all concurrent via the existing `workerPoolDo`
  ([widget-utils.go:183](../internal/glance/widget-utils.go#L183)). The per-app timeout comes
  from `timeout`.
- Each app's outcome is independent. **The widget never enters an error state because of an
  app.** `canContinueUpdateAfterHandlingErr` is only used for widget-level faults, which
  should be none after `initialize`.
- Read at most **256 KiB** of the body (`io.LimitReader`). Anything larger counts as `invalid`
  with the message "body exceeds 256 KiB".
- Send `Accept: application/json` and the standard Glance User-Agent.

### 3.3 Row state

Every app resolves to exactly one **row state** during `update()`:

| Row state | `mode: healthz` condition | `mode: status-code` condition | Colour |
|---|---|---|---|
| `down` | body valid, `status == "down"` | status 5xx | `--color-negative` |
| `unreachable` | transport error or timeout | transport error or timeout | `--color-negative` (hollow dot) |
| `invalid` | response isn't a valid `healthz/v1` body (§3.4) | status not 2xx/5xx (e.g. 404, 401) | `--color-negative` (dashed dot) |
| `degraded` | body valid, `status == "degraded"` | n/a | `--color-warning` |
| `ok` | body valid, `status == "ok"` | 2xx | `--color-positive` |

**`stale`** is a modifier, not a state. For a valid `healthz` body, if
`now − checked_at > stale-after`, the row gets a "stale Nm" badge and counts as failing for
sorting and `expand: failing`. This catches the frozen-snapshot failure mode described in the
prompt pack's changelog (a dead self-check loop keeps serving its last `ok`).

**Status codes in `mode: healthz`:** the contract says always 200. A non-200 response with a
valid body is still parsed and shown, with the status code as a note ("HTTP 503"). A non-200
response with an invalid body is `invalid`.

### 3.4 Strict validation (`mode: healthz`)

A body is valid only if every rule below holds. Otherwise the row is `invalid`, and its
expanded view shows the **first** rule that failed, plus a 200-character excerpt of the body.

1. It parses as a JSON object.
2. `schema == "healthz/v1"`.
3. `status` is one of `ok` | `degraded` | `down`.
4. `checked_at` parses as RFC 3339. The contract asks for UTC truncated to the second, but
   fractional seconds and offsets are **accepted** (be liberal in what you accept), and the
   row gets a small "non-canonical timestamp" note.
5. `checks` is an array (may be empty). Each element has a string `name`, a valid `status`
   enum and a bool `critical`.
6. `history`, if present, is an array of `{t, s}` with `s` a valid enum. It's truncated to
   the last `history-cells` entries.

Missing optional fields (`version`, `build`, `uptime_seconds`, `dashboard_url`, `name`,
`app`) are not errors.

**Not re-derived:** the widget shows the app's `status` as reported and doesn't recompute it
from `checks`. If they disagree (e.g. a critical check is `down` but `status` is `ok`), the
row gets a "status/checks mismatch" note. It surfaces the bug without overriding the app.

### 3.5 History

- `mode: healthz`: the strip shows `body.history`, oldest to newest, right-aligned, padded on
  the left with empty cells up to `history-cells`.
- `mode: status-code`: the widget keeps a **local ring buffer** of `history-cells` entries per
  app, appended once per `update()`. It lives in memory, is lost on restart or config reload,
  and is marked as local in the expanded view.
- `unreachable` and `invalid` rows in `mode: healthz` show the body history from the last
  successful fetch, greyed out, with "last seen Nm ago". This is kept in memory only.

### 3.6 Sort

`sort: status` orders rows as follows, then by display name (case-insensitive), with `slug`
as the tie-break:

`down` → `unreachable` → `invalid` → `degraded` → stale `ok` → `ok`

`sort: config` keeps the YAML order.

### 3.7 Rendering

Files: `templates/healthz.html` and `static/css/widget-healthz.css`. The template extends
`widget-base.html` and reuses native classes (`list`, `list-gap-10`, `flex`, `items-center`,
`gap-10`, `size-h4`, `color-primary`, `collapsible-container` with `data-collapse-after`).

**Collapsed row** (one line on desktop, wraps on mobile):

```
●  Orders API        v1.4.2   2m ago   2 failing: nats, smtp   ▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮
```

- Status dot, with a shape per state for colour-blind users: filled, hollow for
  `unreachable`, dashed for `invalid`.
- Name, linked to `body.dashboard_url`, then config `dashboard`, then unlinked.
- Version.
- `checked_at` as relative time via `dynamicRelativeTimeAttrs`, plus a stale badge when it
  applies.
- Failing summary: the count plus names of non-`ok` checks, truncated with an ellipsis. It's
  empty when everything is `ok`.
- History strip: `history-cells` cells, each coloured by state, with a `title` of the
  timestamp and state for hover.

**Expanded row** (`<details>`, open per `expand`):

- Uptime (humanised), `build.commit`, `build.time`.
- Checks table: status dot · name · `critical` marker · `latency_ms` · `message`. Non-`ok`
  checks come first.
- For `unreachable` and `invalid`: the error reason, the HTTP status, and a body excerpt
  (`invalid` only).
- Notes: stale, non-canonical timestamp, status/checks mismatch, local history.

**Widget header summary:** "N ok · N degraded · N down". Unreachable and invalid count as
down.

### 3.8 Colours

Add to the base theme CSS (next to `--color-positive` and `--color-negative`):

```css
--color-warning: hsl(40, 90%, 60%);
```

Define it for both the light and dark theme blocks so custom themes can override it. Nothing
else in the widget CSS uses inline hex. Document `--color-warning` in `docs/themes.md`.

### 3.9 Implementation notes

- **Files:** `internal/glance/widget-healthz.go`, `widget-healthz_test.go`, register
  `case "healthz"` in `widget.go`, `templates/healthz.html`, `static/css/widget-healthz.css`
  (imported where the other widget CSS is), docs section in `docs/configuration.md`.
- **Decode:** `encoding/json` into fixed structs, not gjson. Decode once, validate, and keep
  only what's rendered.
- **Allocation:**
  - Preallocate `rows := make([]healthzRow, 0, len(apps))`.
  - The ring buffer is a fixed-capacity slice allocated once in `initialize()` and reused
    across updates.
  - Precompute every CSS class, display string and sort key in `update()`, so `Render()` does
    no work beyond template execution.
- **Concurrency:** `update()` builds a fresh `[]healthzRow` and swaps it in. Last-seen history
  and ring buffers are only touched inside `update()`, which the widget framework already
  serialises. Verify that assumption against `widgetBase` during implementation.
- **Time:** all comparisons in UTC. `stale` uses the fetch completion time, not render time.

### 3.10 Tests (`widget-healthz_test.go`)

Fixtures live in `test/fixtures/healthz/` and are served by `httptest.Server`. They're shared
with the prompt pack's §2 Step 3.

| Fixture | Expect |
|---|---|
| `ok.json` | `ok`, 60-cell strip |
| `degraded.json` (non-critical `nats` degraded) | `degraded`, "1 failing: nats" |
| `down.json` (critical `postgres` down) | `down`, row sorted first |
| `startup.json` (single `startup` check) | `degraded`, message "initialising" |
| `nano-timestamp.json` | valid, "non-canonical timestamp" note |
| `stale.json` (`checked_at` 1h old) | `ok` + stale badge, sorted above fresh `ok` |
| `mismatch.json` (critical down, status ok) | `ok` + mismatch note |
| `wrong-schema.json` (`healthz/v2`) | `invalid`, reason names rule 2 |
| `bad-enum.json` (`status: "warn"`) | `invalid`, reason names rule 3 |
| `html.txt` served as 200 | `invalid`, rule 1, body excerpt |
| 300 KiB body | `invalid`, size message |
| closed port | `unreachable` |
| handler sleeps past `timeout` | `unreachable` within `timeout` + 100ms; siblings unaffected |
| `mode: status-code`: 200 / 503 / 404 | `ok` / `down` / `invalid`; local ring grows by 1 per update and wraps at `history-cells` |

Plus:

- Config validation table (every rule in §3.1).
- Sort order golden test.
- Render golden HTML for one of each state.
- A benchmark `BenchmarkHealthzUpdate` with 20 apps against a local server, reporting
  allocs/op, to guard the allocation targets in §3.9.

### 3.11 Acceptance criteria

1. With four apps where one is `ok`, one `degraded`, one `down` and one unreachable, the
   widget renders all four rows in the order down, unreachable, degraded, ok. No widget-level
   error.
2. Killing one app process changes only that row, to `unreachable`, on the next update.
3. `go vet`, `go test ./...` and the CI compose smoke job pass.
4. The prompt pack's §2 is updated to use `type: healthz`. The per-app Details page becomes
   optional, since the expanded rows cover it.
5. `docs/configuration.md` documents every property in §3.1 with one full example.

---

## 4. Impact on the prompt pack

After B lands, §2 of [glance-health-prompt.md](glance-health-prompt.md) collapses to:

- **Step 2:** one `healthz` widget listing the registered apps. There are no templates.
- **Step 2.4 failure handling:** handled natively, so remove the fallback paragraph.
- **Step 3 validate:** reuse `test/fixtures/healthz/`.
- **§3 registration line** maps 1:1 to an `apps[]` entry (`slug`, `name`, `url`, `dashboard`).

`custom-api` with `allow-failure` (A) remains the escape hatch for non-contract JSON sources.

---

## 5. Open questions

1. **Receiver naming.** This repo uses `widget` as the receiver name throughout. The author's
   global preference is `h`. Proposal: follow the repo (`widget`) in the fork, to keep upstream
   merges and diffs clean.
2. **Upstreaming.** Is A worth offering to `glanceapp/glance` as a PR? It's generic and small.
   B is probably fork-only.
3. **Persisting history for `status-code` mode.** Is an in-memory ring (lost on restart)
   enough, or should it be kept? Glance has no datastore today, so persistence would add one.
4. **Sort of `invalid` vs `degraded`.** An `invalid` row is usually a deploy or contract bug
   rather than an outage. Is ranking it above `degraded` right?
