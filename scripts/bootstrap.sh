#!/usr/bin/env bash
# claude-passthru bootstrap importer.
#
# One-time migration from native Claude Code `permissions.allow` entries
# (stored in settings.json / settings.local.json) into passthru rule files.
# Writes imported rules to:
#   ~/.claude/passthru.imported.json         (user scope)
#   $CWD/.claude/passthru.imported.json      (project scope)
#
# The authored `passthru.json` files are NEVER touched: they remain the
# hand-managed source of truth for human-curated rules.
#
# Supported conversions:
#   Bash(<prefix>:*)          -> {tool:"Bash", match:{command:"^<escaped>(\\s|$)"}}
#   Bash(<exact command>)     -> {tool:"Bash", match:{command:"^<escaped>$"}}
#   mcp__server__tool         -> {tool:"^mcp__server__tool$"}
#   WebFetch(domain:x.com)    -> {tool:"WebFetch",
#                                 match:{url:"^https?://([^/.]+\\.)*x\\.com([/:?#]|$)"}}
#
# Unknown shapes (rules with spaces past the prefix, unrecognized forms) are
# skipped with a warning printed to stderr.
#
# Flags:
#   --write            actually write; default is a dry-run that prints JSON to stdout.
#   --user-only        only scan/import user scope.
#   --project-only     only scan/import project scope.
#   --help / -h        usage.
#
# Paths honor PASSTHRU_USER_HOME + PASSTHRU_PROJECT_DIR for hermetic tests.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate plugin root (for verify.sh invocation)
# ---------------------------------------------------------------------------

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/verify.sh" ]; then
  _PASSTHRU_PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  _PASSTHRU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _PASSTHRU_PLUGIN_ROOT="$(cd "${_PASSTHRU_SCRIPT_DIR}/.." && pwd)"
fi

VERIFY_SH="${_PASSTHRU_PLUGIN_ROOT}/scripts/verify.sh"

# Pull in PASSTHRU_CANON_JQ (and any other shared constants) so the import-time
# dedup filter stays in lockstep with verify.sh's canonical identity.
# shellcheck disable=SC1091
source "${_PASSTHRU_PLUGIN_ROOT}/hooks/common.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

WRITE=0
SCOPE="all"  # all | user | project

print_usage() {
  cat <<'USAGE'
usage: bootstrap.sh [--write] [--user-only|--project-only] [--help]

Imports native Claude Code `permissions.allow` entries from settings.json
files into passthru.imported.json rule files.

Default mode: print proposed rules to stdout as JSON for review.
--write:      persist to disk, then run scripts/verify.sh --quiet.
              On verifier failure, restore backups and exit non-zero.
--user-only:  limit to ~/.claude/settings.json.
--project-only: limit to $CWD/.claude/settings{,.local}.json.

Paths honor PASSTHRU_USER_HOME and PASSTHRU_PROJECT_DIR.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --write) WRITE=1; shift ;;
    --user-only)
      if [ "$SCOPE" = "project" ]; then
        printf 'bootstrap.sh: --user-only and --project-only are mutually exclusive\n' >&2
        exit 1
      fi
      SCOPE="user"; shift ;;
    --project-only)
      if [ "$SCOPE" = "user" ]; then
        printf 'bootstrap.sh: --user-only and --project-only are mutually exclusive\n' >&2
        exit 1
      fi
      SCOPE="project"; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *)
      printf 'bootstrap.sh: unknown argument: %s\n' "$1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve source and target paths
# ---------------------------------------------------------------------------

USER_HOME="${PASSTHRU_USER_HOME:-$HOME}"
PROJECT_DIR="${PASSTHRU_PROJECT_DIR:-$PWD}"

USER_SETTINGS="$USER_HOME/.claude/settings.json"
PROJECT_SETTINGS_SHARED="$PROJECT_DIR/.claude/settings.json"
PROJECT_SETTINGS_LOCAL="$PROJECT_DIR/.claude/settings.local.json"

USER_IMPORTED="$USER_HOME/.claude/passthru.imported.json"
PROJECT_IMPORTED="$PROJECT_DIR/.claude/passthru.imported.json"

