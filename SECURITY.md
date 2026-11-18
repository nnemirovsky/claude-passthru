# Security policy

## Reporting a vulnerability

Report privately through GitHub, not in a public issue:

**[Open a private security advisory](https://github.com/nnemirovsky/claude-passthru/security/advisories/new)**

The report is visible only to the maintainer ([@nnemirovsky](https://github.com/nnemirovsky)) until an advisory is published, so nothing sensitive is exposed while a fix is prepared. Expect an acknowledgement within a week.

If the form is unavailable, open a normal issue that says only "I would like a private channel for a security report", with no details, and a private advisory will be opened for you.

Never attach real credentials, tokens, personal data or private files to a report. Describe the shape of the problem instead.

## Supported versions

Only the latest release gets security fixes.

## Scope

passthru decides whether a tool call runs without a prompt, so any way past that decision counts. In scope:

- A call allowed that no rule, read-only check or permission-mode check should allow. Examples: a compound Bash command that slips a segment past the splitter, a read-only command whose arguments reach outside the working directory and allowed dirs, or a path that escapes them with `..`.
- A deny rule that does not block a call it matches.
- A rule proposed by the overlay, `/passthru:suggest` or bootstrap that matches more than the call it was built from, for example one that lets shell operators through.
- Temporary files in `$TMPDIR` that let another local user read a tool call's input or change an overlay verdict.
- Writing outside the rule files, sentinels, lock directory, audit log and temporary files listed in PRIVACY.md.

Out of scope:

- Rules you wrote that are wider than you meant. `/passthru:verify` finds invalid regex and conflicts but cannot know intent.
- Rules a project ships in its own `.claude/passthru.json`. passthru loads them as written, the same way Claude Code loads that project's `.claude/settings.json`, so check them before you work in a repository you do not trust.
- Calls the native permission system allows after passthru passes them through.
- Anything that needs an attacker who can already run code as you or edit `~/.claude`.

