# Privacy policy

passthru runs entirely on your machine. It has no server, makes no network requests and collects no telemetry. Nothing is sent to the author or to any third party.

## What it reads

- The name and input of each tool call, which Claude Code hands to its hooks, to match them against your rules.
- The rule files `passthru.json` and `passthru.imported.json`, in `~/.claude/` and in the project's `.claude/`.
- Claude Code's settings: `~/.claude/settings.json`, `.claude/settings.json` and `.claude/settings.local.json`. Bootstrap and the session start hint read `permissions.allow` and `additionalAllowedWorkingDirs` from them. With the audit log on, the hooks also compare their hashes to tell how the native dialog was answered.

## What it writes

- Rule files, only when you add a rule (`/passthru:add`, `/passthru:suggest` or "always" in the overlay), remove one, or run bootstrap with `--write`. A lock directory `~/.claude/passthru.write.lock.d` and a backup of the file exist only while it writes.
- The sentinel files `~/.claude/passthru.audit.enabled` and `~/.claude/passthru.overlay.disabled`, when you toggle the audit log or the overlay.
- The audit log `~/.claude/passthru-audit.log`, only when you turn it on. Each line holds the time, the decision, the tool name, the reason, the matched rule and the tool use id. It does not hold the tool input. It has no rotation, so it grows until you remove or rotate it.
- Short-lived files in `$TMPDIR`: the overlay's verdict and the environment it passes to its popup, which include the tool input. With the audit log on, a `passthru-pre-<tool use id>.json` file also holds the tool input until the call finishes.

It never changes Claude Code's own settings files.

## Where it sends data

Nowhere. The overlay shows the tool name and input in a tmux, kitty or wezterm popup on your own machine.

## Contact

Questions go to [GitHub issues](https://github.com/nnemirovsky/claude-passthru/issues).
