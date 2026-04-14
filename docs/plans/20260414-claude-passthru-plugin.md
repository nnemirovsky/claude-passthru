# claude-passthru Plugin Implementation

## Overview

Ship a Claude Code plugin named `passthru` (repo `claude-passthru`) that supplements the native permission system with regex rules the native glob syntax cannot express (directory prefixes, sub-arg matching, partial URL/path patterns, MCP tool namespaces). A `PreToolUse` hook reads merged user-scope + project-scope rule files and returns allow/deny decisions, bypassing the native permission dialog on match and falling through to it on miss. Works across all tools (Bash, PowerShell, Read, Edit, WebFetch, MCP tools, etc.), not just Bash.

Problem it solves:
- Native `Bash(prefix:*)` rules require a space-delimited token boundary after the prefix, so `Bash(bash /path/to/dir/:*)` cannot match `bash /path/to/dir/script.sh`. Confirmed in source at `src/tools/BashTool/bashPermissions.ts:894-911` (word-boundary check).
- Glob patterns cannot express `gh api /repos/[^/]+/[^/]+/forks` or similar shape-aware rules.
- No native way to blanket-allow MCP tool families like `mcp__gemini-cli__*`.

Integration: existing native rules in `~/.claude/settings.json` + `.claude/settings.local.json` are untouched. The hook runs first; if no passthru rule matches, execution passes through to native rules unchanged. A one-time bootstrap script seeds the passthru rule files from existing native allow lists so users do not start from zero. A dedicated verifier checks rule correctness (regex validity, schema, overlap, shadowing) across all scopes in one pass, invoked both manually via `/passthru:verify` and automatically after every LLM- or bootstrap-driven rule write.

Slash commands are plugin-namespaced via the colon convention Claude Code uses (same as `/planning:make`, `/release-tools:new`, `/ticktock:ticktock`). File name `commands/<name>.md` is exposed as `/passthru:<name>`. Our commands: `/passthru:add`, `/passthru:suggest`, `/passthru:verify`, `/passthru:log`.

Optional audit log: when the sentinel file `~/.claude/passthru.audit.enabled` exists, the plugin records every tool-call permission decision to `~/.claude/passthru-audit.log` as JSONL. The PreToolUse handler logs its own `allow` / `deny` / `passthrough` decisions; a companion PostToolUse handler classifies passthrough outcomes (native dialog) into `asked_allowed_once`, `asked_allowed_always`, `asked_denied_once`, `asked_denied_always`, or `asked_allowed_unknown` by diffing `settings.json` snapshots captured in a PreToolUse breadcrumb. Audit is **off by default** and imposes zero runtime cost when disabled (single `-e sentinel` check, then exit). `/passthru:log` renders the log as a filtered, colorized table and also toggles the sentinel via `--enable` / `--disable` / `--status`.

## Context (from discovery)

Files/components involved:
- `/Users/nemirovsky/Developer/claude-passthru/` (new repo, empty).
- Reference layout: `/Users/nemirovsky/Developer/ticktock/` (hooks.json at `hooks/hooks.json`, handlers at `hooks/handlers/*.sh`, shared `common.sh`). Only repo structure referenced; plugin structure self-designed.
- Reference release workflow: `/Users/nemirovsky/Developer/sluice/CLAUDE.md` section "Releases" (uses `release-tools:new` skill, tag format `vX.Y.Z`, minor default). Our plugin reuses this pattern and adds a version-bump step for `plugin.json` + `marketplace.json`.
- Relevant Claude Code internals read during brainstorming (not modified):
  - `src/tools/BashTool/bashPermissions.ts:894-911` - word-boundary check that blocks directory-prefix rules.
  - `src/utils/bash/commands.ts:265-369` - compound command splitting (irrelevant to passthru because we do not split).
  - `src/utils/hooks/execAgentHook.ts:133` - agent hooks run non-interactively, so `AskUserQuestion` is not usable from hooks.
  - `src/screens/REPL.tsx:2360+` - permission dialog is hardcoded React, no custom buttons possible.

Related patterns found:
- Hook JSON schema documented in `update-config` skill and Claude Code settings schema.
- Existing community hooks (kornysietsma/claude-code-permissions-hook, hirano00o/gatehook) solve half the problem but lack scope merging and plugin packaging.

Dependencies identified:
- `bash` 4.0+, `jq`, PCRE regex engine (via `grep -P` on GNU systems or `perl` fallback on BSD/macOS where grep lacks `-P`). `bats-core` for tests. All available on macOS/Linux by default (perl is preinstalled).

## Development Approach

- **Testing approach:** Regular (code + tests together). Each task writes code and tests in the same iteration; both must pass before the next task.
- **Branch strategy during development:** Work on `main` locally. The repo is not pushed anywhere until Task 12. No feature branches, no PRs during initial build - single-contributor bootstrap. Once Task 12 pushes to GitHub and enables branch protection, subsequent work MUST use PRs.
- Complete each task fully before moving to the next.
- Make small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task.
  - Tests are not optional.
  - Bats for shell code, manual verification for markdown slash commands (prompt-based, not unit-testable beyond frontmatter).
  - Cover success and error/edge scenarios.
- **CRITICAL: all tests must pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**
- Run tests after each change.

## Testing Strategy

- **Unit tests:** Bats tests for every shell function. Handler scripts tested by piping synthetic JSON payloads on stdin and asserting stdout JSON + exit code. Rule-file merge/validation tested with fixture files in `tests/fixtures/`.
- **Verifier coverage:** the standalone `scripts/verify.sh` has its own bats suite exercising every failure mode (bad JSON, bad regex, duplicate, conflict, shadow). The write wrapper (`scripts/write-rule.sh`) has bats tests for atomic backup + rollback on verifier failure.
- **Slash command coverage:** frontmatter lint tests (required keys present) + manual test scripts for behavioral verification. The slash commands themselves are thin orchestration layers over the shell scripts.
- **No e2e tests:** This is a config+hook plugin; there is no UI. End-to-end verification is a manual `claude --debug` check after install, documented in the acceptance-criteria task.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with a `+` prefix.
- Document issues/blockers with a `!!` prefix.
- Update plan if implementation deviates from original scope.

## Solution Overview

