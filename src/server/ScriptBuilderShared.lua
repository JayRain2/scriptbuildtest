-- Shared compile queue between Main's parallel worker (an Actor
-- script) and Sandbox's compile step. Only strings, numbers and
-- booleans live here: SharedTables reject regular tables.
-- Protocol: Sandbox claims the slot (reqBusy = true last, after
-- writing the source), the worker writes the result
-- (resKind/resBytecode/resError, then resDone = true last),
-- Sandbox reads the result and frees the slot (reqBusy = false).
-- resKind is "ok", "sourceError" (bad script, report it), or
-- "workerError" (the worker itself failed, fall back to
-- main-thread compile). Anything missing, busy, or slow also
-- falls back: a broken worker can never break running scripts,
-- it can only cost the freeze it was meant to remove.
local shared = SharedTable.new()
shared.reqBusy = false
shared.reqId = 0
shared.reqSource = ""
shared.resDone = false
shared.resKind = ""
shared.resBytecode = ""
shared.resError = ""
return shared
