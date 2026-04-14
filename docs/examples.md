# Rule examples

Real-world passthru rules across `Bash`, `PowerShell`, `Read`, `Edit`, `Write`, `WebFetch`, and MCP tools. Each entry shows the rule JSON, what it matches, and what it does NOT match. Copy-paste into the `allow[]` or `deny[]` array of your `passthru.json`.

See [`rule-format.md`](rule-format.md) for the full schema reference.

## 1. Directory-prefix for Bash scripts

Allow any `bash` invocation targeting a specific directory prefix.

```json
{
  "tool": "Bash",
  "match": { "command": "^bash /Users/you/scripts/" },
  "reason": "local scripts"
}
```

**Matches.**

* `bash /Users/you/scripts/deploy.sh`
* `bash /Users/you/scripts/nested/build.sh`

**Does not match.**

* `bash /etc/init.d/foo` (different prefix)
* `sh /Users/you/scripts/deploy.sh` (different interpreter)
* `cd /Users/you/scripts && bash deploy.sh` (command does not start with `bash /Users/you/scripts/`)

The last near-miss is the common footgun: the hook matches on the raw command string, so compound commands need a different rule.

## 2. gh api repo forks across any owner/repo

Allow `gh api /repos/<owner>/<repo>/forks` for any owner and repo.

```json
{
  "tool": "Bash",
  "match": { "command": "^gh api /repos/[^/]+/[^/]+/forks" },
  "reason": "github forks api reads"
}
```

**Matches.**

* `gh api /repos/anthropics/claude-code/forks`
* `gh api /repos/nemirovsky/claude-passthru/forks?page=2`

**Does not match.**

* `gh api /repos/anthropics/claude-code/issues` (different endpoint)
* `gh api /user/repos` (different shape)
* `curl https://api.github.com/repos/anthropics/claude-code/forks` (different tool usage)

## 3. git read-only subcommands

Allow safe git inspection commands.

```json
{
  "tool": "Bash",
  "match": { "command": "^git (status|log|diff|show|branch)( |$)" },
  "reason": "read-only git inspection"
}
```

**Matches.**

* `git status`
* `git log --oneline`
* `git diff HEAD~5..HEAD`
* `git branch`

**Does not match.**

* `git push origin main` (not in the allow list)
* `git commit -m "foo"` (not listed)
* `git statussss` (the `( |$)` boundary prevents partial matches)

## 4. PowerShell Get- cmdlets

Allow read-only PowerShell cmdlets.

```json
{
  "tool": "PowerShell",
  "match": { "command": "^Get-" },
  "reason": "read-only powershell"
}
```

**Matches.**

* `Get-Process`
* `Get-ChildItem -Path C:\\`
* `Get-Item .`

**Does not match.**

* `Remove-Item foo` (different verb)
* `Set-Location C:\\` (different verb)
* `echo (Get-Process)` (pipeline does not start with `Get-`)

## 5. Read and Edit within a specific project

Allow `Read` and `Edit` for any file under a project root.

```json
{
  "tool": "Read|Edit|Write",
  "match": { "file_path": "^/Users/you/Developer/myproject/" },
  "reason": "myproject workspace"
}
```

**Matches.**

* `Read /Users/you/Developer/myproject/src/main.ts`
* `Edit /Users/you/Developer/myproject/README.md`

**Does not match.**

* `Read /Users/you/Developer/other/README.md` (different project)
* `Read /etc/passwd` (not under the project root)

## 6. WebFetch scoped to api.github.com

Allow any URL on `api.github.com`.

```json
{
  "tool": "WebFetch",
  "match": { "url": "^https?://api\\.github\\.com(/|$)" },
  "reason": "github api fetches"
}
```

**Matches.**

* `https://api.github.com/repos/foo/bar`
* `http://api.github.com`
* `https://api.github.com/`

**Does not match.**

* `https://api.github.com.evil.example/` (the `(/|$)` prevents subdomain hijacks)
* `https://github.com/foo/bar` (different host)
* `https://api.github.co.m/foo` (dot in regex is escaped)

