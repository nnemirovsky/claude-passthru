#!/usr/bin/env bats

# tests/common_match.bats
# Validates hooks/common.sh rule matching engine: pcre_match, match_rule, find_first_match.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  # Synthetic scope roots so sourcing common.sh path helpers can't touch real ~/.claude.
  TMP="$(mktemp -d -t passthru-test.XXXXXX)"
  USER_ROOT="$TMP/user"
  PROJ_ROOT="$TMP/proj"
  mkdir -p "$USER_ROOT/.claude" "$PROJ_ROOT/.claude"
  export PASSTHRU_USER_HOME="$USER_ROOT"
  export PASSTHRU_PROJECT_DIR="$PROJ_ROOT"

  # shellcheck disable=SC1090
  source "$REPO_ROOT/hooks/common.sh"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# pcre_match - low-level PCRE helper (perl-backed, BSD grep compat)
# ---------------------------------------------------------------------------

@test "pcre_match returns 0 on a simple literal match" {
  run pcre_match "hello world" "hello"
  [ "$status" -eq 0 ]
}

@test "pcre_match returns 1 when subject does not match pattern" {
  run pcre_match "hello world" "xyz"
  [ "$status" -eq 1 ]
}

@test "pcre_match returns 2 on invalid regex (compile error)" {
  run pcre_match "anything" "(unclosed"
  [ "$status" -eq 2 ]
}

