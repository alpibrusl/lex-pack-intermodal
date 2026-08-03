# tests/test_intermodal.lex — pure-logic coverage for src/intermodal.lex.
#
# ceil_days is the one pure, non-trivial function here (dwell hours -> billable
# whole days, rounded up); the effectful routes (gate events, demurrage report,
# DB) need a live DB to exercise meaningfully — that's covered by
# lex-ev-fleet's own integration testing of the mounted deployment.

import "std.list" as list

import "lex-soft/src/positions" as pos

import "../src/intermodal" as intermodal

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

# ---- ceil_days --------------------------------------------------------------
fn test_ceil_days_exact_days_no_rounding() -> Result[Unit, Str] {
  assert_true(intermodal.ceil_days(48.0) == 2, "an exact multiple of 24 hours must not round up")
}

fn test_ceil_days_partial_day_rounds_up() -> Result[Unit, Str] {
  assert_true(intermodal.ceil_days(25.0) == 2, "any hours past a full day must round up to the next whole day")
}

fn test_ceil_days_less_than_a_day_rounds_up_to_one() -> Result[Unit, Str] {
  assert_true(intermodal.ceil_days(1.0) == 1, "even a single hour over free time bills a full day")
}

fn test_ceil_days_zero_is_zero() -> Result[Unit, Str] {
  assert_true(intermodal.ceil_days(0.0) == 0, "zero over-hours must bill zero days")
}

# ---- manifest() -------------------------------------------------------------
fn test_manifest_is_valid() -> Result[Unit, Str] {
  let m := intermodal.manifest()
  assert_true(list.is_empty(pos.validate(m)), "intermodal's own manifest must satisfy the shared position/pattern validator")
}

fn test_manifest_route_prefix() -> Result[Unit, Str] {
  assert_true(intermodal.manifest().route_prefix == "/intermodal", "manifest route_prefix must match the mounted routes")
}

fn test_manifest_does_not_settle() -> Result[Unit, Str] {
  assert_true(not intermodal.manifest().settles, "demurrage is reported, not settled — the manifest must not advertise a settler")
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_ceil_days_exact_days_no_rounding(), test_ceil_days_partial_day_rounds_up(), test_ceil_days_less_than_a_day_rounds_up_to_one(), test_ceil_days_zero_is_zero(), test_manifest_is_valid(), test_manifest_route_prefix(), test_manifest_does_not_settle()]
}