Architecture:
```
Claude Code tool call
      |
      v
PreToolUse hook (matcher: "*") --> pre-tool-use.sh
      |
      v
   common.sh: load passthru.json + passthru.imported.json from each scope, merge, validate
      |
      v
   common.sh: iterate deny[], then allow[]; match_rule(tool_name, tool_input, rule)
      |
   +---- match in deny  --> print {permissionDecision: "deny", ...}; exit 0
   |
   +---- match in allow --> print {permissionDecision: "allow", reason}; exit 0
   |
   +---- no match       --> print {"continue": true}; exit 0  --> native permission system takes over

Write paths (bootstrap.sh, /passthru:add, /passthru:suggest) call scripts/write-rule.sh,
which takes a backup, appends the rule, runs scripts/verify.sh, and restores the backup
on verifier failure. The user can also invoke /passthru:verify or scripts/verify.sh directly.
```

Rule matching semantics:
- `tool` field is a regex matched against `tool_name` (e.g., `Bash`, `PowerShell`, `mcp__gemini-cli__ask-gemini`). Absent = match any tool.
- `match` field is an object keyed by `tool_input` field names; each value is a PCRE regex that must match the corresponding input field. All keys must match (AND). Absent/empty `match` = match any call to the tool.
- Deny has priority over allow. First deny match short-circuits with deny. First allow match after deny check short-circuits with allow.
- Merge semantics: deny and allow arrays from all four files (user `passthru.json`, user `passthru.imported.json`, project `passthru.json`, project `passthru.imported.json`) are concatenated. Both scopes contribute; neither overrides.

Key design decisions:
- **Shell-based handler** (not Rust/Node): zero install friction, matches ticktock convention, easy to audit. jq + grep -P cover all needs.
- **Dedicated verifier** (`scripts/verify.sh`): deterministic correctness checks in one pass across all scopes. Invoked automatically on every write (via `write-rule.sh`) and on demand via `/passthru:verify`. Catches errors before they reach the hot path, so the hook-time loader can stay fast (parse + minimal schema check only).
- **Atomic write wrapper** (`scripts/write-rule.sh`): isolates backup + append + verify + rollback into one deterministic shell script. Slash command prompts cannot reliably roll back via in-session variables (plan review finding), so the correctness lives in shell and the prompt only orchestrates.
- **Separate imported-rules file** per scope (`passthru.imported.json`): bootstrap never touches user-authored `passthru.json`, so re-imports are idempotent.
- **Single rule file per scope for user-authored rules**: simpler than multiple files. JSON so it mirrors `settings.json` format tools users already know.
- **Hybrid visibility**: on allow, we emit `permissionDecisionReason` so the decision appears in the transcript (visible when user opens it) but does not clutter the focus view. Achieved for free via the native hook schema - no extra flag needed.
- **Slash commands as in-session prompts**: markdown files with frontmatter. Current session's Claude model handles the prompt (no API key, no `claude -p` spawn). Namespaced via the `/passthru:<name>` plugin-command convention.
- **Passthrough on no match**: exit 0 with `{"continue": true}` means the native permission system runs unchanged. Existing rules keep working.
- **Plain ASCII everywhere**: per project writing rules, no em-dashes, arrows, or Unicode symbols in code, docs, or script output. ASCII equivalents only (`->`, `--`, `[OK]`, `[ERR]`).

## Technical Details

Rule file schema (all four scope files use the same shape):

```json
{
  "version": 1,
  "allow": [
    {
      "tool": "Bash|PowerShell",
      "match": { "command": "^bash /Users/[^/]+/\\.claude/plugins/cache/umputun-cc-thingz/" },
      "reason": "cc-thingz plugin scripts"
    },
    {
      "tool": "Read",
      "match": { "file_path": "^/Users/nemirovsky/Developer/" }
    },
    {
      "tool": "WebFetch",
      "match": { "url": "^https?://(github\\.com|docs\\.anthropic\\.com)" }
    },
    {
      "tool": "^mcp__gemini-cli__",
      "reason": "all gemini mcp calls"
    }
  ],
  "deny": [
    {
      "tool": "Bash|PowerShell",
      "match": { "command": "rm\\s+-rf\\s+/" }
    }
  ]
}
```

Hook JSON output format (per Claude Code hook schema):

Allow:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "passthru allow: cc-thingz plugin scripts"
  }
}
```

Deny:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "passthru deny: matched rule [rm -rf /]"
  }
}
```

Passthrough: stdout `{"continue": true}`, exit 0.

File locations:
- User scope: `~/.claude/passthru.json` (hand-authored) + `~/.claude/passthru.imported.json` (bootstrap output)
- Project scope: `$CWD/.claude/passthru.json` + `$CWD/.claude/passthru.imported.json`
- Plugin root via env: `$CLAUDE_PLUGIN_ROOT`

## What Goes Where

- **Implementation Steps** (checkboxes): plugin code, hook handler, common library, verifier, write wrapper, slash commands, bootstrap script, tests, README.
- **Post-Completion** (no checkboxes): manual install + `claude --debug` verification, listing on a marketplace if desired.

## Implementation Steps

### Task 1: Plugin skeleton and manifests

**Files:**
- Create: `/Users/nemirovsky/Developer/claude-passthru/.claude-plugin/plugin.json`
- Create: `/Users/nemirovsky/Developer/claude-passthru/.claude-plugin/marketplace.json`
- Create: `/Users/nemirovsky/Developer/claude-passthru/hooks/hooks.json`
- Create: `/Users/nemirovsky/Developer/claude-passthru/README.md` (stub, expanded in Task 10)
- Create: `/Users/nemirovsky/Developer/claude-passthru/.gitignore`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/plugin_loads.bats`

- [x] `git init` in the repo root. Work on `main` (default branch). (already initialized)
- [x] create `plugin.json` with `name: "passthru"`, `version: "0.1.0"`, description.
- [x] create `marketplace.json` at `.claude-plugin/marketplace.json` (root of repo, alongside `plugin.json`) - required by Claude Code's `/plugin marketplace add <repo>` resolver.
- [x] create `hooks.json` with one `PreToolUse` entry, matcher `"*"`, pointing at `${CLAUDE_PLUGIN_ROOT}/hooks/handlers/pre-tool-use.sh`, timeout 2 (jq+grep is well under 1s; 2s is enough headroom without masking runaway hooks).
- [x] create minimal `README.md` stub (full version in Task 10).
- [x] create `.gitignore` excluding `.DS_Store`, `tests/tmp/`.
- [x] write bats test that validates all JSON files parse and contain required keys.
- [x] run tests - must pass before task 2.
- [x] first commit: `chore: initial plugin skeleton`.

### Task 2: Rule file loading and merging (common.sh)

**Files:**
- Create: `/Users/nemirovsky/Developer/claude-passthru/hooks/common.sh`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/common_load.bats`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/fixtures/user-only.json`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/fixtures/project-only.json`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/fixtures/both-scopes.json`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/fixtures/imported-and-authored.json`