# ---------------------------------------------------------------------------
# Regex-escape helper (for bash prefix literals)
# ---------------------------------------------------------------------------
# Escapes every regex metacharacter in the input so it becomes a safe literal
# inside a regex. Uses perl because sed incantations vary between BSD/GNU.
regex_escape() {
  local s="$1"
  perl -e 'print quotemeta($ARGV[0])' "$s"
}

# ---------------------------------------------------------------------------
# Domain escape for WebFetch: escape only the dots in the hostname
# (non-literal bytes are rejected earlier).
# ---------------------------------------------------------------------------
domain_escape() {
  local s="$1"
  # Escape dots only, since hostname chars [a-z0-9-] have no regex metacharacter
  # meaning. Anything stranger is passed through quotemeta for safety.
  perl -e '
    my $s = $ARGV[0];
    if ($s =~ /^[A-Za-z0-9.\-]+$/) {
      $s =~ s/\./\\./g;
      print $s;
    } else {
      print quotemeta($s);
    }
  ' "$s"
}

# ---------------------------------------------------------------------------
# Convert a single native rule string to a passthru rule JSON object.
# Prints a single-line JSON object on success, nothing on skip.
# Prints a `[WARN] ...` message to stderr on unsupported forms.
# Returns 0 always (caller handles empty output).
# ---------------------------------------------------------------------------
convert_rule() {
  local raw="$1"
  local json=""

  # Strip leading/trailing whitespace.
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"

  if [ -z "$raw" ]; then
    return 0
  fi

  # Match Bash(...) form, captured inner content stripped of the outer parens.
  if [[ "$raw" == Bash\(*\) ]]; then
    local inner="${raw#Bash(}"
    inner="${inner%)}"

    # Two sub-forms:
    #   prefix:*        -> command must start with prefix and be followed by space|eol
    #   exact command   -> command must match exactly (anchored both ends)
    if [[ "$inner" == *:\* ]]; then
      local prefix="${inner%:\*}"
      # Reject prefixes that contain inner spaces; those would need manual review.
      # (A "prefix" like `git status` is fine, but `git status --foo` with spaces
      # past the prefix-of-prefix is usually user intent that doesn't trivially
      # transform. We preserve any spaces in the prefix - they are literal in
      # the shell line - and only require the start-anchor plus word-boundary.)
      if [ -z "$prefix" ]; then
        printf '[WARN] skipping rule with empty Bash prefix: %s\n' "$raw" >&2
        return 0
      fi
      local escaped
      escaped="$(regex_escape "$prefix")"
      json="$(jq -cn \
        --arg cmd "^${escaped}(\\s|\$)" \
        '{tool:"Bash", match:{command:$cmd}, reason:"imported from settings"}')"
    else
      # Exact Bash command: accept only if it looks like a sane shell line (no
      # embedded newlines). Convert to an anchored regex.
      if [[ "$inner" == *$'\n'* ]]; then
        printf '[WARN] skipping Bash rule with embedded newline: %s\n' "$raw" >&2
        return 0
      fi
      local escaped
      escaped="$(regex_escape "$inner")"
      json="$(jq -cn \
        --arg cmd "^${escaped}\$" \
        '{tool:"Bash", match:{command:$cmd}, reason:"imported from settings"}')"
    fi

  elif [[ "$raw" == WebFetch\(domain:*\) ]]; then
    local domain="${raw#WebFetch(domain:}"
    domain="${domain%)}"
    # Strip any accidental whitespace.
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    if [ -z "$domain" ]; then
      printf '[WARN] skipping WebFetch rule with empty domain: %s\n' "$raw" >&2
      return 0
    fi
    local escaped_domain
    escaped_domain="$(domain_escape "$domain")"
    # Require the host to be exactly `domain` or to end with `.domain` (so
    # `evilx.com` cannot match a rule for `x.com`). The trailing character
    # class admits every URL delimiter that can legally follow the host in
    # RFC 3986 authority syntax: `/` (path), `:` (port), `?` (query),
    # `#` (fragment), or end-of-string. The old `(/|$)` form rejected
    # same-host URLs like `https://x.com?foo=1` and `https://x.com#frag`
    # which the native `WebFetch(domain:x.com)` rule does cover.
    json="$(jq -cn \
      --arg url "^https?://([^/.]+\\.)*${escaped_domain}([/:?#]|\$)" \
      '{tool:"WebFetch", match:{url:$url}, reason:"imported from settings"}')"

  elif [[ "$raw" == WebFetch\(*\) ]]; then
    printf '[WARN] skipping WebFetch rule with unsupported form: %s\n' "$raw" >&2
    return 0

  elif [[ "$raw" == mcp__* ]]; then
    # Exact MCP tool identifier. Must not contain parens.
    if [[ "$raw" == *"("* ]] || [[ "$raw" == *")"* ]]; then
      printf '[WARN] skipping MCP rule with unexpected punctuation: %s\n' "$raw" >&2
      return 0
    fi
    local escaped
    escaped="$(regex_escape "$raw")"
    json="$(jq -cn \
      --arg tool "^${escaped}\$" \
      '{tool:$tool, reason:"imported from settings"}')"

  else
    printf '[WARN] skipping unknown rule format: %s\n' "$raw" >&2
    return 0
  fi

  printf '%s\n' "$json"
}