@test "pcre_match supports character classes and anchors" {
  run pcre_match "/Users/foo/dev/bar" "^/Users/[^/]+/dev/"
  [ "$status" -eq 0 ]
  run pcre_match "/etc/passwd" "^/Users/[^/]+/dev/"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# match_rule - single-rule matcher
# ---------------------------------------------------------------------------

@test "match_rule: Bash command regex matches" {
  rule='{"tool":"Bash","match":{"command":"^ls(\\s|$)"},"reason":"ls"}'
  run match_rule "Bash" '{"command":"ls -la"}' "$rule"
  [ "$status" -eq 0 ]
}

@test "match_rule: Bash command regex does not match different command" {
  rule='{"tool":"Bash","match":{"command":"^ls(\\s|$)"}}'
  run match_rule "Bash" '{"command":"rm -rf /"}' "$rule"
  [ "$status" -eq 1 ]
}

@test "match_rule: tool mismatch is a no-match" {
  rule='{"tool":"Bash","match":{"command":"^ls"}}'
  run match_rule "Read" '{"command":"ls -la"}' "$rule"
  [ "$status" -eq 1 ]
}

@test "match_rule: Read file_path regex matches" {
  rule='{"tool":"Read","match":{"file_path":"^/Users/[^/]+/Developer/"}}'
  run match_rule "Read" '{"file_path":"/Users/alice/Developer/proj/x.md"}' "$rule"
  [ "$status" -eq 0 ]
}

@test "match_rule: Read file_path regex rejects paths outside prefix" {
  rule='{"tool":"Read","match":{"file_path":"^/Users/[^/]+/Developer/"}}'
  run match_rule "Read" '{"file_path":"/etc/passwd"}' "$rule"
  [ "$status" -eq 1 ]
}

@test "match_rule: WebFetch url regex matches allowed domain" {
  rule='{"tool":"WebFetch","match":{"url":"^https?://(github\\.com|docs\\.anthropic\\.com)(/|$)"}}'
  run match_rule "WebFetch" '{"url":"https://github.com/anthropics/anthropic-sdk-python"}' "$rule"
  [ "$status" -eq 0 ]
}

@test "match_rule: WebFetch url regex rejects non-allowed domain" {
  rule='{"tool":"WebFetch","match":{"url":"^https?://(github\\.com|docs\\.anthropic\\.com)(/|$)"}}'
  run match_rule "WebFetch" '{"url":"https://evil.example.com/"}' "$rule"
  [ "$status" -eq 1 ]
}

@test "match_rule: MCP tool name regex matches namespace wildcard" {
  rule='{"tool":"^mcp__gemini-cli__","reason":"all gemini mcp calls"}'
  run match_rule "mcp__gemini-cli__ask-gemini" '{}' "$rule"
  [ "$status" -eq 0 ]
  run match_rule "mcp__gemini-cli__ping" '{}' "$rule"
  [ "$status" -eq 0 ]
}

@test "match_rule: MCP tool name regex does not match other namespaces" {
  rule='{"tool":"^mcp__gemini-cli__"}'
  run match_rule "mcp__other-server__tool" '{}' "$rule"
  [ "$status" -eq 1 ]
}

@test "match_rule: multi-field match requires all keys to pass (AND)" {
  rule='{"tool":"Bash","match":{"command":"^gh api","description":"forks"}}'
  run match_rule "Bash" '{"command":"gh api /repos/foo/bar/forks","description":"list forks of the repo"}' "$rule"
  [ "$status" -eq 0 ]
}

@test "match_rule: multi-field match fails if any key does not match" {
  rule='{"tool":"Bash","match":{"command":"^gh api","description":"forks"}}'
  run match_rule "Bash" '{"command":"gh api /repos/foo/bar/branches","description":"list branches"}' "$rule"
  [ "$status" -eq 1 ]
}

@test "match_rule: absent tool field means match any tool" {
  rule='{"match":{"command":"^ls"}}'
  run match_rule "Bash" '{"command":"ls -la"}' "$rule"
  [ "$status" -eq 0 ]
  run match_rule "PowerShell" '{"command":"ls -la"}' "$rule"
  [ "$status" -eq 0 ]
}

@test "match_rule: empty tool string means match any tool" {
  rule='{"tool":"","match":{"command":"^ls"}}'
  run match_rule "Bash" '{"command":"ls -la"}' "$rule"
  [ "$status" -eq 0 ]
}

@test "match_rule: absent match means match any input for that tool" {
  rule='{"tool":"^mcp__gemini-cli__"}'
  run match_rule "mcp__gemini-cli__ping" '{"foo":"bar","baz":42}' "$rule"
  [ "$status" -eq 0 ]
}

@test "match_rule: empty match object means match any input for that tool" {
  rule='{"tool":"Bash","match":{}}'
  run match_rule "Bash" '{"command":"anything goes"}' "$rule"
  [ "$status" -eq 0 ]
}

@test "match_rule: field missing from tool_input is a no-match" {
  rule='{"tool":"Read","match":{"file_path":"^/tmp/"}}'
  run match_rule "Read" '{}' "$rule"
  [ "$status" -eq 1 ]
}

@test "match_rule: field explicitly null in tool_input is a no-match" {
  rule='{"tool":"Read","match":{"file_path":"^/tmp/"}}'
  run match_rule "Read" '{"file_path":null}' "$rule"
  [ "$status" -eq 1 ]
}

@test "match_rule: invalid regex in .tool propagates as error (rc=2)" {
  rule='{"tool":"(unclosed","match":{"command":"^ls"}}'
  run match_rule "Bash" '{"command":"ls"}' "$rule"
  [ "$status" -eq 2 ]
}

@test "match_rule: invalid regex in .match field propagates as error (rc=2)" {
  rule='{"tool":"Bash","match":{"command":"(unclosed"}}'
  run match_rule "Bash" '{"command":"ls"}' "$rule"
  [ "$status" -eq 2 ]
}

# Directory-prefix regex: the core motivating example from the plan - matches a bash
# sub-argument path that native `Bash(prefix:*)` rules cannot express due to the
# word-boundary check matching how native Bash permission prefixes behave.
@test "match_rule: directory-prefix regex matches bash subcommand paths" {
  rule='{"tool":"Bash","match":{"command":"^bash /Users/[^/]+/\\.claude/plugins/.*/scripts/[a-z-]+\\.sh( |$)"}}'
  run match_rule "Bash" '{"command":"bash /Users/alice/.claude/plugins/cache/org-claude-passthru/scripts/verify.sh --quiet"}' "$rule"
  [ "$status" -eq 0 ]
  # Reject extension that is not .sh
  run match_rule "Bash" '{"command":"bash /Users/alice/.claude/plugins/cache/org-claude-passthru/scripts/evil.py"}' "$rule"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# find_first_match - iterate list, return first match
# ---------------------------------------------------------------------------

@test "find_first_match: returns first matching rule by index order" {
  rules='[
    {"tool":"Bash","match":{"command":"^rm"},"reason":"rm rule"},
    {"tool":"Bash","match":{"command":"^ls"},"reason":"ls rule"},
    {"tool":"Bash","match":{"command":"^ls -la$"},"reason":"ls-la specific"}
  ]'
  run find_first_match "$rules" "Bash" '{"command":"ls -la"}'
  [ "$status" -eq 0 ]
  # Output format is "<index>\t<rule-json>". Split with bash parameter expansion.
  idx="${output%%$'\t'*}"
  rule="${output#*$'\t'}"
  [ "$idx" = "1" ]
  run jq -r '.reason' <<<"$rule"
  [ "$output" = "ls rule" ]
}

@test "find_first_match: returns empty on no match" {
  rules='[{"tool":"Bash","match":{"command":"^rm"}}]'
  run find_first_match "$rules" "Bash" '{"command":"ls -la"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "find_first_match: empty rules array returns empty" {
  run find_first_match '[]' "Bash" '{"command":"ls"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "find_first_match: null rules returns empty" {
  run find_first_match 'null' "Bash" '{"command":"ls"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "find_first_match: propagates invalid-regex error with rule index" {
  rules='[
    {"tool":"Bash","match":{"command":"^ls"}},
    {"tool":"Bash","match":{"command":"(bad"}}
  ]'
  run find_first_match "$rules" "Bash" '{"command":"rm -rf"}'
  [ "$status" -eq 2 ]
  # Stderr (folded into $output by bats `run`) should reference the offending index.
  [[ "$output" == *"index 1"* ]] || [[ "$stderr" == *"index 1"* ]]
}

