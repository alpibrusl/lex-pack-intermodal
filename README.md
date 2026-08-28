# lex-pack-intermodal

Intermodal domain pack — container/terminal dwell and demurrage, derived from gate-event timestamps rather than asserted.

Extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) (see [issue #237](https://github.com/alpibrusl/lex-ev-fleet/issues/237)). Builds on [`lex-pack-custody`](https://github.com/alpibrusl/lex-pack-custody) at the **data** level only: a gate-in/gate-out pair is read straight from the shared `events` table (`kind='custody.handoff'`, keyed by `trailer_ref`) — this pack does not import custody's code or depend on it in `lex.toml`. A deployment mounting both needs custody as its own dependency.

## Routes

```
POST /intermodal/terms                        — declare a terminal {site, free_hours, rate_eur_day}
GET  /intermodal/containers/:ref/demurrage    — dwell + chargeable days per terminal, evidence attached
```

## Usage

```lex
import "lex-pack-intermodal/intermodal" as intermodal

# in your router-wiring code:
let r := intermodal.mount(router.new(), db)
```

`intermodal.manifest()` returns the `pos.PackManifest` describing this pack's parties/pattern for the `lex-soft/src/positions` catalogue. Dwell terms are reported, never settled (`settles: false`).

## Layering

Part of the lex-soft pack family: `lex-soft` (engine, primitives) → this pack (`mount()` for the HTTP routes, `manifest()` for the `lex-soft/src/positions` catalogue) → [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License


Copyright (c) 2026 lex-pack-intermodal contributors.

Licensed under the [EUPL-1.2](LICENSE) — the European Union Public Licence, as used across the `lex-*` ecosystem.

