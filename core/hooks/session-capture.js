#!/usr/bin/env node
// NO-OP SHIM. The session-capture Stop hook was removed and de-registered in
// settings.local.json, but the CURRENT session still has it loaded in memory
// (Claude Code reads hook config only at session start). This stub makes that
// stale registration exit cleanly instead of throwing MODULE_NOT_FOUND.
//
// After you restart Claude Code, the hook is no longer registered and this file
// is never invoked — delete it then (and the empty .claude/hooks/ dir).
try { process.stdin.resume(); process.stdin.on('data', () => {}); } catch (e) {}
process.exit(0);
