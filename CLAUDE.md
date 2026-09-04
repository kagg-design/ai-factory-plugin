# Repository safety

The ignored `runtime/` directory may contain live factory state, session
metadata, logs, and project configuration. Never delete, move, recreate, or
bulk-clean it as repository housekeeping. Do not run `git clean -x`, `git clean
-X`, or an equivalent ignored-file cleanup in this repository.

Use the factory's scoped cleanup commands only when the user explicitly asks to
remove factory state. Inspect the exact location first with `factory runtime`.
