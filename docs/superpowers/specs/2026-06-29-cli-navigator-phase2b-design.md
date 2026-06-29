# CLI Navigator Phase 2b — Design

**Status:** approved design, pre-plan. Builds on the merged navigator (#228, `src/bin/ui`).

## Goal

Expose the remaining useful Z-Wave / MQTT config from the CLI, in two parts:

- **Part A — env-backed `zwave.*` keys as snap config.** The Z-Wave serial port and the S2/S0 security keys are env-var-backed in ZUI (`ZWAVE_PORT`, `KEY_S2_*`, `KEY_S0_Legacy`). Add them to the snap **catalog + `env-wrapper`** so they flow through `snap set` → the `configure` hook → and the navigator's existing Settings section (§2) — the snap-native path, no new edit code. Add a catalog **`scope`** so `help`'s table stays lean (`common` only) while the navigator shows all (`common` + `advanced`).
- **Part B — MQTT broker `settings.json` editor.** The MQTT broker connection (`mqtt.host`/`port`/`auth`/`username`/`password`) has **no env var** — it lives only in `settings.json`. Add a new navigator section that reads/writes `$SNAP_DATA/settings.json` `mqtt.*` via `yq`, reusing §2's guided pattern (no `nano`, no raw JSON).

**Descriptions for the new keys are intentionally omitted.** Verified there is no machine-readable source to derive them: ZUI has no JSON-schema/OpenAPI, does not use Zod (`process.env.X || default` in `api/config/app.ts`; plain TS `interface`s in `api/config/store.ts`), and its docsify docs are hand-written (`generateDocs.ts` only emits the MQTT *API-method* reference from JSDoc). The exposed set is a small, curated ~12 keys, so hand-authoring the key+type list *is* the curation.

## Context (reused, not duplicated)

- `src/bin/ui` (merged #228): §2 Settings is catalog-driven — browse `key = value` → detail → typed edit (`bool`→`ui_choose`, secret→`ui_input --password`, else `ui_input`) → `snapctl set/unset` → `configure` hook validates → `ui_ok`/`ui_err`. `nav_set_apply` surfaces the hook verdict; `session.secret` is masked.
- `src/helper/catalog`: `settings_catalog` (TSV: `key  type  default  description`), `catalog_keys`, `catalog_row`.
- `src/bin/help`: `settings_rows` renders the catalog into the help table.
- `src/helper/env-wrapper`: `X=$(snapctl get <key>); export X` per setting (with the `MQTT_NAME` empty→`unset` idiom).

## Part A — env-backed `zwave.*` keys

**Catalog schema change:** add two things to `settings_catalog`'s rows —
1. a **`scope`** field (`common` | `advanced`); all 14 existing keys become `common`.
2. a **`secret`** `type` value (alongside `string`/`int`/`bool`) for masked keys; **`session.secret` changes `type` `string`→`secret`**, generalizing §2's hardcoded `[ "$key" = session.secret ]` masking into "mask + `--password` when `type=secret`".

New `advanced` rows (description omitted = empty field):

| snap key | type | → env var (`env-wrapper`) |
|---|---|---|
| `zwave.serial-port` | string | `ZWAVE_PORT` |
| `zwave.s2-unauthenticated` | secret | `KEY_S2_Unauthenticated` |
| `zwave.s2-authenticated` | secret | `KEY_S2_Authenticated` |
| `zwave.s2-access-control` | secret | `KEY_S2_AccessControl` |
| `zwave.s2-lr-authenticated` | secret | `KEY_LR_S2_Authenticated` |
| `zwave.s2-lr-access-control` | secret | `KEY_LR_S2_AccessControl` |
| `zwave.s0-legacy` | secret | `KEY_S0_Legacy` |

- **`env-wrapper`:** add `V=$(snapctl get zwave.serial-port); [ -n "$V" ] && export ZWAVE_PORT="$V"` (and the 6 `KEY_*`), unsetting/omitting when empty (the `MQTT_NAME` pattern) so an unset snap key doesn't force-blank a value ZUI set elsewhere.
- **`help`:** `settings_rows` filters to `scope=common` → the 7 advanced keys never bloat the help table.
- **Navigator §2:** lists ALL catalog keys (common + advanced); `type=secret` keys are masked in the list/detail and edited via `ui_input --password`. No other §2 change — the existing `snapctl set`→`configure` path handles the new keys.
- **`configure` hook:** no change needed (it validates a fixed subset; unknown keys pass through). Optional hex-format validation of the keys is deferred.

## Part B — MQTT broker `settings.json` editor

New navigator section **"MQTT broker"** (a top-level menu item in `main`), editing `$SNAP_DATA/settings.json` `mqtt.*` via `yq`. A small catalog local to `ui`:

| settings.json path | type |
|---|---|
| `mqtt.host` | string |
| `mqtt.port` | int |
| `mqtt.auth` | bool |
| `mqtt.username` | string |
| `mqtt.password` | secret |

(TLS `key`/`cert`/`ca` deferred — niche.)

**Flow** (mirrors §2): list `key = <current>` (read each via `yq` from `settings.json`; `(unset)`/`(hidden)` for secret) → pick → typed edit (`bool`→`ui_choose`, `secret`→`--password`, else `ui_input`) → **atomic write**: render the change into a tempfile copy with `yq`, confirm the tempfile parses (`yq` exit 0), then `mv` over `settings.json` (a broken file is never installed). **Warn — don't block —** if the daemon is running (ZUI rewrites `settings.json` on its own saves, so an edit may be clobbered). After a successful write, `ui_confirm "Restart daemon?"` → the existing `restart` bin.

- Missing `settings.json` (fresh install) → treat as empty `{}`; `yq` creates the `mqtt.*` path on write.
- No `configure` hook here — `settings.json` is ZUI's own file, not snap config. Validation = per-type entry + the `yq`-parses check before the atomic `mv`.

## Error handling

- **Part A:** as §2 — `configure`-hook rejection → `ui_err` + old value kept; secrets masked.
- **Part B:** a failed/invalid `yq` write never replaces the original (atomic tempfile + validate + `mv`); read failure → `ui_err`, return to menu; daemon-running → warn; restart declined → leave as-is. Section loops return to the menu, never `exit`.

## Testing

- **Part A:** update the catalog drift guard (now 5 fields; assert `scope`∈{common,advanced} and `type`∈{string,int,bool,secret}); assert `help`'s `settings_rows` contains the `common` keys and **omits** the `advanced` ones; assert `env-wrapper` exports `ZWAVE_PORT`/`KEY_*` from the corresponding `snapctl get`; assert navigator §2 lists an advanced key and masks a `secret` key (no raw value leaks).
- **Part B:** stub `yq` (read/write) + the daemon-state check; `nav_mqtt`: edit → the exact `yq` write targets `settings.json` `mqtt.<field>`; invalid write → original kept; secret field uses `--password` + masks in the banner; daemon-running → warning shown; restart offered on success. PTY (`script(1)`) where the flow is interactive.
- All suites pass under a normal env **and** `TERM=dumb`; `shellcheck --severity=warning -x` clean.

## Packaging

No new stage-packages (`yq` + `gum` already present). No `nano`.

## Incremental delivery

1. **Part A** — catalog `scope`+`secret` columns, `env-wrapper` mappings, `help` `common` filter, §2 `type=secret` masking. Ships headless device provisioning (serial port + keys) via the existing Settings + `snap set`.
2. **Part B** — the `nav_mqtt` `settings.json` editor. Adds MQTT-broker-from-CLI.

Each is an independently testable deliverable; the navigator stays usable after each.