- [x] implement `load_rules` in `common.sh` that reads up to four files (`~/.claude/passthru.json`, `~/.claude/passthru.imported.json`, `$CWD/.claude/passthru.json`, `$CWD/.claude/passthru.imported.json`), tolerates missing, concatenates `.allow` and `.deny` arrays via `jq -s`, and outputs merged JSON on stdout.
- [x] implement `validate_rules <json>`: enforce `version: 1`, each entry has at least one of `tool` or `match`, each `match` value is a non-empty string. Do NOT pre-compile/validate PCRE at load time (per-rule `grep -P` roundtrips are slow and may reject valid user PCRE). Deep regex checks live in `scripts/verify.sh` (Task 5), not here. Regex errors at match time still surface with a clear message identifying the offending rule index.
- [x] handle: missing file (skip), empty file (treat as `{}`), malformed JSON (fail with file path).
- [x] write bats tests: user-only, project-only, both scopes merging, imported + authored in same scope, missing files, malformed JSON, schema violation.
- [x] write tests for deny+allow ordering preservation across all four files.
- [x] run tests - must pass before task 3.

### Task 3: Rule matching engine (common.sh continued)

**Files:**
- Modify: `/Users/nemirovsky/Developer/claude-passthru/hooks/common.sh`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/common_match.bats`

- [x] implement `match_rule <tool_name> <tool_input_json> <rule_json>` returning 0 on match, 1 on no match.
- [x] check `tool` regex against `tool_name` using `grep -P` (or perl fallback on BSD/macOS where grep lacks `-P`). Absent/empty = match any.
- [x] for each key in `match`: extract the corresponding field from `tool_input` via `jq -r`; if field is null or missing, rule fails; else regex-match with `grep -P` (or perl fallback).
- [x] empty or absent `match` = match any input.
- [x] implement `find_first_match <rules_array_json> <tool_name> <tool_input>` returning the first matching rule JSON, or empty on no match. Caller extracts `.allow` or `.deny` with jq before passing in - no in-function jq path indirection.
- [x] write bats tests covering: Bash command regex, Read file_path regex, WebFetch url regex, MCP tool name regex, multi-field match (AND), absent match field, field missing from tool_input (no match), invalid regex (error).
- [x] run tests - must pass before task 4.

Implementation note: macOS ships BSD grep without `-P`. Implementation uses `perl -e 'exit(1) unless $ARGV[0] =~ /$ARGV[1]/'` as the PCRE backend (perl is preinstalled on macOS and Linux). Exit codes: 0=match, 1=no-match, 2=bad-regex. Bad-regex errors from `find_first_match` print the offending rule index to stderr. README (Task 10) should note the perl runtime dependency.

### Task 4: Hook handler (pre-tool-use.sh)

**Files:**
- Create: `/Users/nemirovsky/Developer/claude-passthru/hooks/handlers/pre-tool-use.sh`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/hook_handler.bats`

- [x] implement handler: read stdin JSON, extract `tool_name` and `tool_input`, source `common.sh`, load+validate merged rules.
- [x] check deny first. On match: emit `permissionDecision: "deny"` with `permissionDecisionReason: "passthru deny: <reason> [<pattern>]"`, exit 0.
- [x] check allow. On match: emit `permissionDecision: "allow"` with `permissionDecisionReason: "passthru allow: <reason>"`, exit 0.
- [x] no match: exit 0 with stdout payload `{"continue": true}` (explicit passthrough - avoids any risk that Claude Code's hook parser logs an error on empty stdout; confirmed safe per plan review against `src/utils/hooks.ts:552-574`).
- [x] handle errors (missing stdin, malformed input JSON, rule validation failure): print diagnostic to stderr, emit `{"continue": true}` on stdout, exit 0 (fail open - never block tool use on plugin bugs).
- [x] emergency disable via sentinel file `~/.claude/passthru.disabled` (presence = disabled). Env vars are not reliably inherited by hook subprocesses; a sentinel file is unambiguous and survives across shell invocations.
- [x] **plugin self-allow:** before running user rules, hardcode an allow for the plugin's own scripts. Slash commands (`/passthru:add`, `/passthru:suggest`, `/passthru:verify`) shell out via `bash ${CLAUDE_PLUGIN_ROOT}/scripts/*.sh`, and those Bash tool calls go through the PreToolUse hook. Without this self-allow, every slash-command invocation would hit the native permission dialog. Regex: `^bash /.*/\.claude/plugins/.*/claude-passthru/scripts/[a-z-]+\.sh( |$)` (tool = `Bash`; escaped `\.claude` so the literal dot matches the on-disk path). This is baked into the hook handler, not the user's config, so it works out-of-the-box across all install paths with zero bootstrap step required. Include a bats test covering the self-allow path.
- [x] write bats tests (all end-to-end via stdin pipe, no "manual pipe-test" step - that test IS a bats test): deny match -> deny JSON, allow match -> allow JSON, no match -> `{"continue": true}`, deny priority over allow, malformed stdin -> `{"continue": true}` + stderr warning, disabled sentinel present -> `{"continue": true}`, plugin self-allow (synthetic `bash .../claude-passthru/scripts/verify.sh` payload -> allow), real-world Bash `gh api /repos/owner/repo/forks` fixture round-trip.
- [x] + **optional audit log (PreToolUse side):** if sentinel `~/.claude/passthru.audit.enabled` exists, append one JSONL line per decision to `~/.claude/passthru-audit.log`. Audit is OFF by default; enabling is a single `touch`. Line schema:
  ```json
  {"ts":"<iso8601>","event":"allow|deny|passthrough","source":"passthru","tool":"<tool_name>","reason":"<rule reason or null>","rule_index":<int or null>,"pattern":"<tool or match-key regex summary or null>","tool_use_id":"<hook input id or null>"}
  ```
  Log write failures must NEVER block the tool call (fail open, diagnostic to stderr). Writes must be append-safe under concurrent hooks (open with O_APPEND via `>>`; a single JSONL line per `printf` is atomic below PIPE_BUF on POSIX).
- [x] + audit log breadcrumb (PreToolUse side): when audit is enabled AND the decision is `passthrough`, also write `$TMPDIR/passthru-pre-<tool_use_id>.json` with `{"ts":"...","tool":"<name>","tool_input":<obj>,"settings_sha_user":"<sha256 of ~/.claude/settings.json or null>","settings_sha_project":"<sha256 of .claude/settings.local.json or null>"}`. Consumed by Task 4b PostToolUse to classify the user's native-dialog outcome (asked_allowed_once/always, asked_denied_once/always). Breadcrumb is only written on passthrough (we don't need it when we decided ourselves). If `tool_use_id` is absent, skip the breadcrumb (we log the base passthrough event regardless).
- [x] + garbage-collect stale breadcrumbs: on every PreToolUse, unlink breadcrumb files older than 1 hour. Cheap find/stat check, bounded to the breadcrumb directory.
- [x] + bats tests for audit: audit disabled -> no log file written, no breadcrumb; audit enabled + allow match -> one JSONL line with correct fields, no breadcrumb; audit enabled + deny match -> one JSONL line, no breadcrumb; audit enabled + passthrough with tool_use_id -> one JSONL + one breadcrumb file; audit enabled + passthrough without tool_use_id -> JSONL but no breadcrumb; stale breadcrumb older than 1h is unlinked on next PreToolUse.
- [x] run tests - must pass before task 4b.

