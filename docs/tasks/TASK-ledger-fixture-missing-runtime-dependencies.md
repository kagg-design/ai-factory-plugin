# Ledger fixture omits Factory runtime dependencies

Date: 2026-10-23. Observed while checking direct ROCK orchestration.

## Evidence

Base commit: 37aeca7f68d92ee0496f3c03a6ef0495ebd94cad. The original
factory-common.ps1 dot-sources orchestrator-name.ps1 on line 2. The isolated
fixture in tests/state-ledger.tests.ps1:14 copies only factory-common.ps1 and
project-context.ps1 into its synthetic plugin. The copied project-context.ps1
also dot-sources asana-common.ps1. These dependencies are absent in the fixture.

Reproduction, from a complete Factory source checkout with Windows PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

Observed: completed-archive tests pass, then state-ledger fixture initialization
fails because its plugin/scripts/orchestrator-name.ps1 is not recognized as a
script. Test fixture root in this observation:
C:\Users\igerg\AppData\Local\Temp\factory-ledger-8c35fdda811944078fe361dc61e0a06a.
No Factory task/session was involved; this was an isolated synthetic repository.

Expected: the ledger fixture copies the dependency closure required to initialize
its isolated runtime, and the full test entrypoint proceeds into ledger checks.

## Impact and acceptance

The full regression entrypoint stops before checking later suites. Individual
suites can still be run with the complete plugin root. This is a confirmed
fixture-packaging failure; no evidence here establishes a production ledger fault.

- Supply the isolated fixture's required scripts without reading live runtime.
- Run state-ledger.tests.ps1 and tests/run-tests.ps1 in isolation.
- Verify no fixtures gain access to the real project state or services.
- Preserve existing undeclared-removal, locking and recovery assertions.

## Repair

Igor authorized repair in the Factory development chat on 2026-10-23.
The fixture now copies the runtime PowerShell script package, including transitive
dependencies, instead of maintaining an incomplete two-file list. It still patches
only its disposable copy and retains all ledger assertions.

`tests/run-tests.ps1 -LedgerOnly` passed: forced replacement race (12 initializations),
write guards, recovery copies, legitimate rejection, and idle/busy scheduler journal
checks. The idle measurement recorded 15 holds/minute; busy heartbeats made no
ledger writes. The full entrypoint is being checked separately.