## 7. WebFetch for all subdomains of a company domain

Allow any subdomain of `example.com`.

```json
{
  "tool": "WebFetch",
  "match": { "url": "^https?://([^/.]+\\.)*example\\.com(/|$)" },
  "reason": "example.com domain and subdomains"
}
```

**Matches.**

* `https://example.com/`
* `https://www.example.com`
* `https://api.staging.example.com/health`

**Does not match.**

* `https://example.com.evil.com` (anchor is `(/|$)`, not `.`)
* `https://evil-example.com` (prefix check fails)

## 8. MCP server namespace

Allow every tool on the `gemini-cli` MCP server without listing each one.

```json
{
  "tool": "^mcp__gemini-cli__",
  "reason": "gemini mcp server"
}
```

**Matches.**

* `mcp__gemini-cli__ask-gemini`
* `mcp__gemini-cli__brainstorm`
* `mcp__gemini-cli__ping`

**Does not match.**

* `mcp__google-maps__maps_geocode` (different server)
* `gemini-cli` (missing MCP prefix)

Note there is no `match` block. MCP-namespace rules key off the tool name only.

## 9. MCP single tool, pinned exactly

Allow exactly one MCP tool.

```json
{
  "tool": "^mcp__gemini-cli__ask-gemini$",
  "reason": "gemini ask only"
}
```

**Matches.**

* `mcp__gemini-cli__ask-gemini`

**Does not match.**

* `mcp__gemini-cli__brainstorm` (different tool)
* `mcp__gemini-cli__ask-gemini-v2` (the trailing `$` prevents this)

## 10. Deny rule: rm -rf patterns (safety)

Deny destructive patterns across any shell tool, even if broader allow rules would pass.

```json
{
  "tool": "Bash|PowerShell",
  "match": { "command": "rm\\s+-rf\\s+/" },
  "reason": "safety"
}
```

**Matches.**

* `rm -rf /`
* `echo hi; rm -rf /var/log` (substring match, no `^` anchor)
* `rm  -rf  /home/foo` (the `\s+` handles multiple spaces)

**Does not match.**

* `rm -rf foo/` (leading `/` required after the flag)
* `rmdir /tmp/foo` (different command)

Place this in `deny[]`. Deny has priority over allow, so even if you also have `{"tool":"Bash","match":{"command":"^rm "}}` in `allow[]`, the deny wins.

## 11. Deny rule: secret-looking WebFetch URLs

Deny any WebFetch whose URL looks like it's trying to exfiltrate secrets.

```json
{
  "tool": "WebFetch",
  "match": { "url": "(token|secret|apikey)=" },
  "reason": "block accidental secret leakage"
}
```

**Matches.**

* `https://example.com/log?token=abc`
* `https://analytics.example.com/?apikey=xyz`

**Does not match.**

* `https://example.com/docs/token-guide` (no `=`)
* `https://example.com/api/v1/` (no suspicious query string)

## 12. Restrict a tool by both name and input

Allow `Edit` but only inside a test file pattern.

```json
{
  "tool": "^Edit$",
  "match": { "file_path": "/tests/.*\\.bats$" },
  "reason": "tests only"
}
```

**Matches.**

* `/repo/tests/hook.bats`
* `/repo/tests/sub/verifier.bats`

**Does not match.**

* `/repo/tests/fixtures/rule.json` (wrong extension)
* `/repo/src/foo.ts` (not under `/tests/`)

## Tips

* **Anchor intentionally.** `^` at the start pins the leading portion. Trailing `$` pins the end. Without anchors the regex matches anywhere in the string.
* **Escape `.` and `\\s`.** JSON requires double-escaping `\\`. Inside the regex engine `\\.` becomes `\.` and matches a literal dot.
* **Character classes over wildcards.** Prefer `[^/]+` (one-or-more non-slash) over `.*` in path regex to avoid accidentally spanning path separators.
* **Run `/passthru:suggest` after the fact.** When a permission dialog fires on a call you want to auto-allow later, ask the slash command to draft a rule. It generalizes owner/repo/version variables for you.
