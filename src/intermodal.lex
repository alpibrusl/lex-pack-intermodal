# intermodal.lex — container custody + demurrage evidence (intermodal pack, #125).
#
# The relay model, extended to ports and rail: a CONTAINER is a trailer_ref on
# the same signed custody chain, a TERMINAL is any site that has declared its
# commercial TERMS (free hours + demurrage rate), and a gate movement is just a
# custody handoff — gate-in is the handoff TO the terminal, gate-out is the
# next handoff away from it. Berth/gate slot capacity reuses the lex-tms
# swap-slot inventory unchanged (atomic booking, #109).
#
# Demurrage is where disputes live, so it is derived, never asserted: dwell is
# the timestamp difference between two DUAL-SIGNED gate events, the chain's
# integrity is re-verified on every read, and the report shows the signatures
# next to the euros. A contested case escalates through the existing custody
# dispute route.
#
#   POST /intermodal/terms                        — declare a terminal {site, free_hours, rate_eur_day}
#   GET  /intermodal/containers/:ref/demurrage    — dwell + chargeable days per terminal, evidence attached
#
# Domain pack over the lex-soft core + custody pack events. Zero core changes.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.float" as float

import "std.time" as time

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-trail/attest" as attest

import "lex-soft/src/settlement" as settlement

import "lex-soft/src/positions" as pos

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jnum(j :: jv.Json, key :: Str, dflt :: Float) -> Float {
  match jv.get_field(j, key) {
    Some(JFloat(v)) => v,
    Some(JInt(n)) => int.to_float(n),
    Some(JStr(s)) => match jv.parse(s) {
      Ok(JFloat(v)) => v,
      Ok(JInt(n)) => int.to_float(n),
      _ => dflt,
    },
    _ => dflt,
  }
}

fn row_str(row :: sql.Row, k :: Str) -> Str {
  match sql.get_str(row, k) {
    Some(v) => v,
    None => "",
  }
}

fn row_float(row :: sql.Row, k :: Str) -> Float {
  match sql.get_float(row, k) {
    Some(v) => v,
    None => 0.0,
  }
}

fn row_int(row :: sql.Row, k :: Str) -> Int {
  match sql.get_int(row, k) {
    Some(v) => v,
    None => 0,
  }
}

# Portable DDL (SQLite + Postgres): TEXT / DOUBLE PRECISION / BIGINT only.
# NOT REAL: lex's Postgres driver binds PFloat as Rust f64 (float8), which
# tokio-postgres refuses to serialize against a REAL (float4) column — see
# reference_lex_postgres memory. The ALTERs below widen an already-deployed
# table in place (no-op on SQLite; no-op on Postgres once already widened).
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __t := sql.exec(db, "CREATE TABLE IF NOT EXISTS intermodal_terms (site TEXT PRIMARY KEY, free_hours DOUBLE PRECISION NOT NULL, rate_eur_day DOUBLE PRECISION NOT NULL, created_ms BIGINT NOT NULL)", [])
  let __fh := sql.exec(db, "ALTER TABLE intermodal_terms ALTER COLUMN free_hours TYPE DOUBLE PRECISION", [])
  let __rd := sql.exec(db, "ALTER TABLE intermodal_terms ALTER COLUMN rate_eur_day TYPE DOUBLE PRECISION", [])
  ()
}

type Terms = { free_hours :: Float, rate_eur_day :: Float }

fn terms_for(db :: Db, site :: Str) -> [sql] Option[Terms] {
  match sql.query(db, "SELECT free_hours, rate_eur_day FROM intermodal_terms WHERE site = ?", [PStr(site)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some({ free_hours: row_float(row, "free_hours"), rate_eur_day: row_float(row, "rate_eur_day") }),
    },
  }
}

# One gate movement: a custody.handoff event of this container, with its
# dual-signature evidence attached (same attestation chain the journey
# endpoint verifies — "custody.sign" entries carry by/role/sig).
type Gate = { event_id :: Str, ts_ms :: Int, site :: Str, to_agent :: Str, mode :: Str, signatures :: Int }

fn gates_for(db :: Db, log :: tlog.Log, container_ref :: Str) -> [sql] List[Gate] {
  let pat := str.concat("%\"trailer_ref\":", str.concat(jv.stringify(JStr(container_ref)), "%"))
  let rows := match sql.query(db, "SELECT id, payload_json, ts_ms FROM events WHERE kind='custody.handoff' AND payload_json LIKE ? ORDER BY ts_ms ASC", [PStr(pat)]) {
    Err(_) => [],
    Ok(rs) => rs,
  }
  list.map(rows, fn (row :: sql.Row) -> [sql] Gate {
    let payload := match jv.parse(row_str(row, "payload_json")) {
      Err(_) => JObj([]),
      Ok(v) => v,
    }
    let id := row_str(row, "id")
    let sigs := match attest.chain(log, id) {
      Err(_) => 0,
      Ok(atts) => list.len(list.filter(atts, fn (a :: attest.Attestation) -> Bool {
        a.kind == "custody.sign"
      })),
    }
    { event_id: id, ts_ms: row_int(row, "ts_ms"), site: jstr(payload, "site"), to_agent: jstr(payload, "to_agent"), mode: jstr(payload, "mode"), signatures: sigs }
  })
}

fn gate_json(g :: Gate) -> jv.Json {
  JObj([("event_id", JStr(g.event_id)), ("ts_ms", JInt(g.ts_ms)), ("site", JStr(g.site)), ("to_agent", JStr(g.to_agent)), ("mode", JStr(g.mode)), ("signatures", JInt(g.signatures))])
}

