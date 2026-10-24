# Direct ROCK CLI: inherited native process encoding

Date: 2026-10-23. Found while executing the authorized Access pilot.

The new public `factory rock cycle` enters a child PowerShell script. That child
inherits Factory functions, so the conditional common loader skips initialization
of its script-scoped UTF-8 encoding. Exact-commit evidence and the real planner
launch then fail with `FactoryUtf8NoBom` unset. Stub model tests did not exercise
this script-scope boundary. No model action or Asana write occurred.

The repair belongs to the requested coordinator implementation: initialize the
encoding in the ROCK entry scope without replacing inherited Factory functions.
A regression invokes the native Git process from a child script with inherited
functions. Saved pilot events remain pending and can continue without state edits.

The pilot also exposed a version boundary: newer PowerShell parses ISO JSON dates
as DateTime, while Windows PowerShell returns strings. Converting the former to a
locale-specific string before parsing can break receipt leases and retry times.
ROCK now preserves typed timestamps and parses ISO strings invariantly. The
coordinator regression performs a real PowerShell 7 browser-claim/receipt roundtrip
under ru-RU as well as the Windows PowerShell fixture run.