@test "find_first_match: matches Read rule in a mixed-tool rule list" {
  rules='[
    {"tool":"Bash","match":{"command":"^ls"},"reason":"ls"},
    {"tool":"Read","match":{"file_path":"^/tmp/"},"reason":"tmp"},
    {"tool":"WebFetch","match":{"url":"^https://github\\.com/"},"reason":"gh"}
  ]'
  run find_first_match "$rules" "Read" '{"file_path":"/tmp/foo.txt"}'
  [ "$status" -eq 0 ]
  rule="${output#*$'\t'}"
  run jq -r '.reason' <<<"$rule"
  [ "$output" = "tmp" ]
}

@test "find_first_match: matches WebFetch rule with url" {
  rules='[{"tool":"WebFetch","match":{"url":"^https://docs\\.anthropic\\.com/"},"reason":"anthropic"}]'
  run find_first_match "$rules" "WebFetch" '{"url":"https://docs.anthropic.com/claude/reference"}'
  [ "$status" -eq 0 ]
  rule="${output#*$'\t'}"
  run jq -r '.reason' <<<"$rule"
  [ "$output" = "anthropic" ]
}

@test "find_first_match: matches MCP tool-name-only rule" {
  rules='[{"tool":"^mcp__gemini-cli__","reason":"gemini family"}]'
  run find_first_match "$rules" "mcp__gemini-cli__ask-gemini" '{"prompt":"hi"}'
  [ "$status" -eq 0 ]
  rule="${output#*$'\t'}"
  run jq -r '.reason' <<<"$rule"
  [ "$output" = "gemini family" ]
}

@test "find_first_match: multi-field rule matches only when both fields match" {
  rules='[{"tool":"Bash","match":{"command":"^gh api","description":"forks"},"reason":"forks"}]'
  run find_first_match "$rules" "Bash" '{"command":"gh api /repos/foo/bar/forks","description":"list forks"}'
  [ "$status" -eq 0 ]
  rule="${output#*$'\t'}"
  run jq -r '.reason' <<<"$rule"
  [ "$output" = "forks" ]

  run find_first_match "$rules" "Bash" '{"command":"gh api /repos/foo/bar/branches","description":"list branches"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "find_first_match: returns the matched rule's index in TAB-prefix" {
  # A rule list where the third entry matches; index should be 2.
  rules='[
    {"tool":"Bash","match":{"command":"^rm"}},
    {"tool":"Bash","match":{"command":"^cat"}},
    {"tool":"Bash","match":{"command":"^echo"}}
  ]'
  run find_first_match "$rules" "Bash" '{"command":"echo hi"}'
  [ "$status" -eq 0 ]
  idx="${output%%$'\t'*}"
  [ "$idx" = "2" ]
}

# ---------------------------------------------------------------------------
# match_rule: jq injection guard via crafted match-key names
# ---------------------------------------------------------------------------

@test "match_rule: match key containing a double-quote is handled safely" {
  # A rule whose match-key name contains characters (here a quote) that
  # would have broken the older "interpolate-into-jq-program" code. The
  # rule must be evaluated as a normal field lookup, not crash, not
  # silently flip semantics.
  rule='{"tool":"Bash","match":{"weird\"key":"^ls$"}}'
  # Tool input has the SAME exotic key name with the matching value.
  run match_rule "Bash" '{"weird\"key":"ls"}' "$rule"
  [ "$status" -eq 0 ]
  # And the not-match path: same rule, different field value.
  run match_rule "Bash" '{"weird\"key":"rm"}' "$rule"
  [ "$status" -eq 1 ]
  # Missing field -> no match (rule fails).
  run match_rule "Bash" '{"other":"ls"}' "$rule"
  [ "$status" -eq 1 ]
}

@test "match_rule: match key containing a dot does not get path-interpreted by jq" {
  # `a.b` historically interpolated into jq as `.a.b` (a path lookup),
  # not `."a.b"` (a single-key lookup). With --arg the key is treated
  # literally regardless of interior dots.
  rule='{"tool":"Bash","match":{"a.b":"^x$"}}'
  run match_rule "Bash" '{"a.b":"x"}' "$rule"
  [ "$status" -eq 0 ]
  # And confirm `{"a":{"b":"x"}}` does NOT match (we want literal-key, not path).
  run match_rule "Bash" '{"a":{"b":"x"}}' "$rule"
  [ "$status" -eq 1 ]
}
