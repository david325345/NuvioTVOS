#!/usr/bin/env python3
"""Writes the AIOStreams package's node_modules without symlinks.

Apple TV does not let apps create symlinks (EPERM), but pnpm's install is
made of them: each package lives in node_modules/.pnpm/<id>/node_modules/<name>
and finds its dependencies through sibling symlinks. pnpm's own flat layout
(node-linker=hoisted) ignores --filter and would bring the web frontend's
dependencies too, so this takes pnpm's normal install of the server and lays
it out the way npm does, with real folders:

- each package once in <stage>/node_modules, a different version of one
  nested under the package that needs it (resolved exactly as Node.js walks
  node_modules folders, so every package gets the version pnpm gave it),
- AIOStreams' own workspace packages (core, crypto) stay in packages/ and
  are reached through small forwarding packages, so they load once and
  still find their resources relative to packages/,
- whatever pnpm hoisted for packages with undeclared dependencies
  (node_modules/.pnpm/node_modules) is available at the root as well.

Usage: flatten.py <source tree after pnpm install> <stage dir>
"""
import json
import os
import shutil
import sys
from collections import deque

source = os.path.realpath(sys.argv[1])
stage = os.path.realpath(sys.argv[2])
store = os.path.join(source, "node_modules", ".pnpm")

# Workspace packages that are in the stage: real source dir -> stage dir.
workspace = {}
for name in sorted(os.listdir(os.path.join(source, "packages"))):
    staged = os.path.join(stage, "packages", name)
    if os.path.isfile(os.path.join(staged, "package.json")):
        workspace[os.path.realpath(os.path.join(source, "packages", name))] = staged


def entries(folder):
    """(name, real path) for each package entry of a node_modules folder."""
    found = []
    if not os.path.isdir(folder):
        return found
    for name in sorted(os.listdir(folder)):
        if name.startswith("."):
            continue
        path = os.path.join(folder, name)
        if name.startswith("@") and os.path.isdir(path) and not os.path.islink(path):
            for inner in sorted(os.listdir(path)):
                found.append((f"{name}/{inner}", os.path.realpath(os.path.join(path, inner))))
        else:
            found.append((name, os.path.realpath(path)))
    return [(name, real) for name, real in found if os.path.exists(real)]


def dependencies(real):
    """What a package resolves by name: for a workspace package its own
    node_modules, for a package in pnpm's store its sibling links."""
    if real in workspace or real == source:
        return entries(os.path.join(real, "node_modules"))
    container = os.path.dirname(real)
    if os.path.basename(container).startswith("@"):
        container = os.path.dirname(container)
    own = os.path.relpath(real, container)
    return [(name, target) for name, target in entries(container) if name != own]


placements = {}  # stage path of a node_modules entry -> real source dir (or ("forward", workspace dir))
queue = deque()


def lookup(location, name):
    """What Node.js would find for `name` from a package at `location`."""
    folder = location
    while True:
        if os.path.basename(folder) != "node_modules":
            candidate = os.path.join(folder, "node_modules", name)
            if candidate in placements:
                return placements[candidate]
        if folder == stage:
            return None
        folder = os.path.dirname(folder)


def place(location, real):
    for name, target in dependencies(real):
        wanted = ("forward", target) if target in workspace else target
        found = lookup(location, name)
        if found == wanted:
            continue
        root = os.path.join(stage, "node_modules", name)
        spot = root if found is None else os.path.join(location, "node_modules", name)
        if spot in placements:
            # Only for the workspace root's own dependencies: the server's version stays.
            print(f"note: {os.path.relpath(spot, stage)} kept, {name} wanted from {os.path.relpath(location, stage)} differs")
            continue
        placements[spot] = wanted
        if wanted == target:
            queue.append((spot, target))


def run():
    while queue:
        place(*queue.popleft())


# The server first (its versions win the root), then the other workspace
# packages, then the workspace root's own dependencies.
order = sorted(workspace, key=lambda real: (os.path.basename(real) != "server", real))
for real in order:
    queue.append((workspace[real], real))
run()
queue.append((stage, source))
run()
# pnpm's hidden hoisting: names nothing placed at the root yet.
for name, target in entries(os.path.join(store, "node_modules")):
    root = os.path.join(stage, "node_modules", name)
    if root not in placements and target not in workspace:
        placements[root] = target
        queue.append((root, target))
run()


def forward(spot, staged):
    manifest = json.load(open(os.path.join(staged, "package.json")))
    main = os.path.join(staged, manifest.get("main") or "index.js")
    if os.path.isdir(main):
        main = os.path.join(main, "index.js")
    os.makedirs(spot, exist_ok=True)
    entry = os.path.relpath(main, spot)
    if not entry.startswith("."):
        entry = "./" + entry
    is_module = manifest.get("type") == "module"
    stub = {"name": manifest["name"], "version": manifest.get("version", "0.0.0"), "main": "index.js"}
    if is_module:
        stub["type"] = "module"
    with open(os.path.join(spot, "package.json"), "w") as file:
        json.dump(stub, file, indent=2)
    with open(os.path.join(spot, "index.js"), "w") as file:
        file.write(f"export * from {json.dumps(entry)};\n" if is_module else f"module.exports = require({json.dumps(entry)});\n")


copies = forwards = 0
for spot in sorted(placements, key=lambda path: (path.count(os.sep), path)):
    what = placements[spot]
    if isinstance(what, tuple):
        forward(spot, workspace[what[1]])
        forwards += 1
    else:
        shutil.copytree(what, spot, symlinks=False, dirs_exist_ok=True, ignore_dangling_symlinks=True,
                        ignore=shutil.ignore_patterns(".bin"))
        copies += 1

top = os.path.join(stage, "node_modules")
nested = sum(1 for spot in placements if not (os.path.dirname(spot) == top
             or os.path.dirname(os.path.dirname(spot)) == top and os.path.basename(os.path.dirname(spot)).startswith("@")))
print(f"flatten: {copies} packages ({nested} nested for other versions), {forwards} forwarding packages")
