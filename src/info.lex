# info.lex — the intermodal agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of this pack's REST pos.PackManifest: how a
# console should PRESENT the intermodal-ops persona — label, tagline, starter
# prompts. Served by the host under /platform/packs's agent_packs field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "intermodal", title: "Intermodal", tagline: "Container dwell and demurrage, derived from gate-event timestamps rather than asserted.", personas: [{ kind: "intermodal-ops", title: "Intermodal ops", tagline: "Sets terminal terms and reports container dwell/demurrage exposure.", suggested_prompts: ["Set terminal terms for site port-north: 2 free hours, 50 EUR/day after.", "Get the demurrage report for container CNT-100.", "What is the total demurrage exposure for container CNT-100?"] }] }
}