### Task 4b: PostToolUse hook for native-dialog outcomes (audit log continued)

**Files:**
- Create: `/Users/nemirovsky/Developer/claude-passthru/hooks/handlers/post-tool-use.sh`
- Modify: `/Users/nemirovsky/Developer/claude-passthru/hooks/hooks.json` (add PostToolUse entry, matcher `"*"`, timeout 2)
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/post_hook_handler.bats`

- [x] + implement handler: read stdin JSON, extract `tool_name`, `tool_input`, `tool_use_id`, `tool_response`. If audit sentinel is absent -> exit 0 immediately (`{"continue": true}` on stdout), zero overhead in disabled mode.
- [x] + look up the breadcrumb at `$TMPDIR/passthru-pre-<tool_use_id>.json`. If absent (meaning PreToolUse decided allow/deny itself, or audit was disabled then), exit 0 silently - we already logged the decision PreToolUse side.
- [x] + classify outcome:
  - tool_response missing or marked as permission-blocked -> `asked_denied_once` (note: Claude Code rarely persists deny decisions, so "denied always" is detected only if a new deny rule appeared in settings.json; otherwise default to "once"). Detect blocked via tool_response containing `permissionDenied: true` or similar indicator.
  - tool_response present and successful -> compute current settings.json sha for both user and project scopes. Compare to breadcrumb's snapshots:
    - user or project sha changed AND new permissions entry covers this tool call -> `asked_allowed_always`
    - unchanged -> `asked_allowed_once`
  - "new permissions entry covers this tool call" heuristic: diff the old vs new `permissions.allow` arrays, take the added entry, check if it's a substring/glob match for the current tool call. A rough heuristic; document the limitations. Never emit a wrong classification silently: on ambiguity, emit `asked_allowed_unknown` rather than guessing.
- [x] + write JSONL line to `~/.claude/passthru-audit.log`: `{"ts":"...","event":"asked_allowed_always|asked_allowed_once|asked_denied_always|asked_denied_once|asked_allowed_unknown","source":"native","tool":"<name>","tool_use_id":"<id>"}`. Same append-safe write semantics as PreToolUse.
- [x] + unlink the breadcrumb after processing (success or error). Never leave orphans.
- [x] + fail-open behaviour: any error in PostToolUse -> diagnostic to stderr, exit 0 with `{"continue": true}`. Audit failures must not affect tool outcomes.
- [x] + bats tests: breadcrumb -> tool_response success + settings unchanged = `asked_allowed_once`; settings changed with matching new rule = `asked_allowed_always`; settings changed with unrelated rule = `asked_allowed_unknown`; tool_response shows permission blocked = `asked_denied_once`; no breadcrumb = no-op; audit disabled = no-op regardless of breadcrumb (self-heal - unlink only); malformed breadcrumb -> stderr + no-op + unlink.
- [x] + run tests - must pass before task 5.

### Task 5: Rule verifier + atomic write wrapper

**Files:**
- Create: `/Users/nemirovsky/Developer/claude-passthru/scripts/verify.sh`
- Create: `/Users/nemirovsky/Developer/claude-passthru/scripts/write-rule.sh`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/verifier.bats`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/write_rule.bats`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/fixtures/invalid-regex.json`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/fixtures/duplicate-rules.json`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/fixtures/conflicting-rules.json`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/fixtures/shadowed-rule.json`

Verifier (`verify.sh`):
- [x] loads all four rule files (user + project, authored + imported), runs checks across the merged set, prints a structured report, exits 0 on clean / 1 on any error / 2 on warnings only (only if `--strict`).
- [x] **check 1 parse:** every existing file parses as JSON (fail with file path + jq error on parse fail).
- [x] **check 2 schema:** each rule has `tool` or `match`, types match spec, `version: 1`.
- [x] **check 3 regex compile:** every `tool` regex and every `match.*` regex is tested with `grep -P '' </dev/null` (compile-only, no matching). On syntax error, report file path + rule index + offending pattern + grep's error.
- [x] **check 4 duplicates:** exact-duplicate rules (same tool + same match object) across all scopes -> warn (not always wrong, but surfaced so the user can prune).
- [x] **check 5 deny/allow conflict:** identical tool + match present in both `.deny[]` and `.allow[]` across any scope -> error (user intent unclear; deny wins silently would be worse than explicit failure).
- [x] **check 6 shadowing:** within a single allow[] or deny[] array (post-merge), if rule at index i has the exact same tool+match as rule at some index j<i, warn "rule N shadowed by earlier identical rule at index M". Formal regex-subset detection is undecidable; this heuristic catches the common case.
- [x] **flags:** `--strict` (warnings also non-zero exit), `--quiet` (no stdout on success, still prints errors), `--scope user|project|all` (default all), `--format plain|json` (default plain).
- [x] **report format:** `[OK] N rules across M files checked` on success; on failure, structured lines `<severity> <file>:<jq-path> [rule-index] <message>`. Output is plain ASCII per project writing rules.
- [x] write bats tests for each check with dedicated fixtures; test strict mode; test json output is valid JSON; test exit codes; test `--scope user` runs against only user files.
- [x] edge cases: no files at all -> exit 0 with "no rules"; one file invalid + one valid -> exit 1, specific file called out; identical rules in user + project -> warn (still exit 0 without --strict).

Atomic write wrapper (`write-rule.sh`):
- [x] signature: `write-rule.sh <scope> <list> <rule_json>` where `scope` is `user|project` and `list` is `allow|deny`.
- [x] resolve target `passthru.json` path, create if missing with `{"version":1,"allow":[],"deny":[]}`.
- [x] take a backup to a temp file, append the rule to the chosen list, run `scripts/verify.sh --quiet`, on verifier failure **restore backup atomically** and exit non-zero with the verifier's error on stderr, on success delete the backup and exit 0.
- [x] handle concurrent writes with a lock file (`~/.claude/passthru.write.lock`, 5s timeout, released via `trap`).
- [x] write bats tests: happy path (rule appended, file valid), invalid regex (backup restored, non-zero exit, no file corruption), missing target file (created with correct shape), concurrent write serialization.
- [x] run tests - must pass before task 6.

### Task 6: /passthru:add slash command

**Files:**
- Create: `/Users/nemirovsky/Developer/claude-passthru/commands/add.md`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/command_add_manual.md` (manual test script)
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/command_frontmatter.bats`

- [x] write `commands/add.md` with frontmatter: `description`, `argument-hint: "<scope> <tool> <pattern> [reason]"`. Exposed as `/passthru:add` via plugin namespacing.
- [x] prompt body instructs Claude to: parse `$ARGUMENTS`, validate scope (`user`|`project`), construct the rule JSON, then shell out to `bash ${CLAUDE_PLUGIN_ROOT}/scripts/write-rule.sh <scope> allow <rule_json>`. On non-zero exit, surface the stderr output to the user. On success, confirm the rule was added and show the resulting file.
- [x] include examples in the prompt: adding a Bash rule, adding an MCP tool rule, adding a multi-field match.
- [x] support `--deny` flag in args to pass `deny` instead of `allow` to `write-rule.sh`.
- [x] write bats lint test for the markdown file: required frontmatter keys (`description`, `argument-hint`) present and non-empty. (Shared bats file covers add, suggest, verify frontmatter.)
- [x] write manual test script documenting: invoke `/passthru:add user Bash "^gh api /repos/"`, verify `~/.claude/passthru.json` was created/updated, verify the verifier ran via `write-rule.sh`, verify subsequent matching command is auto-allowed.
- [x] manual negative test: invoke `/passthru:add` with a syntactically invalid regex; confirm the verifier catches it, the rule is not written, and the file is not corrupted.
- [x] manual verification (deferred to Task 11)
- [x] run tests (bats) - must pass before task 7.

### Task 7: /passthru:suggest slash command

**Files:**
- Create: `/Users/nemirovsky/Developer/claude-passthru/commands/suggest.md`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/command_suggest_manual.md`

