# tests/test_intermodal_agent.lex — pure-logic coverage for
# src/intermodal_agent.lex.
#
# lex test discards run_all's return value and only checks whether the call
# raises a runtime error -- see lex-ag-ui's README for the full writeup.
# This file forces a real runtime error when count_failures(...) > 0 so
# lex test/lex ci are real gates here.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-llm/src/tool" as t

import "../src/intermodal_agent" as agent

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn schema_of(name :: Str) -> Option[sch.ModelSchema] {
  match t.find_by_name(agent.make_intermodal_tools("http://127.0.0.1:8100"), name) {
    None => None,
    Some(tool) => Some(tool.params),
  }
}

fn test_three_tools_defined() -> Result[Unit, Str] {
  assert_true(list.len(agent.make_intermodal_tools("http://127.0.0.1:8100")) == 3, "intermodal has 2 routes plus a derived total-exposure convenience, so 3 tools")
}

fn test_declare_terminal_terms_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("site", JStr("port-north")), ("rate_eur_day", JFloat(50.0)), ("free_hours", JFloat(2.0))])
  match schema_of("declare_terminal_terms") {
    None => Err("declare_terminal_terms tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("declare_terminal_terms's schema must accept intermodal.lex's documented POST /intermodal/terms body"),
      Ok(_) => pass(),
    },
  }
}

fn test_declare_terminal_terms_schema_requires_rate() -> Result[Unit, Str] {
  let bad := JObj([("site", JStr("port-north"))])
  match schema_of("declare_terminal_terms") {
    None => Err("declare_terminal_terms tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("declare_terminal_terms's schema must require rate_eur_day"),
    },
  }
}

fn test_get_demurrage_report_schema_requires_container_ref() -> Result[Unit, Str] {
  match schema_of("get_demurrage_report") {
    None => Err("get_demurrage_report tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("get_demurrage_report's schema must require container_ref"),
    },
  }
}

fn test_get_total_exposure_schema_requires_container_ref() -> Result[Unit, Str] {
  match schema_of("get_total_exposure") {
    None => Err("get_total_exposure tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("get_total_exposure's schema must require container_ref"),
    },
  }
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_three_tools_defined(), test_declare_terminal_terms_schema_accepts_documented_shape(), test_declare_terminal_terms_schema_requires_rate(), test_get_demurrage_report_schema_requires_container_ref(), test_get_total_exposure_schema_requires_container_ref()]
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn run_all() -> Int {
  let failures := count_failures(suite_pure())
  let _crash_if_failed := if failures > 0 {
    1 / 0
  } else {
    0
  }
  failures
}

