@AGENTS.md

# Claude-specific notes

`AGENTS.md` above is shared with Codex, Gemini and opencode and stays provider-neutral. This part holds only what is specific to Claude Code: the Claude app, T3 Code and Petal's own Claude panel all run it on this repo.

## Instruction files

- Claude Code loads `AGENTS.md` only through the import above, because this project has a `CLAUDE.md`. Keep every rule that all agents need in `AGENTS.md`.
- Claude's auto-memory is only for facts about this machine and session history. A rule every agent should follow goes in `AGENTS.md`, or Codex and Gemini threads in T3 will never see it.

## Petal's own Claude

- Petal's Claude panel is a Claude Code session too (`Claude.swift`): it gets the `mcp__petal` tools (Petal itself, `Petal --mcp`) and `~/.config/petal/instructions.md`. When a change here touches what that Claude can do (a new setting or tool), add the setting to `Settings.swift` with its help, the tool to `macos/Resources/mcp/tools.json` and `MCP.swift`, and say so in its system prompt in `Claude.swift` when it needs to know how to use it.
- To change the owner's dock (settings, the dock's apps), prefer the `mcp__petal` tools when they are connected; otherwise edit `~/.config/petal/` directly. Either way Petal reloads live.
- Petal calls Haiku at low effort for its quick calls and uses the chat model the user picks. Keep new background calls on Haiku; they count toward the user's Claude usage.

## Skills and commands

- `/code-review` and `/security-review`: the independent review must come from a reviewer that didn't write the code. Use a fresh subagent, or in T3 a `delegate_task` to another provider for a second model's view.
- `/simplify`: cleanup pass after a feature lands.
- `frontend-design` and other generic design skills are subordinate to the design language in `AGENTS.md`. The app and the marketing site are different systems; on `site/`, follow Edgetr's. When a skill disagrees (gradients, grain, busy copy, real screenshots, fake product demos), follow `AGENTS.md`.

## T3 Code

- T3 tools (`delegate_task`, `link_pull_request`, `t3_thread_launch`, previews) exist only when this runs inside T3, not in the Claude app or Petal's panel. Don't assume them.
- Call `link_pull_request` for every PR you open or work on.
- T3 creates its own worktrees under `~/.t3/worktrees/`, separate from Claude Code's `.claude/worktrees/`. Remove a worktree and its local branch once its branch has merged or been pushed to `main`.
- A worktree is not the installed app: only the Petal.app in `/Applications` runs as the owner's dock. A worktree's build can be checked without running as the dock (`AGENTS.md`, Verification); say when a change wasn't run as the dock.
- For parallel work, give each delegated agent its own worktree (`isolation: "worktree"`). It starts from the last local commit, so commit what it needs first.