# ---------------------------------------------------------------------------
# Convert a settings.json file into an array of passthru rule JSON objects.
# Prints the JSON array (possibly empty) on stdout.
# Exits non-zero (via set -e) if the file is malformed.
# ---------------------------------------------------------------------------
convert_settings_file() {
  local settings="$1"
  if [ ! -f "$settings" ]; then
    printf '[]\n'
    return 0
  fi

  # Parse check - surface a clear error if malformed.
  if ! jq -e '.' "$settings" >/dev/null 2>&1; then
    printf 'bootstrap.sh: cannot parse settings file: %s\n' "$settings" >&2
    return 2
  fi

  local allow_json
  allow_json="$(jq -c '(.permissions.allow // []) | map(select(type == "string"))' "$settings")"

  local n
  n="$(jq -r 'length' <<<"$allow_json")"
  if [ "$n" = "0" ]; then
    printf '[]\n'
    return 0
  fi

  local -a rules=()
  local entry converted
  # Stream each allow entry as a single jq pass (one fork instead of N).
  # `jq -r '.[]'` emits each element as its native shape (raw string for
  # strings, JSON for anything else). convert_rule only needs the string
  # form; non-string entries are warned about and dropped downstream.
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -z "$entry" ] && continue
    converted="$(convert_rule "$entry")"
    if [ -n "$converted" ]; then
      rules+=("$converted")
    fi
  done < <(jq -r '.[]' <<<"$allow_json" 2>/dev/null)

  if [ "${#rules[@]}" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi

  # Merge into a JSON array.
  printf '%s\n' "${rules[@]}" | jq -s '.'
}

# ---------------------------------------------------------------------------
# Merge rule arrays, dedup by identity (tool + match), preserve first occurrence.
# Preserves input order (unlike jq's unique_by which sorts).
# ---------------------------------------------------------------------------
dedup_rules() {
  # stdin: a JSON array of rules (possibly with duplicates)
  # stdout: a JSON array with first-occurrence kept, original ordering preserved
  # Uses PASSTHRU_CANON_JQ from common.sh so identity semantics match verify.sh.
  jq "
    def canon: ${PASSTHRU_CANON_JQ} | tojson;
"'    reduce .[] as $r ([[], []];
      (.[0]) as $seen
      | (.[1]) as $out
      | ($r | canon) as $id
      | if ($seen | index($id)) then .
        else [($seen + [$id]), ($out + [$r])] end)
    | .[1]
  '
}

# ---------------------------------------------------------------------------
# Produce the imported JSON document for a scope.
# Arg $1: JSON array of rule objects.
# Stdout: full `{version:1, allow:[...], deny:[]}` document.
# ---------------------------------------------------------------------------
wrap_document() {
  local rules="$1"
  jq -cn --argjson allow "$rules" \
    '{version:1, allow:$allow, deny:[]}'
}

# ---------------------------------------------------------------------------
# Collect rules per scope
# ---------------------------------------------------------------------------