fn ceil_days(hours :: Float) -> Int {
  let d := hours / 24.0
  let n := float.to_int(d)
  if int.to_float(n) < d {
    n + 1
  } else {
    n
  }
}

# A terminal stay: gate-in is the handoff TO a terms-declared site; gate-out is
# the NEXT handoff of the container (whatever mode carries it away); an open
# stay (no later handoff) is billed against now — that is what a demurrage
# clock is.
fn stay_json(db :: Db, gate_in :: Gate, gate_out :: Option[Gate], now_ms :: Int, terms :: Terms) -> jv.Json {
  let end_ms := match gate_out {
    Some(g) => g.ts_ms,
    None => now_ms,
  }
  let dwell_h := int.to_float(end_ms - gate_in.ts_ms) / 3600000.0
  let over_h := dwell_h - terms.free_hours
  let days := if over_h > 0.0 {
    ceil_days(over_h)
  } else {
    0
  }
  let out_json := match gate_out {
    Some(g) => gate_json(g),
    None => JNull,
  }
  JObj([("site", JStr(gate_in.site)), ("gate_in", gate_json(gate_in)), ("gate_out", out_json), ("open", JBool(match gate_out {
    Some(_) => false,
    None => true,
  })), ("dwell_hours", JFloat(dwell_h)), ("free_hours", JFloat(terms.free_hours)), ("chargeable_days", JInt(days)), ("rate_eur_day", JFloat(terms.rate_eur_day)), ("demurrage_eur", JFloat(int.to_float(days) * terms.rate_eur_day))])
}

# Walk the gate sequence and pair each terminal arrival with the next
# departure. Plain recursion over the list (no mutation in lex).
fn stays(db :: Db, gates :: List[Gate], now_ms :: Int) -> [sql] List[jv.Json] {
  match list.head(gates) {
    None => [],
    Some(head) => {
      let rest := list.tail(gates)
      let here := match terms_for(db, head.site) {
        None => [],
        Some(t) => [stay_json(db, head, list.head(rest), now_ms, t)],
      }
      list.concat(here, stays(db, rest, now_ms))
    },
  }
}

fn mount(r :: router.Router, db :: Db) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let with_terms := router.route_effectful(r, "POST", "/intermodal/terms", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let site := jstr(j, "site")
        let rate := jnum(j, "rate_eur_day", -1.0)
        if str.is_empty(site) or rate < 0.0 {
          resp.bad_request("{\"error\":\"site and a rate_eur_day >= 0 are required\"}")
        } else {
          let free := jnum(j, "free_hours", 0.0)
          let stmt := "INSERT INTO intermodal_terms (site, free_hours, rate_eur_day, created_ms) VALUES (?, ?, ?, ?) ON CONFLICT (site) DO UPDATE SET free_hours = ?, rate_eur_day = ?"
          match sql.exec(db, stmt, [PStr(site), PFloat(free), PFloat(rate), PInt(time.now_ms()), PFloat(free), PFloat(rate)]) {
            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
            Ok(_) => {
              let log := settlement.trail_on(db)
              let payload := jv.stringify(JObj([("site", JStr(site)), ("free_hours", JFloat(free)), ("rate_eur_day", JFloat(rate))]))
              let __e := tlog.append(log, "intermodal.terms", None, payload)
              resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("site", JStr(site)), ("free_hours", JFloat(free)), ("rate_eur_day", JFloat(rate))])))
            },
          }
        }
      },
    }
  })
  router.route_effectful(with_terms, "GET", "/intermodal/containers/:ref/demurrage", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    let log := settlement.trail_on(db)
    let gates := gates_for(db, log, ref)
    match list.head(list.reverse(gates)) {
      None => resp.json_status(404, "{\"error\":\"no custody events for this container\"}"),
      Some(tip) => {
        let intact := settlement.verify(log, tip.event_id)
        let items := stays(db, gates, time.now_ms())
        let total := list.fold(items, 0.0, fn (acc :: Float, s :: jv.Json) -> Float {
          acc + jnum(s, "demurrage_eur", 0.0)
        })
        resp.json(jv.stringify(JObj([("container_ref", JStr(ref)), ("movements", JList(list.map(gates, fn (g :: Gate) -> jv.Json {
          gate_json(g)
        }))), ("terminal_stays", JList(items)), ("total_demurrage_eur", JFloat(total)), ("chain_intact", JBool(intact))])))
      },
    }
  })
}

# The domain vocabulary this pack speaks, in the engine's position words
# (lex-soft/src/positions). Dwell terms are reported, never settled — settles is
# false, and an onboarding surface should not offer a settler here.
fn manifest() -> pos.PackManifest {
  { id: "intermodal", title: "Intermodal", tagline: "Free time then a per-period charge, computed from the custody record rather than asserted.", pattern: "dwell_terms", subject: "container", subject_ref_field: "container_ref", custody_ref_field: "trailer_ref", parties: [{ position: "custodian", name: "site", title: "Site — declares the free hours and the per-day rate", field: "site", required: true }, { position: "custodian", name: "holder", title: "Holder — takes the subject on at a gate event", field: "to_agent", required: false }, { position: "observer", name: "counterparty", title: "Counterparty — reads the accrued dwell without acting", field: "", required: false }], relationships: [{ from: "holder", to: "site", role: "custody", label: "gate events move the subject in and out of the site" }, { from: "site", to: "counterparty", role: "reporting", label: "accrued dwell is reported to the counterparty" }], event_kinds: ["intermodal.terms"], evidence_kinds: ["gate_event", "custody_signature"], settles: false, route_prefix: "/intermodal" }
}

