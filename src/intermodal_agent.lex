# intermodal_agent.lex — an LLM-driven agent persona that operates THIS
# pack's own REST service (intermodal.lex's /intermodal/* routes).
#
# Same loopback-HTTP pattern as lex-pack-construction/src/construction_agent.lex.
# Intermodal has no external backend to wrap (queries the local events table
# directly, no outbound HTTP) -- its mount() IS the domain logic.

import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

fn http_post_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req1 := http.with_header(req0, "Content-Type", "application/json")
  let req := if str.is_empty(tenant) {
    req1
  } else {
    http.with_header(req1, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  let req := if str.is_empty(tenant) {
    base
  } else {
    http.with_header(base, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Capability ────────────────────────────────────────────────────────────────
fn intermodal_capability() -> cap.Capability {
  cap.inbound("handle", "Operate container/terminal dwell tracking: declare a terminal's demurrage terms and report a container's dwell and demurrage exposure.", { title: "IntermodalOps", description: "Inbound message for the intermodal ops agent.", fields: [sch.required_str("text", [])] })
}

# ── Tools (self — this pack's own REST routes, no external backend) ──────────
fn make_intermodal_tools(self_base_url :: Str) -> List[t.Tool] {
  [t.define("declare_terminal_terms", "Set or update a terminal's commercial terms: free hours before demurrage starts accruing, and the daily rate once it does.", { title: "DeclareTerminalTerms", description: "Terminal terms declaration.", fields: [sch.required_str("site", []), sch.required_float("rate_eur_day", []), sch.optional(sch.required_float("free_hours", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/intermodal/terms"), jv.stringify(args), ""))
  }), t.define("get_demurrage_report", "Get a container's full demurrage report: every gate movement, per-terminal stays with dwell hours vs free hours and the resulting charge, the running total, and whether the custody chain is intact.", { title: "GetDemurrageReport", description: "Demurrage report lookup.", fields: [sch.required_str("container_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.join([self_base_url, "/intermodal/containers/", jstr(args, "container_ref"), "/demurrage"], ""), ""))
  }), t.define("get_total_exposure", "Quick check of just a container's total demurrage exposure in EUR and whether the chain is intact, without the full stay-by-stay breakdown.", { title: "GetTotalExposure", description: "Total demurrage exposure.", fields: [sch.required_str("container_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let j := http_get_json(str.join([self_base_url, "/intermodal/containers/", jstr(args, "container_ref"), "/demurrage"], ""), "")
    Ok(JObj([("container_ref", JStr(jstr(j, "container_ref"))), ("total_demurrage_eur", match jv.get_field(j, "total_demurrage_eur") {
      Some(v) => v,
      None => JFloat(0.0),
    }), ("chain_intact", match jv.get_field(j, "chain_intact") {
      Some(v) => v,
      None => JBool(false),
    })]))
  })]
}

# ── System prompt ──────────────────────────────────────────────────────────────
fn intermodal_system_prompt(id :: Str) -> Str {
  str.join(["You are intermodal ops agent ", id, ". You track container dwell time at terminals and the demurrage charges it triggers.", " Use declare_terminal_terms to set a terminal's free hours and daily rate, get_demurrage_report for the full stay-by-stay breakdown with evidence, and get_total_exposure for a quick EUR figure without the detail.", " Be precise about container_ref and site, and always name the specific container/terminal you reported on."], "")
}

# ── Agent factory (the persona builder the pack mounts) ────────────────────────
fn make_intermodal_def(db :: Db, id :: Str, base_url :: Str, self_base_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := intermodal_capability()
  let cfg := { id: id, kind: "intermodal-ops", system_prompt: intermodal_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "self_url", url: self_base_url }], intent_roles: [], tools: make_intermodal_tools(self_base_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("Intermodal ops agent ", id), "0.1.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

