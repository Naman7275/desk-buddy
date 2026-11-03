---
name: desk-buddy
description: Manage the user's Desk Buddy widget (desktop to-do list and leave balance). Use whenever the user mentions a task, to-do, reminder or follow-up ("add X", "remind me to", "for tomorrow", "next week", "done with X", "drop X", "move X to Friday", "what's on my list", "what did I do yesterday") or a leave ("took leave today", "leave on 12 Nov", "half day Friday", "what's my leave balance"). Edits tasks.md / leaves.md in {{INSTALL_DIR}}, which the widget shows live.
---

# Desk Buddy

The user has a desktop widget plus a plush mascot ("buddy") that show `{{INSTALL_DIR}}\tasks.md` and `{{INSTALL_DIR}}\leaves.md`. The widget re-reads the files every 1.5 s, so **editing the files is how you control the widget**. The user also ticks, adds and drops items in the widget, so the files can change under you.

## Rules
- Always Read the file right before editing. Use small Edits; never rewrite the whole file. Keep the exact format; the widget parses it.
- Dates are absolute `YYYY-MM-DD` in local time. Resolve "today", "tomorrow", "Friday", "next week" (= next Monday) yourself.
- Act straight away when the intent is clear; ask only if it's ambiguous which item is meant. Confirm in one line afterwards.
- Never put passwords, tokens or other secrets in the files. Never delete Daily log history.

## tasks.md
```
## Note from Claude
One short line shown as a blue banner at the top of the widget.

## Open (carry over until done)
- [ ] Task text (added YYYY-MM-DD)
- [ ] Task text (added YYYY-MM-DD) (due YYYY-MM-DD)

## Daily log
### YYYY-MM-DD (Weekday)
- Added: Task text
- Done: Task text
- Dropped: Task text
- Note: free text
```
- `(added …)` first, `(due …)` optional after it.
- Daily log is newest-first; today's block goes directly under the Daily log comment line. If it already exists (the widget creates it too), append to it.

| User says | Do |
|---|---|
| add / remind me / I need to X | Append `- [ ] X (added <today>)` to Open; add `- Added: X` to today's block |
| …for tomorrow / on Friday | Same, plus ` (due <date>)` |
| done / finished X | Remove the Open line; add `- Done: X` |
| drop / not needed X | Remove the Open line; add `- Dropped: X` |
| move X to <day> | Change only the `(due …)` part |
| what's left | Summarise Open: due/overdue first, then oldest |
| what did I do (day) | Summarise that Daily log block |
| focus for today | Replace the line under `## Note from Claude` |

## leaves.md (optional)
```
## Policy
- Credit: 1.5 per month from 2026-01
- Days off: Sat, Sun

## Taken
- 2026-06-15 1
- 2026-09-25 0.5
- 2026-03 2 Trip (exact days not noted)
```
- The widget adds the monthly credit itself; never write credit lines.
- One line per leave day, in date order; `0.5` = half day; future date = planned; negative = days given back.
- For a range, skip the "Days off" weekdays.
- Balance = months since the start month × credit − all entries dated today or earlier.
- "cancel my leave on X" → remove that line. "what's my balance" → compute it and answer with the balance and planned days.
