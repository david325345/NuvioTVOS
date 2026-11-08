#!/usr/bin/env python3
"""Leaves no symlinks in the staged AIOStreams package.

Apple TV does not let apps create symlinks (EPERM), so the package must not
have any. pnpm's hoisted layout (node-linker=hoisted) already puts real
folders in node_modules; what is left are links to AIOStreams' own workspace
packages (packages/core, packages/crypto) and to command-line tools (.bin):

- a link to a workspace package becomes a small forwarding package that loads
  the real one where it is, so AIOStreams still finds its resources relative
  to packages/core and each package is loaded once,
- .bin links are dropped (nothing runs commands on Apple TV),
- any other link is replaced by a copy of what it points to.

Usage: no-symlinks.py <stage dir>
"""
import json
import os
import shutil
import sys

stage = os.path.realpath(sys.argv[1])
packages = os.path.join(stage, "packages")


def symlinks():
    found = []
    for directory, dirnames, filenames in os.walk(stage):
        for name in dirnames + filenames:
            candidate = os.path.join(directory, name)
            if os.path.islink(candidate):
                found.append(candidate)
    return found


def forward(link, target):
    manifest = json.load(open(os.path.join(target, "package.json")))
    main = os.path.join(target, manifest.get("main") or "index.js")
    if os.path.isdir(main):
        main = os.path.join(main, "index.js")
    os.unlink(link)
    os.makedirs(link)
    entry = os.path.relpath(main, link)
    if not entry.startswith("."):
        entry = "./" + entry
    is_module = manifest.get("type") == "module"
    stub = {"name": manifest["name"], "version": manifest.get("version", "0.0.0"), "main": "index.js"}
    if is_module:
        stub["type"] = "module"
    with open(os.path.join(link, "package.json"), "w") as file:
        json.dump(stub, file, indent=2)
    with open(os.path.join(link, "index.js"), "w") as file:
        if is_module:
            file.write(f"export * from {json.dumps(entry)};\n")
        else:
            file.write(f"module.exports = require({json.dumps(entry)});\n")
    return os.path.relpath(main, stage)


forwarded = copied = dropped = 0
# Deepest first: a folder is complete before a link to it is copied.
for link in sorted(symlinks(), key=lambda item: -item.count(os.sep)):
    name = os.path.relpath(link, stage)
    target = os.path.realpath(link)
    if ".bin" in name.split(os.sep):
        os.unlink(link)
        dropped += 1
        continue
    if not os.path.exists(target):
        print(f"note: broken link dropped: {name}")
        os.unlink(link)
        dropped += 1
        continue
    if target != stage and not target.startswith(stage + os.sep):
        sys.exit(f"link outside the package: {name} -> {target}")
    if os.path.dirname(target) == packages and os.path.isfile(os.path.join(target, "package.json")):
        print(f"forward: {name} -> {forward(link, target)}")
        forwarded += 1
        continue
    os.unlink(link)
    if os.path.isdir(target):
        shutil.copytree(target, link, symlinks=False)
    else:
        shutil.copy2(target, link)
    print(f"copy: {name} -> {os.path.relpath(target, stage)}")
    copied += 1

left = symlinks()
if left:
    print("symlinks left:")
    for link in left[:20]:
        print("  " + os.path.relpath(link, stage))
    sys.exit(1)
print(f"symlinks: none left ({forwarded} forwarding packages, {copied} copies, {dropped} dropped)")
