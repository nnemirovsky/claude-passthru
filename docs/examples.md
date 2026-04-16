# Rule examples

Real-world passthru rules across `Bash`, `PowerShell`, `Read`, `Edit`, `Write`, `WebFetch`, and MCP tools. Each entry shows the rule JSON, what it matches, and what it does NOT match. Copy-paste into the `allow[]`, `deny[]`, or `ask[]` array of your `passthru.json`.

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

## 13. Ask before fetching non-allowlisted domains

Silent-allow the specific domains you trust, but prompt on everything else. Useful when you have a blanket WebFetch allow set elsewhere and want to force eyeballs on out-of-band URLs. Put this in `ask[]`.

```json
{
  "tool": "WebFetch",
  "match": { "url": "^https?://(?!example\\.com)" },
  "reason": "prompt for non-example-domain URLs"
}
```

**Matches (overlay fires).**

* `https://api.github.com/repos/foo/bar`
* `https://raw.githubusercontent.com/anthropics/claude-code/README.md`

**Does not match (silently proceeds per other rules, or to native dialog).**

* `https://example.com/docs/guide`

Add via:

```
/passthru:add --ask user WebFetch "^https?://(?!example\\.com)" "prompt for non-example-domain URLs"
```

This uses a negative-lookahead `(?!example\\.com)`. PCRE (perl) supports lookaheads natively; the verifier checks that your regex compiles in perl so the rule fails loud if you typo the pattern.

## 14. Ask before reading outside the project directory

Prompt before `Read` touches anything under `~/.ssh`. Put this in `ask[]`. Combine with an `allow[]` rule scoped to your workspace for zero-prompt access to the project.

```json
{
  "tool": "Read",
  "match": { "file_path": "^/Users/.*/\\.ssh" },
  "reason": "prompt before reading anything under .ssh"
}
```

**Matches (overlay fires).**

* `/Users/you/.ssh/id_ed25519`
* `/Users/you/.ssh/config`

**Does not match.**

* `/Users/you/Developer/myproject/README.md`
* `/etc/ssh/sshd_config` (not under `/Users/.*/.ssh`)

Add via:

```
/passthru:add --ask user Read "^/Users/.*/\\.ssh" "prompt before reading anything under .ssh"
```

## 15. Ask on every call to a half-trusted MCP server

You trust `mcp__gemini-cli__*` enough to auto-allow, but a second MCP server is new and you want to audit every call for a while. No `match` block needed; tool-name filter is enough for namespace-scoped prompts.

```json
{
  "tool": "^mcp__untrusted__",
  "reason": "prompt on all calls to the untrusted MCP server"
}
```

**Matches (overlay fires).**

* `mcp__untrusted__fetch_data`
* `mcp__untrusted__update_record`

**Does not match.**

* `mcp__gemini-cli__ask-gemini` (different server)
* `mcp_untrusted_x` (different prefix)

Add via:

```
/passthru:add --ask user '^mcp__untrusted__' "prompt on all calls to the untrusted MCP server"
```

## 16. Narrow allow wins over broad ask (document order)

`allow` and `ask` tie-break by document order within the merged list, not by list name. Put the narrow rule first:

```json
{
  "version": 2,
  "allow": [
    { "tool": "Bash", "match": { "command": "^git push origin main$" }, "reason": "mainline push is fine" }
  ],
  "ask": [
    { "tool": "Bash", "match": { "command": "^git push" }, "reason": "double-check any other push target" }
  ]
}
```

**Matches (silent allow).**

* `git push origin main` (hits the narrow allow in `allow[]` first)

**Matches (overlay fires on the ask).**

* `git push origin feature/foo`
* `git push --force origin main`

**Does not match.**

* `git status`
* `git commit` (falls through to other rules or native dialog)

If you flipped the order (ask declared before allow, broad pattern before narrow), the ask would catch `git push origin main` first and you would get a prompt on every push. Document order is the tie-breaker, so put the rule you want to win higher up in the file.

## Tips

* **Anchor intentionally.** `^` at the start pins the leading portion. Trailing `$` pins the end. Without anchors the regex matches anywhere in the string.
* **Escape `.` and `\\s`.** JSON requires double-escaping `\\`. Inside the regex engine `\\.` becomes `\.` and matches a literal dot.
* **Character classes over wildcards.** Prefer `[^/]+` (one-or-more non-slash) over `.*` in path regex to avoid accidentally spanning path separators.
* **Ask rules are for prompts, not policy.** Put "always allow" in `allow[]` and "always deny" in `deny[]`. Put "ask me every time" in `ask[]`. Do not use ask as a weak allow. See [`rule-format.md`](rule-format.md#decision-flow) for the full decision flow.
* **Run `/passthru:suggest` after the fact.** When a permission dialog fires on a call you want to auto-allow later, ask the slash command to draft a rule. It generalizes owner/repo/version variables for you.
