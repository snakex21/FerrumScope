#!/usr/bin/env python3
"""
fix_implicit_void.py — jednorazowa migracja do jawnego typu zwracanego.

Zig 0.15.2 **odrzuca** funkcje z pominiętym typem zwracanym (`fn f() {}`).
W tej wersji toolchainu trzeba `fn f() void {}`. Potwierdzone eksperymentem:
wariant z `void` parsuje się poprawnie, warianty bez `void` są odrzucane
błędem „expected return type expression, found '{'".

Skrypt jest idempotentny: funkcje, które już mają typ zwracany, są pomijane.
Działa na całym tekście pliku, szukając sygnatur `fn`/`pub fn` i wstawiając
` void` przed nawiasem otwierającym ciało.

Użycie:  python tools/fix_implicit_void.py [--check]
"""

from __future__ import annotations

import argparse
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
TARGET_DIRS = ["src", "tools"]

# Sygnatura funkcji na początku linii: opcjonalne wcięcie, `pub`, `fn`, nazwa, `(`.
FUNC_RE = re.compile(r"(?m)^[ \t]*(?:pub[ \t]+)?fn[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\(")

# Typ zwracany zaczyna się od jednego z tych znaków.
RETURN_START_RE = re.compile(r"[A-Za-z_!?*\[]")


def matching_paren(text: str, open_idx: int) -> int:
    """Indeks nawiasu zamykającego odpowiadającego `open_idx` (lub -1)."""
    depth = 0
    i = open_idx
    n = len(text)
    quote = None
    while i < n:
        ch = text[i]
        if quote is not None:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in ('"', "'"):
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def fix_text(text: str) -> tuple[str, int]:
    out: list[str] = []
    pos = 0
    count = 0
    while True:
        m = FUNC_RE.search(text, pos)
        if m is None:
            out.append(text[pos:])
            break

        open_idx = text.index("(", m.end() - 1)
        close_idx = matching_paren(text, open_idx)
        if close_idx < 0:
            out.append(text[pos : m.end()])
            pos = m.end()
            continue

        # Co stoi bezpośrednio za ')'?
        j = close_idx + 1
        while j < len(text) and text[j] in " \t\r\n":
            j += 1

        if j < len(text) and text[j] == "{":
            # Brak typu zwracanego — wstawiamy ` void` tuż po ')'.
            out.append(text[pos : close_idx + 1])
            out.append(" void")
            pos = close_idx + 1
            count += 1
            continue

        if j < len(text) and RETURN_START_RE.match(text[j]):
            # Typ zwracany już jest — przepisujemy bez zmian.
            out.append(text[pos : j])
            pos = j
            continue

        # Nieczytelna sytuacja — zostawiamy bez zmian.
        out.append(text[pos : close_idx + 1])
        pos = close_idx + 1

    return "".join(out), count


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="tylko pokaż, co zostałoby zmienione")
    args = ap.parse_args()

    total = 0
    files = 0
    for d in TARGET_DIRS:
        base = os.path.join(ROOT, d)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            # Pomijamy pobrany toolchain.
            if os.path.basename(dirpath) == "zig":
                dirnames[:] = []
                continue
            for name in sorted(filenames):
                if not name.endswith(".zig"):
                    continue
                p = os.path.join(dirpath, name)
                with open(p, encoding="utf-8") as fh:
                    text = fh.read()
                new_text, n = fix_text(text)
                if n:
                    rel = os.path.relpath(p, ROOT).replace("\\", "/")
                    print(f"{'would fix' if args.check else 'fixed'} {n:>3}  {rel}")
                    total += n
                    files += 1
                    if not args.check:
                        with open(p, "w", encoding="utf-8", newline="") as fh:
                            fh.write(new_text)
    verb = "do poprawki" if args.check else "poprawiono"
    print(f"{verb}: {total} sygnatur w {files} plikach")
    return 0


if __name__ == "__main__":
    sys.exit(main())
