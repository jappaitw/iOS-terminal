#!/usr/bin/env python3
"""Regenerates PocketCode/Resources/Acknowledgements.json from the resolved SwiftPM checkouts.

Run after changing package versions:  python3 scripts/gen_acknowledgements.py
(Packages must be resolved into .spm/ first, e.g. by building once.)
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKOUTS = os.path.join(ROOT, ".spm", "checkouts")
OUT = os.path.join(ROOT, "PocketCode", "Resources", "Acknowledgements.json")

# Display names and project URLs for the packages that ship in the app.
PACKAGES = {
    "Citadel": ("Citadel", "https://github.com/orlandos-nl/Citadel"),
    "SwiftTerm": ("SwiftTerm", "https://github.com/migueldeicaza/SwiftTerm"),
    "Runestone": ("Runestone", "https://github.com/simonbs/Runestone"),
    "TreeSitterLanguages": ("TreeSitterLanguages", "https://github.com/simonbs/TreeSitterLanguages"),
    "tree-sitter": ("Tree-sitter", "https://github.com/tree-sitter/tree-sitter"),
    "swift-nio": ("SwiftNIO", "https://github.com/apple/swift-nio"),
    "swift-nio-ssh": ("SwiftNIO SSH", "https://github.com/apple/swift-nio-ssh"),
    "swift-crypto": ("Swift Crypto", "https://github.com/apple/swift-crypto"),
    "swift-asn1": ("Swift ASN.1", "https://github.com/apple/swift-asn1"),
    "swift-log": ("SwiftLog", "https://github.com/apple/swift-log"),
    "swift-collections": ("Swift Collections", "https://github.com/apple/swift-collections"),
    "swift-atomics": ("Swift Atomics", "https://github.com/apple/swift-atomics"),
    "swift-system": ("Swift System", "https://github.com/apple/swift-system"),
    "swift-argument-parser": ("Swift Argument Parser", "https://github.com/apple/swift-argument-parser"),
    "BigInt": ("BigInt", "https://github.com/attaswift/BigInt"),
}

# Grammars compiled into the app (see project.yml). TreeSitterLanguages vendors their
# generated parsers without per-grammar license files; all are MIT-licensed upstream.
GRAMMARS = [
    ("Bash", "https://github.com/tree-sitter/tree-sitter-bash"),
    ("C", "https://github.com/tree-sitter/tree-sitter-c"),
    ("C++", "https://github.com/tree-sitter/tree-sitter-cpp"),
    ("C#", "https://github.com/tree-sitter/tree-sitter-c-sharp"),
    ("CSS", "https://github.com/tree-sitter/tree-sitter-css"),
    ("Go", "https://github.com/tree-sitter/tree-sitter-go"),
    ("HTML", "https://github.com/tree-sitter/tree-sitter-html"),
    ("Java", "https://github.com/tree-sitter/tree-sitter-java"),
    ("JavaScript", "https://github.com/tree-sitter/tree-sitter-javascript"),
    ("JSON", "https://github.com/tree-sitter/tree-sitter-json"),
    ("Markdown", "https://github.com/MDeiml/tree-sitter-markdown"),
    ("PHP", "https://github.com/tree-sitter/tree-sitter-php"),
    ("Python", "https://github.com/tree-sitter/tree-sitter-python"),
    ("Ruby", "https://github.com/tree-sitter/tree-sitter-ruby"),
    ("Rust", "https://github.com/tree-sitter/tree-sitter-rust"),
    ("SQL", "https://github.com/DerekStride/tree-sitter-sql"),
    ("Swift", "https://github.com/alex-pinkus/tree-sitter-swift"),
    ("TOML", "https://github.com/ikatyang/tree-sitter-toml"),
    ("TypeScript / TSX", "https://github.com/tree-sitter/tree-sitter-typescript"),
    ("YAML", "https://github.com/ikatyang/tree-sitter-yaml"),
]

MIT = """Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE."""


def find(dirpath, pattern):
    for name in sorted(os.listdir(dirpath)):
        if re.match(pattern, name, re.I):
            return os.path.join(dirpath, name)
    return None


def kind(text):
    if "Apache License" in text and "Version 2.0" in text:
        return "Apache-2.0"
    if "Permission is hereby granted, free of charge" in text:
        return "MIT"
    return "See license"


def main():
    if not os.path.isdir(CHECKOUTS):
        sys.exit("No .spm/checkouts — build once so SwiftPM resolves packages.")
    entries = []
    for folder in sorted(os.listdir(CHECKOUTS), key=str.lower):
        if folder not in PACKAGES:
            print(f"warning: {folder} not in PACKAGES; add it or confirm it doesn't ship", file=sys.stderr)
            continue
        path = os.path.join(CHECKOUTS, folder)
        lic = find(path, r"^(license|licence|copying)")
        if not lic:
            sys.exit(f"{folder}: no license file found")
        text = open(lic, encoding="utf-8").read().strip()
        notice = find(path, r"^notice")
        if notice:
            text += "\n\n———— NOTICE ————\n\n" + open(notice, encoding="utf-8").read().strip()
        name, url = PACKAGES[folder]
        entries.append({"name": name, "url": url, "license": kind(text), "text": text})
    grammar_list = "\n".join(f"• {n} — {u}" for n, u in GRAMMARS)
    entries.append({
        "name": "Tree-sitter grammars",
        "url": "https://tree-sitter.github.io",
        "license": "MIT",
        "text": "Syntax highlighting uses these tree-sitter grammars, each MIT-licensed by its respective authors:\n\n"
                + grammar_list + "\n\nCopyright (c) the respective grammar authors.\n\n" + MIT,
    })
    entries.sort(key=lambda e: e["name"].lower())
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=1)
    print(f"wrote {len(entries)} entries to {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
