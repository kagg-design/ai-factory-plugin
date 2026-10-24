# Ordinary Asana add tasks remain open after Factory completion

Authorized by Igor in this Factory development chat on 2026-10-24.

Native add intake preserves the Asana source ID/URL, but does not enable the
legacy Asana worker-question mode. Completion was tied to that legacy mode.
Do not change worker communication to fix source completion.

Emit one durable attention edge for the existing Factory orchestrator after an
ordinary Asana-source task reaches native done with matching publication evidence.
The orchestrator uses its authorized browser to complete the original card and
records freshly observed completion through a native receipt command. No new
API/token transport or connector is introduced. ROCK-owned tasks stay with the
ROCK coordinator. Local/foreign sources and failed/held/unpublished work do not
qualify. Repeated receipt delivery must be idempotent and preserve Factory flags.
