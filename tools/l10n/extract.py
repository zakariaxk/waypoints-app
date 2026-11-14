#!/usr/bin/env python3
"""String Catalogs for WaypointsKit (PRD L10N-1, plan 9.10).

    tools/l10n/extract.py           regenerate Sources/<Module>/Resources/Localizable.xcstrings
    tools/l10n/extract.py --apply   also add `bundle: .module` to plain Text("…") and
                                    String(localized: "…") calls so they resolve from the module

Keys are the English copy. Interpolations become %@ placeholders. Existing entries are kept,
so translations added in Xcode survive a re-run.
"""
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "ios", "Packages", "WaypointsKit", "Sources")

# A Swift string literal that may contain simple interpolations without nested quotes.
LIT = r'"((?:[^"\\\n]|\\[^(\n]|\\\((?:[^"()\n]|\([^"()\n]*\))*\))*)"'

# Calls whose literal argument is user-facing copy (DesignSystem components take LocalizedStringKey).
COMPONENTS = ("Text|PrimaryButton|SecondaryButton|QuietButton|DestructiveButton|EmptyState|SectionLabel|"
              "Field|Chip|NavRow|Button|Label|Toggle|Link|ToastMessage|ErrorState|Sheet|Banner|Menu")
PATTERNS = [
    re.compile(r'\b(?:%s)\(\s*%s' % (COMPONENTS, LIT)),
    re.compile(r'String\(localized:\s*%s' % LIT),
    re.compile(r'LocalizedStringKey\(\s*%s' % LIT),
    re.compile(r'\b(?:label|prompt|actionTitle|confirmTitle|consequence|title|subtitle|placeholder|noneTitle):\s*%s' % LIT),
    re.compile(r'\.(?:navigationTitle|accessibilityLabel|accessibilityHint|alert|confirmationDialog)\(\s*%s' % LIT),
]
INTERP = re.compile(r'\\\((?:[^"()\n]|\([^"()\n]*\))*\)')


def key_of(literal: str) -> str | None:
    if not re.search(r'[A-Za-z]', literal) or literal.startswith(("http", "waypoints:", "mailto:")):
        return None
    if re.fullmatch(r'[a-z0-9_.]+', literal) and "." in literal:      # symbol names, keys
        return None
    k = INTERP.sub("%@", literal)
    return k.replace('\\"', '"').replace("\\n", "\n")


def keys_in(text: str) -> set[str]:
    out = set()
    for p in PATTERNS:
        for m in p.finditer(text):
            k = key_of(m.group(1))
            if k:
                out.add(k)
    return out


def apply_bundle(text: str) -> str:
    text = re.sub(r'\bText\(\s*%s\s*\)' % LIT, lambda m: 'Text("%s", bundle: .module)' % m.group(1), text)
    text = re.sub(r'String\(localized:\s*%s\s*\)' % LIT,
                  lambda m: 'String(localized: "%s", bundle: .module)' % m.group(1), text)
    return text


def main() -> None:
    apply = "--apply" in sys.argv
    for module in sorted(os.listdir(ROOT)):
        src = os.path.join(ROOT, module)
        if not os.path.isdir(src):
            continue
        keys: set[str] = set()
        for dp, _, fns in os.walk(src):
            for fn in fns:
                if not fn.endswith(".swift"):
                    continue
                path = os.path.join(dp, fn)
                text = open(path, encoding="utf-8").read()
                keys |= keys_in(text)
                if apply:
                    new = apply_bundle(text)
                    if new != text:
                        open(path, "w", encoding="utf-8").write(new)
        if not keys:
            continue
        res = os.path.join(src, "Resources")
        os.makedirs(res, exist_ok=True)
        cat_path = os.path.join(res, "Localizable.xcstrings")
        existing = {}
        if os.path.exists(cat_path):
            existing = json.load(open(cat_path, encoding="utf-8")).get("strings", {})
        strings = {k: existing.get(k, {"extractionState": "manual"}) for k in sorted(keys)}
        json.dump({"sourceLanguage": "en", "strings": strings, "version": "1.0"},
                  open(cat_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False, sort_keys=True)
        print(f"{module:20s} {len(keys)} keys")


if __name__ == "__main__":
    main()
