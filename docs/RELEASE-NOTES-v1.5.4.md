# MCPBAR v1.5.4

**2026-09-25** — The Agents tab comes first, fills the space, and its health
bars grow in. Plus a fix for a row that could keep an old look.

macOS 26+, Apple Silicon.

---

## Changed: the panel opens on the Agents tab

A fresh launch now shows **Agents** first: one row per agent, each with its
health bar. The tab you pick still lasts until MCPBAR quits.

## New: the health bars grow in

Each agent's health bar grows in from the left, in half a second, with no
bounce:

- the first time you look at the Agents tab after MCPBAR starts (once the
  first check has results), and
- after every full check: the footer's Refresh, or the regular timed check.

**Check again** on one server does not replay it. With **Reduce Motion** on
(System Settings > Accessibility > Display), the bars just appear.

## Changed: the problems toggle no longer empties the Agents tab

With the footer's problems toggle on, the agents that need you are listed
first, as before. The agents with nothing wrong now stay too, below a thin
line and faded, so the tab never looks half empty. You can still open them;
an opened one is shown at full strength. A search that matches a fine agent
shows it, faded.

## Fixed: a row could keep its old look after moving

A server that moved from "Everything else" into "Needs you" while the panel
was open (or back, after **Mark as intended**) could keep its old mark and no
note until you switched tabs. Each row is now rebuilt when it changes
section.

Everything else is v1.5.3 (see `docs/RELEASE-NOTES-v1.5.3.md`).
