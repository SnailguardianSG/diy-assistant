"""Find Claude's login link in a terminal recording and print it as one line.

    python3 login-link.py <recording made with `script`>

On a phone the login link wraps over many lines, and copying it from the
terminal breaks it (found in the rehearsal: line breaks became "+" or stayed
in). The installer records the login screen, finds the link with this, and the
bot sends it to the owner's Telegram group as one tappable link.

Handles colour/cursor codes, wrapped lines, and box borders drawn around the
text. Prints nothing until a complete link (with client_id and state) is there.
"""
import re
import sys

ESC = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78]")
URL_CHAR = re.compile(r"[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]")
FILLER = " \t│┃|"          # spaces and box borders that can surround a wrapped line


def find(text: str) -> str | None:
    for m in re.finditer(r"https://claude\.(?:ai|com)/", text):
        i, out = m.start(), []
        while i < len(text):
            c = text[i]
            if c in "\r\n" or c in FILLER:
                # Wrapped? Skip filler, line breaks and the next line's filler - but
                # only if a line break is among them; a plain space ends the link.
                j, broke = i, False
                while j < len(text) and (text[j] in FILLER or text[j] in "\r\n"):
                    broke |= text[j] in "\r\n"
                    j += 1
                if not broke:
                    break
                i = j
                continue
            if not URL_CHAR.match(c):
                break
            out.append(c)
            i += 1
        url = "".join(out)
        state = re.search(r"[?&]state=([A-Za-z0-9_-]{43})", url)
        if "client_id=" in url and state:
            return url[: state.end()]
    return None


if __name__ == "__main__":
    raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
    link = find(ESC.sub("", raw))
    if link:
        print(link)
