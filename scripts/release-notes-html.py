#!/usr/bin/env python3
"""Turn docs/release-notes/<version>.md into the HTML fragment Sparkle shows
in its update window.

    python3 scripts/release-notes-html.py docs/release-notes/1.10.9.md > feed/mcpock-1.10.9.html

generate_appcast embeds an .html file named like the DMG (mcpock-1.10.9.dmg ->
mcpock-1.10.9.html) into that update's appcast item. The fragment has no
DOCTYPE or body tag on purpose: that is what makes Sparkle embed it. Reads the
same small Markdown the What's new window reads: plain lines, "- " bullets,
**bold** and `code`.
"""
import html
import re
import sys


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", text)


def convert(markdown):
    out, in_list = [], False
    for raw in markdown.splitlines():
        line = raw.strip()
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>" + inline(line[2:]) + "</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if not line:
            continue
        heading = re.match(r"#+\s+(.*)", line)
        if heading:
            out.append("<h3>" + inline(heading.group(1)) + "</h3>")
        elif not line.endswith(".") and len(line) < 60:
            out.append("<h3>" + inline(line) + "</h3>")
        else:
            out.append("<p>" + inline(line) + "</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as f:
        sys.stdout.write(convert(f.read()))