- [x] write `commands/suggest.md` with frontmatter: `description`, `argument-hint: "[tool-or-command-hint]"`. Exposed as `/passthru:suggest`.
- [x] prompt body instructs Claude to: scan recent tool-call events in the session transcript, identify the last permission-prompt-triggering tool call (or the one matching the user's hint), propose a regex rule that generalizes that class of command without overfitting.
- [x] prompt explicitly tells Claude to explain the regex, show matched/non-matched examples, then ask the user to pick scope (`user`|`project`) and confirm before writing.
- [x] on confirmation, shell out to `bash ${CLAUDE_PLUGIN_ROOT}/scripts/write-rule.sh <scope> allow <rule_json>` (same path as `/passthru:add`). On failure, surface the error.
- [x] extend the shared frontmatter bats test to cover `suggest.md`.
- [x] write manual test script: run a `gh api /repos/...` command that triggers native prompt, answer "yes once", then invoke `/passthru:suggest`, verify proposed regex is sensible, verify `write-rule.sh` ran and the rule landed.
- [x] manual verification (deferred to Task 11).
- [x] run tests (bats) - must pass before task 8.

### Task 8: /passthru:verify slash command

**Files:**
- Create: `/Users/nemirovsky/Developer/claude-passthru/commands/verify.md`

- [x] write `commands/verify.md` with frontmatter: `description`, `argument-hint: "[--scope user|project|all] [--strict]"`. Exposed as `/passthru:verify`.
- [x] prompt body instructs Claude to run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/verify.sh $ARGUMENTS`, present the output in a readable way, and on errors explain what to do (edit file, re-run).
- [x] include guidance: when the user edits `passthru.json` directly, they should run `/passthru:verify` to catch errors before the next tool call.
- [x] extend the shared frontmatter bats test to cover `verify.md`.
- [x] manual verification (deferred to Task 11).
- [x] run tests (bats) - must pass before task 8b.

### Task 8b: /passthru:log slash command + scripts/log.sh

**Files:**
- Create: `/Users/nemirovsky/Developer/claude-passthru/scripts/log.sh`
- Create: `/Users/nemirovsky/Developer/claude-passthru/commands/log.md`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/log_script.bats`

- [x] + implement `scripts/log.sh`: reads `~/.claude/passthru-audit.log` (override path via `--file`), formats JSONL entries for human viewing.
- [x] + flags:
  - `--since <value>`: filter by time. Accepts ISO 8601 (`2026-04-14T00:00:00Z`), relative (`1h`, `24h`, `7d`), or `today`.
  - `--event <pattern>`: filter by event. Value is a regex matched against the `event` field. Examples: `allow`, `deny`, `^asked_`, `asked_allowed_(once|always)`.
  - `--tool <pattern>`: regex against `tool` field.
  - `--format table|json|raw`: default `table` (pretty columns, ANSI colors only when stdout is a tty), `json` emits the filtered entries as a JSON array, `raw` passes through JSONL unchanged.
  - `--tail N`: show only the last N entries after filtering.
  - `--enable`: touch `~/.claude/passthru.audit.enabled`, exit 0 after printing "audit enabled".
  - `--disable`: rm the sentinel, exit 0 after printing "audit disabled".
  - `--status`: print `enabled`/`disabled` and the log file path, exit 0.
  - `--help`: short usage text.
- [x] + empty log / missing file -> print "no entries" to stderr, exit 0.
- [x] + table columns: time (local tz, `HH:MM:SS` if today, else `YYYY-MM-DD HH:MM`), event, source, tool, reason/detail. Truncate long reasons with ellipsis; full JSON is always available via `--format json` or `--format raw`.
- [x] + color scheme (tty only): green for `allow`/`asked_allowed_*`, red for `deny`/`asked_denied_*`, yellow for `passthrough`/`asked_allowed_unknown`.
- [x] + plain ASCII (no em-dashes, no fancy bullets). Use `|` column separators and ASCII box chars if any.
- [x] + `commands/log.md` slash command frontmatter: `description`, `argument-hint: "[--since 1h] [--event ...] [--tool ...] [--tail N] [--format table|json|raw] [--enable|--disable|--status]"`. Exposed as `/passthru:log`. Prompt body shells out to `bash ${CLAUDE_PLUGIN_ROOT}/scripts/log.sh $ARGUMENTS` and surfaces output.
- [x] + extend shared frontmatter bats test to cover `log.md`.
- [x] + bats tests for log.sh: empty/missing log -> "no entries"; mixed-event log + `--event allow` filter; `--since 1h` filters correctly against fixture timestamps; `--format json` emits valid JSON array; `--tail 2` returns last 2; `--enable` creates sentinel; `--disable` removes it; `--status` reports correctly in both states; bad `--since` value -> stderr + exit 2.
- [x] + run tests - must pass before task 9.

### Task 9: Bootstrap script (one-time import from native rules)

**Files:**
- Create: `/Users/nemirovsky/Developer/claude-passthru/scripts/bootstrap.sh`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/bootstrap.bats`
- Create: `/Users/nemirovsky/Developer/claude-passthru/tests/fixtures/settings-with-allow.json`

- [x] implement `bootstrap.sh` that scans `~/.claude/settings.json` + `$CWD/.claude/settings.local.json` + `$CWD/.claude/settings.json` for `permissions.allow` entries.
- [x] write imported rules to a separate file per scope: `~/.claude/passthru.imported.json` (user) and `.claude/passthru.imported.json` (project). The hook's loader (Task 2) already merges these alongside the authored files.
- [x] convert simple `Bash(prefix:*)` rules into: `{ tool: "Bash", match: { command: "^<escaped-prefix>(\\s|$)" }, reason: "imported from settings" }`. Skip patterns that would require manual regex conversion (containing spaces beyond the prefix, etc.).
- [x] convert `mcp__server__tool` exact rules into `{ tool: "^mcp__server__tool$", reason: "imported" }`.
- [x] convert `WebFetch(domain:x.com)` into `{ tool: "WebFetch", match: { url: "^https?://([^/.]+\\.)*x\\.com(/|$)" }, reason: "imported" }` - the stricter regex prevents `evilx.com` from matching when the user allowed `x.com`.
- [x] default mode: print proposed rules to stdout for review; `--write` flag to replace `passthru.imported.json` (authored `passthru.json` is never touched).
- [x] **after `--write` completes, invoke `scripts/verify.sh --quiet`**. If verifier fails, preserve the previous `.imported.json` (restored from a temp backup taken before the write), print the verifier error, and exit non-zero.
- [x] write bats tests: fixture settings.json with a mix of Bash prefix rules, MCP rules, WebFetch rules, exact-command rules. Verify output JSON.
- [x] test edge cases: empty allow list, malformed settings.json, re-run on existing `passthru.imported.json` (replaces cleanly; hand-written `passthru.json` unchanged).
- [x] regression test: verify `evilx.com` does NOT match an imported `x.com` rule.
- [x] regression test: verify bootstrap writes + verifier-pass round-trip (chain passes end-to-end).
- [x] run tests - must pass before task 10.

### Task 10: README, CLAUDE.md, and usage documentation

**Files:**
- Modify: `/Users/nemirovsky/Developer/claude-passthru/README.md`
- Create: `/Users/nemirovsky/Developer/claude-passthru/CONTRIBUTING.md`
- Create: `/Users/nemirovsky/Developer/claude-passthru/CLAUDE.md`
- Create: `/Users/nemirovsky/Developer/claude-passthru/docs/rule-format.md`
- Create: `/Users/nemirovsky/Developer/claude-passthru/docs/examples.md`

- [x] expand `README.md` to cover: what it does, why (motivating examples like the directory-prefix gap, the `gh api` regex use case), install, first-run bootstrap, rule format reference with examples, command reference (`/passthru:add`, `/passthru:suggest`, `/passthru:verify`, `/passthru:log`), the verifier (`scripts/verify.sh` standalone invocation), troubleshooting, sentinel-file escape hatch (`touch ~/.claude/passthru.disabled`).
- [x] + README must include a **"Requirements"** section listing runtime dependencies with install hints:
  - `bash` (check actual minimum - 3.2 if code is 3.2-compatible, else 4.0+). macOS default is 3.2; Linux usually ships 4+. Verify the minimum against the scripts actually committed before pinning.
  - `jq` 1.6+ - macOS: `brew install jq`, Debian/Ubuntu: `apt install jq`, RHEL/Fedora: `dnf install jq`.
  - `perl` 5+ - preinstalled on macOS and most Linux distros; used as the PCRE backend because BSD grep on macOS lacks `-P`.
  - `bats-core` 1.9+ - tests only; not required to run the plugin. macOS: `brew install bats-core`, Debian/Ubuntu: `apt install bats` (may be older; npm install preferred: `npm install -g bats`).
  - Note PowerShell support: hook itself is Bash/perl only; PowerShell rule matching works because Claude Code still invokes the PreToolUse hook for `PowerShell` tool calls - no PowerShell runtime needed on the user's machine.
- [x] + README must include an **"Audit log"** section documenting:
  - Audit is **opt-in and off by default**.
  - Enable: `touch ~/.claude/passthru.audit.enabled` or `/passthru:log --enable`.
  - Disable: `rm ~/.claude/passthru.audit.enabled` or `/passthru:log --disable`.
  - Log path: `~/.claude/passthru-audit.log` (JSONL).
  - Event types: `allow`, `deny`, `passthrough` (from PreToolUse) and `asked_allowed_once`, `asked_allowed_always`, `asked_denied_once`, `asked_denied_always`, `asked_allowed_unknown` (from PostToolUse, passthrough outcomes only).
  - View: `/passthru:log` or `scripts/log.sh` directly; flags documented in the command help.
  - Log rotation: none built in; use `logrotate` or manual truncation if the file grows. Document expected volume (one line per tool call when enabled).
- [x] README must include a **"Test locally"** section with the exact command for loading an uninstalled plugin directory:

  ```
  claude --plugin-dir /path/to/claude-passthru
  ```

  Explain that this loads the plugin from the working tree without needing `/plugin install`, which is the fastest iteration loop during development. Link to this section from CONTRIBUTING.md.
- [x] README must include a **"Verifying rules"** section: when to run `/passthru:verify` (after manual edits to `passthru.json`), what the automatic verification path covers (after `/passthru:add`, `/passthru:suggest`, `bootstrap --write`), and how to interpret the output.
- [x] `CONTRIBUTING.md`: contributor-facing notes covering (a) local dev loop with `claude --plugin-dir`, (b) how to run bats tests, (c) how to pipe-test the hook manually, (d) rule schema evolution guidelines (bump `version` field on breaking changes), (e) how to add a new verifier check, (f) branch policy: `main` is protected on GitHub, all changes go through PRs.
- [x] `CLAUDE.md`: developer-facing notes for future Claude sessions. Must include a **Releases** section modeled on `/Users/nemirovsky/Developer/sluice/CLAUDE.md`:

  - Use the `release-tools:new` skill (`/release-tools:new`) to cut a new release.
  - **Naming:** tag `vX.Y.Z`, release title same as tag.
  - **Version selection:**
    - **Minor** (`v0.1.0` -> `v0.2.0`): default for most releases. Use when a PR adds `feat` commits, new commands, new rule-schema fields, or user-visible behavior changes.
    - **Hotfix** (`v0.2.0` -> `v0.2.1`): PR contains `fix` commits exclusively (no feat, no breaking changes).
    - **Major** (`v0.2.0` -> `v1.0.0`): breaking changes to rule schema, slash command names, or hook contract. Always discuss with the user before a major bump; never pick major autonomously.
  - **Skip releases for:** `chore`, `docs`, `ci`, `test` only PRs.
  - **Version bump is two-file**: before tagging, update BOTH `.claude-plugin/plugin.json` `version` and `.claude-plugin/marketplace.json` version metadata to match the target tag (without the `v` prefix - `plugin.json` uses `0.2.0` not `v0.2.0`). Commit the version bump as `chore(release): vX.Y.Z`, then tag. The `release-tools:new` skill should be extended or guided to handle this; if it does not, document the manual two-file bump step explicitly in CLAUDE.md.
  - **File structure**, **how tests run**, **how to pipe-test the hook**, **verifier CLI flags** - all documented inline.
- [x] `docs/rule-format.md`: detailed schema reference.
- [x] `docs/examples.md`: 10+ real-world rule examples across Bash, PowerShell, Read, WebFetch, MCP.
- [x] verify all anchors/paths in docs resolve.
- [x] (no new code tests for docs; existing tests still green).
- [x] run full test suite - must pass before task 11.

### Task 11: Verify acceptance criteria

Coverage summary: every acceptance check is either automated in the bats suite (257 tests, 0 failures as of this task) or requires a live Claude Code session to visually confirm native UI behavior. Items marked "manual verification required - live session" cannot be automated from the batch context because they depend on observing the permission dialog, transcript pane, or plugin loader state of a running `claude` process. All such items have corresponding manual test scripts checked into `tests/command_*_manual.md` for execution by a human during plugin install/smoke test.

- [x] verify native dialog is bypassed when a rule matches (install plugin locally, run matching command, confirm no prompt). Automated equivalent: `tests/hook_handler.bats` line 62 "allow match emits allow decision JSON" - the hook emits `permissionDecision: allow`, which Claude Code's hook dispatcher treats as a dialog-bypass per Claude Code source `src/utils/hooks.ts`. Full UI confirmation is manual verification required - live session (per plan's "manual install + `claude --debug` verification" strategy).
- [x] verify native dialog still appears when no rule matches (run a new command, confirm prompt). Automated equivalent: `tests/hook_handler.bats` line 86 "no match with rules present -> passthrough" confirms `{"continue": true}` is emitted, which Claude Code interprets as "run native permission flow". Full UI confirmation is manual verification required - live session.
- [x] verify deny priority: add overlapping allow + deny, verify deny wins. Covered by `tests/hook_handler.bats` line 94 "deny wins over allow when both would match" (crafts a fixture where both lists match the same command and asserts `deny`). Additionally exercised via synthetic payload in this task: with `user-only.json` containing an `rm -rf /` deny and a broad allow, the handler emitted `deny`.
- [x] verify user + project scope merge: rule in user file allows command run from a project with no project file. Covered by `tests/common_load.bats` line 69 "load_rules merges user + project authored (user first, project second)" and the surrounding merge tests that assert user-only rules are honored when project scope is empty.
- [x] verify `transcripts` view shows the allow reason (hybrid visibility). Manual verification required - live session. The hook correctly emits `permissionDecisionReason` (asserted in `tests/hook_handler.bats` lines 71-72), but whether Claude Code surfaces that reason in the transcript pane is a UI-side behavior that can only be observed in a running session.
- [x] verify sentinel disable: `touch ~/.claude/passthru.disabled`, start claude, confirm rules are bypassed; `rm ~/.claude/passthru.disabled`, confirm rules reactivate without restart. Covered by `tests/hook_handler.bats` line 131 "disabled sentinel short-circuits to passthrough (even with matching deny rule)". The "reactivate without restart" aspect is by design: the hook checks `[ -e "$DISABLED_SENTINEL" ]` on every invocation (`hooks/handlers/pre-tool-use.sh` line 233), with no caching. Confirmed via one-off synthetic run in this task: touch -> passthrough, rm -> deny matched again in next invocation.
- [x] verify local dev loop: `claude --plugin-dir /Users/nemirovsky/Developer/claude-passthru` loads the plugin from the working tree. Manual verification required - live session. Plugin structure is validated by `tests/plugin_loads.bats` (manifests parse, required keys present), but Claude Code's plugin loader is external and can only be exercised by running `claude --plugin-dir`.
- [x] verify `/passthru:verify` reports cleanly on a known-good config and reports errors on a deliberately broken one. Covered by `tests/verifier.bats` lines 39, 45, 52, 58 (clean cases) and the parse/schema/regex error checks throughout the file. Confirmed via one-off run in this task: clean config -> `[OK] 1 rules across 1 files checked` exit 0; invalid regex `[` -> `[ERR] ...` exit 1.
- [x] verify auto-verify on write: use `/passthru:add` with an invalid regex; confirm the write is rolled back by `write-rule.sh` and the user is told why. Covered by `tests/write_rule.bats` line 136 "invalid regex -> backup restored, exit non-zero" (asserts byte-for-byte file equality pre/post) and line 151 "invalid regex on new file -> file still exists in valid shape". Confirmed via one-off run in this task: attempting to write `{"tool":"Bash","match":{"command":"["}}` produced `write-rule.sh: verifier rejected new rule; rolled back` and the file was byte-identical to the original.
- [x] run full test suite: `bats tests/*.bats`. Confirmed in this task: 257 tests, 0 failures.
- [x] confirm no regressions: native `.claude/settings.local.json` rules still work untouched. By design - the hook, `/passthru:add`, `/passthru:suggest`, and `/passthru:verify` never write to `settings.json` or `settings.local.json`; they only read `settings.json` (bootstrap.sh, PostToolUse audit sha snapshot) and write to `passthru.json` / `passthru.imported.json` / `passthru-audit.log` / `passthru.audit.enabled`. All writes are scoped to passthru-prefixed paths (verified by `grep -rE "settings\.json" scripts hooks` - only read paths, no write paths). Live-session regression confirmation is manual verification required - live session.
- [x] + audit log end-to-end: enable via `/passthru:log --enable`; run commands that exercise allow/deny/passthrough; confirm JSONL log entries land; verify `/passthru:log --event allow`, `--event '^asked_'`, `--since 1h`, `--tail 10`, and `--format json` each filter or render correctly. Disable via `/passthru:log --disable` and confirm no further entries are appended. Confirm `/passthru:log --status` reflects state. Automated coverage: `tests/hook_handler.bats` audit section (lines 216+) asserts PreToolUse writes JSONL on allow/deny/passthrough when sentinel present, no writes when absent; `tests/post_hook_handler.bats` covers PostToolUse classifications (`asked_allowed_once`, `asked_allowed_always`, `asked_denied_once`, `asked_allowed_unknown`); `tests/log_script.bats` covers all `--event`, `--since`, `--tail`, `--format`, `--enable`, `--disable`, `--status` flag paths. The end-to-end run through a live Claude session (real tool calls driving the whole pipeline) is manual verification required - live session.

### Task 12: Publish to GitHub with branch protection

- [ ] ensure all commits are clean on `main`, working tree has no uncommitted changes.
- [ ] create GitHub repo via gh CLI: `gh repo create nemirovsky/claude-passthru --public --source=. --description "Regex-based permission rules for Claude Code via PreToolUse hook"`. Prompt user first to confirm `--public` vs `--private`.
- [ ] + set GitHub topics (tags) via `gh repo edit nemirovsky/claude-passthru --add-topic claude-code --add-topic claude-code-plugin --add-topic claude-code-hook --add-topic permissions --add-topic security --add-topic regex --add-topic developer-tools`. Tags improve discoverability on GitHub topic pages. Confirm the tag list with the user before running; the list above is a starting point and may be adjusted.
- [ ] + verify description and topics are set: `gh repo view nemirovsky/claude-passthru --json description,repositoryTopics` - confirm both fields are populated as expected. If either is missing, re-run the corresponding `gh repo edit` / `gh repo create` step.
- [ ] + (optional) set the repo homepage URL if a docs site or marketplace listing URL exists later: `gh repo edit nemirovsky/claude-passthru --homepage "<url>"`. Skip on v0.1.0 since no hosted docs yet.
- [ ] push `main` to the new remote: `git push -u origin main`.
- [ ] enable branch protection on `main` via gh CLI (requires admin on the repo):
  ```
  gh api --method PUT repos/nemirovsky/claude-passthru/branches/main/protection \
    -f required_status_checks=null \
    -F enforce_admins=false \
    -F required_pull_request_reviews[required_approving_review_count]=0 \
    -F required_pull_request_reviews[dismiss_stale_reviews]=false \
    -F restrictions=null \
    -F allow_force_pushes=false \
    -F allow_deletions=false
  ```
  Rationale: block direct pushes to `main`, require PRs, disallow force push and branch deletion. Single-maintainer repo so 0-approval PRs are fine (self-merge allowed).
- [ ] verify protection is enforced: attempt `git push origin main` with a dummy commit on a throwaway branch - expect rejection prompting for PR.
- [ ] add minimal GitHub Actions CI: `.github/workflows/ci.yml` running `bats tests/*.bats` on push and PR to `main`. Include shellcheck on `hooks/` and `scripts/`.
- [ ] update `README.md` with the `/plugin marketplace add nemirovsky/claude-passthru` install instruction.
- [ ] move this plan to `docs/plans/completed/`.
- [ ] tag `v0.1.0` via `release-tools:new` skill (bump version in both manifests per Task 10 CLAUDE.md release workflow), push tag.
- [ ] **prompt the user** (via AskUserQuestion) whether to:
  - list plugin on a community marketplace (e.g., `claude-code-marketplace`). If yes, guide through the submission PR.
  - post an announcement on anthropics/claude-code issue #37509 as a community workaround. If yes, draft the comment text and wait for user approval before `gh issue comment`.
  Do not silently skip these - the user explicitly wanted to be prompted after manual verification completes.

## Post-Completion

*Items requiring manual intervention or external systems. Informational only.*

**Manual verification:**
- End-to-end test inside a live Claude Code session: install the plugin via `/plugin install`, run bootstrap, exercise a directory-prefix rule and a `gh api` regex rule.
- Verify hook timing does not introduce perceptible delay (< 100 ms per tool call with typical rule count).
- Verify on Windows + PowerShell if target audience includes Windows users (untested on Windows in current plan).

**External system updates:**
- Marketplace listing and issue-thread announcement are handled as interactive prompts at the end of Task 12 (not silent post-completion optionals).