USER_RULES="[]"
PROJECT_RULES="[]"

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "user" ]; then
  user_converted="$(convert_settings_file "$USER_SETTINGS")"
  USER_RULES="$user_converted"
fi

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "project" ]; then
  # Project scope reads both settings.json (shared) and settings.local.json.
  # Local takes precedence on duplicates; but we simply concat and dedup by
  # identity, first-seen wins.
  proj_shared="$(convert_settings_file "$PROJECT_SETTINGS_SHARED")"
  proj_local="$(convert_settings_file "$PROJECT_SETTINGS_LOCAL")"
  PROJECT_RULES="$(jq -cn \
    --argjson a "$proj_shared" \
    --argjson b "$proj_local" \
    '$a + $b')"
fi

USER_RULES="$(printf '%s' "$USER_RULES" | dedup_rules)"
PROJECT_RULES="$(printf '%s' "$PROJECT_RULES" | dedup_rules)"

USER_DOC="$(wrap_document "$USER_RULES")"
PROJECT_DOC="$(wrap_document "$PROJECT_RULES")"

# ---------------------------------------------------------------------------
# Dry-run: pretty-print the proposed output to stdout.
# ---------------------------------------------------------------------------

if [ "$WRITE" -ne 1 ]; then
  if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "user" ]; then
    printf '# would write: %s\n' "$USER_IMPORTED"
    printf '%s\n' "$USER_DOC" | jq '.'
  fi
  if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "project" ]; then
    printf '# would write: %s\n' "$PROJECT_IMPORTED"
    printf '%s\n' "$PROJECT_DOC" | jq '.'
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Write mode: back up existing .imported.json files, write, then verify.
# ---------------------------------------------------------------------------

BACKUP_DIR="$(mktemp -d -t passthru-bootstrap.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -rf '$BACKUP_DIR'" EXIT

USER_BACKUP=""
PROJECT_BACKUP=""

backup_existing() {
  local src="$1" tag="$2"
  if [ -f "$src" ]; then
    local dst="$BACKUP_DIR/$tag"
    cp -p "$src" "$dst"
    printf '%s' "$dst"
  else
    printf ''
  fi
}

restore_backup() {
  local src="$1" dst="$2"
  if [ -n "$src" ] && [ -f "$src" ]; then
    cp -p "$src" "$dst"
  else
    # No prior file: remove the one we created.
    rm -f "$dst"
  fi
}

write_document() {
  local doc="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  # Atomic write via mv-over.
  local tmp
  tmp="$(mktemp -t passthru-bootstrap-write.XXXXXX)"
  printf '%s\n' "$doc" | jq '.' > "$tmp"
  mv "$tmp" "$dst"
}

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "user" ]; then
  USER_BACKUP="$(backup_existing "$USER_IMPORTED" user.json)"
  write_document "$USER_DOC" "$USER_IMPORTED"
fi

if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "project" ]; then
  PROJECT_BACKUP="$(backup_existing "$PROJECT_IMPORTED" project.json)"
  write_document "$PROJECT_DOC" "$PROJECT_IMPORTED"
fi

# Run verifier.
VERIFY_ERR=""
set +e
VERIFY_ERR="$(bash "$VERIFY_SH" --quiet 2>&1 >/dev/null)"
VERIFY_RC=$?
set -e

if [ "$VERIFY_RC" -ne 0 ]; then
  # Roll back.
  if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "user" ]; then
    restore_backup "$USER_BACKUP" "$USER_IMPORTED"
  fi
  if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "project" ]; then
    restore_backup "$PROJECT_BACKUP" "$PROJECT_IMPORTED"
  fi
  printf 'bootstrap.sh: verifier rejected imported rules; rolled back\n' >&2
  if [ -n "$VERIFY_ERR" ]; then
    printf '%s\n' "$VERIFY_ERR" >&2
  fi
  exit 1
fi

# Report.
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "user" ]; then
  printf 'wrote %s\n' "$USER_IMPORTED"
fi
if [ "$SCOPE" = "all" ] || [ "$SCOPE" = "project" ]; then
  printf 'wrote %s\n' "$PROJECT_IMPORTED"
fi

exit 0
