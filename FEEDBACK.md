# EDA Agent Feedback Log

This append-only log captures concrete blockers and development-process ideas
noticed by AI agents while working in this repository. Its purpose is to make
future tasks take fewer turns, tool calls, rebuilds, and retries.

This file is for the EDA repository itself. Guardian-specific feedback belongs
in `../guardian-zig/FEEDBACK.md` under that repository's own rules.

## What to log

Add an entry when at least one of these is true:

- a blocker prevented completion or required user/external intervention;
- missing or misleading tooling, documentation, diagnostics, fixtures, or
  commands caused avoidable turns, tool calls, rebuilds, or investigation;
- a concrete improvement could remove repeated work from future tasks.

Do not add routine success notes, speculative wish lists, raw command output,
secrets, user data, or generic complaints. Finish the task when possible; this
log is not a substitute for reporting an active blocker to the user.

## How to add an entry

1. Append at the bottom of the Log section. Never edit, reorder, or delete an
   existing entry. If an old item is resolved, append a follow-up entry that
   names the resolving commit or issue.
2. Make the entry self-contained. A reader should understand the task, the
   failing seam or missing capability, what was tried, and the actual cost
   without access to the original agent conversation.
3. Quantify the cost when practical: extra turns, tool calls, full builds,
   retries, or minutes.
4. Make ideas actionable. Name the command, module, diagnostic, fixture, API,
   or documentation section to change and state what repeated work it would
   eliminate.
5. Use only the applicable bullets from the template. One concise entry per
   task is usually enough.

### Entry template

```markdown
## YYYY-MM-DD · <agent> · <task>
- **blocker:** <what prevented progress, evidence, attempts, and what is needed>
- **friction:** <avoidable repeated work and its measured cost>
- **idea:** <specific improvement and the turns/tool calls it should save>
- **workaround:** <best known procedure until the improvement lands>
- **status:** open | mitigated | resolved in <commit/issue>
```

---

## Log

## 2026-08-25 · codex · clickable DRC errors for blocked impedance tapers
- **blocker:** The filesystem was at 100%, and Git could not create the feature-branch ref lock. One old worktree's generated `.zig-cache` occupied 9.9 GB (another cache occupied 88 GB); clearing only the 9.9 GB generated cache restored worktree creation after three diagnostic/tool calls.
- **idea:** Add a documented cache-usage preflight or safe stale-worktree cache cleanup command to the worktree workflow so branch creation and release builds do not first fail on a full volume.
- **workaround:** Run `du -sh .claude/worktrees/*/.zig-cache | sort -hr`, identify an inactive worktree, and delete only files beneath that generated cache.
- **status:** mitigated
