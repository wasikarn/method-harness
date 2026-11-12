#!/usr/bin/env python3
"""Map a short skill name to its namespaced form (GH #330).

The model may call the Skill tool with a short name (`grilling`) that Claude
Code resolves to a plugin skill (`mattpocock-skills:grilling`); the tool
input and result both keep the short name. Print the namespaced name when
exactly one installed plugin ships a skill or command with that name and no
user or project skill claims it; otherwise print the name unchanged, since
a name two plugins share (`doctor`) cannot be resolved from the call alone.

ponytail: walks every installed plugin's skill dirs per call (only for an
unnamespaced name); cache the map if the walk ever gets slow.
"""
import json
import os
import sys


def _skill_names(root, entries):
    # Same coverage rule as the loader (harness-audit check 78): the default
    # one-level skills/<name>/ scan, plus each plugin.json `skills` entry,
    # which loads itself when it holds a SKILL.md, else its direct children.
    names = set()
    dirs = [os.path.join(root, "skills")]
    for e in entries:
        p = os.path.normpath(os.path.join(root, e))
        if os.path.isfile(os.path.join(p, "SKILL.md")):
            names.add(os.path.basename(p))
        else:
            dirs.append(p)
    for d in dirs:
        try:
            for n in os.listdir(d):
                if os.path.isfile(os.path.join(d, n, "SKILL.md")):
                    names.add(n)
        except OSError:
            pass
    try:
        for n in os.listdir(os.path.join(root, "commands")):
            if n.endswith(".md"):
                names.add(n[:-3])
    except OSError:
        pass
    return names


def resolve(short, config_dir, cwd):
    for base in (config_dir, os.path.join(cwd, ".claude")):
        if os.path.isdir(os.path.join(base, "skills", short)):
            return short  # a real unnamespaced skill owns the name
    try:
        with open(os.path.join(config_dir, "plugins", "installed_plugins.json")) as f:
            plugins = json.load(f).get("plugins", {})
    except (OSError, ValueError, AttributeError):
        return short
    matches = set()
    for key, installs in (plugins.items() if isinstance(plugins, dict) else []):
        for inst in installs if isinstance(installs, list) else []:
            root = inst.get("installPath") if isinstance(inst, dict) else None
            if not isinstance(root, str):
                continue
            try:
                with open(os.path.join(root, ".claude-plugin", "plugin.json")) as f:
                    manifest = json.load(f)
            except (OSError, ValueError):
                manifest = {}
            if not isinstance(manifest, dict):
                manifest = {}
            name = manifest.get("name")
            if not isinstance(name, str) or not name:
                name = key.split("@")[0]  # no usable manifest name: the install key's
            entries = manifest.get("skills")
            if isinstance(entries, str):
                entries = [entries]
            if not isinstance(entries, list):
                entries = []
            if short in _skill_names(root, [e for e in entries if isinstance(e, str)]):
                matches.add(f"{name}:{short}")
    return matches.pop() if len(matches) == 1 else short


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(0)
    # CLAUDE_CONFIG_DIR moves ~/.claude, registry and user skills included (memory-dir.py reads it too).
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.environ.get("HOME", ""), ".claude")
    print(resolve(sys.argv[1], config_dir, os.getcwd()))
