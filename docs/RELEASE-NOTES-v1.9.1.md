# mcpock v1.9.1

**2026-10-10** — Two fixes for the desktop widgets.

macOS 26+, Apple Silicon.

- **Widgets use the panel's colors.** A broken server is red; slow, waiting
  for a sign-in and set up differently are amber, as in the panel and the menu
  bar icon. Before, the widgets showed every problem in red. The Status widget's
  dot, the Problems widget's dots and the Agents widget's bars all follow this.
- **Widgets always catch up.** mcpock tells the widgets about a change at most
  once a minute. A change that came in during that minute used to be dropped,
  so after an update or a fresh launch the widgets could show old results for
  up to 15 minutes. Now it is sent as soon as the minute is up.
