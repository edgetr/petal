@AGENTS.md

# Claude-specific notes

`AGENTS.md` above is shared with Codex, Gemini and opencode and stays provider-neutral. This part holds only what is specific to Claude Code: the Claude app, T3 Code and Petal's own Claude panel all run it on this repo.

## Instruction files

- Claude Code loads `AGENTS.md` only through the import above, because this project has a `CLAUDE.md`. Keep every rule that all agents need in `AGENTS.md`.
- Claude's auto-memory is only for facts about this machine and session history. A rule every agent should follow goes in `AGENTS.md`, or Codex and Gemini threads in T3 will never see it.

## Petal's own Claude

- Petal's Claude panel is a Claude Code session too (`Agent.qml` on Omarchy, `Claude.swift` on macOS): it gets the `mcp__petal` tools and `~/.config/petal/instructions.md`. When a change here touches what that Claude can do (a new setting, tool or mode field), update `SETTINGS_SCHEMA` and the tool descriptions in `petal-mcp.py` so it knows, and its macOS system prompt in `Claude.swift` if the change is Mac-only.
- To change the owner's dock (settings, the dock's apps on the Mac, modes on Omarchy), prefer the `mcp__petal` tools when they are connected; otherwise edit `~/.config/petal/` directly. Either way Petal reloads live.
- Petal calls Haiku at low effort for sorting and uses the chat model the user picks. Keep new background calls on Haiku; they count toward the user's Claude usage.

## Skills and commands

- `omarchy`: load it before editing anything in `~/.config/hypr/`, `~/.config/omarchy/` or other Omarchy config. Petal's own `~/.config/petal/` is covered by `AGENTS.md`.
- `/code-review` and `/security-review`: the independent review must come from a reviewer that didn't write the code. Use a fresh subagent, or in T3 a `delegate_task` to another provider for a second model's view.
- `/simplify`: cleanup pass after a feature lands.
- `frontend-design` and other generic design skills are subordinate to the design language in `AGENTS.md`. The dock and the marketing site are different systems; on `site/`, follow Edgetr's. When a skill disagrees (gradients, grain, busy copy, real screenshots, fake product demos), follow `AGENTS.md`.

## T3 Code

- T3 tools (`delegate_task`, `link_pull_request`, `t3_thread_launch`, previews) exist only when this runs inside T3, not in the Claude app or Petal's panel. Don't assume them.
- Call `link_pull_request` for every PR you open or work on.
- T3 creates its own worktrees under `~/.t3/worktrees/`, separate from Claude Code's `.claude/worktrees/`. Remove a worktree and its local branch once its branch has merged or been pushed to `main`.
- A worktree is not the installed plugin: only `~/Projects/Petal/plugin` is live. To try a worktree's change on the real dock, merge it into the main checkout first, or say it wasn't run.
- For parallel work, give each delegated agent its own worktree (`isolation: "worktree"`). It starts from the last local commit, so commit what it needs first.
