#!/usr/bin/env python3
"""Map a short skill name to its namespaced form (GH #330).

The model may call the Skill tool with a short name (`grilling`) that Claude
Code resolves to a plugin skill (`mattpocock-skills:grilling`); the tool
input and result both keep the short name. Print the namespaced name when
exactly one installed and enabled plugin ships a skill or command with that
name and no user or project skill claims it; otherwise print the name
unchanged, since a name two plugins share (`doctor`) cannot be resolved from
the call alone. A plugin counts as enabled by the `enabledPlugins` entries of
the user, project and local settings files (managed settings and `--settings`
are not read), else by its manifest's `defaultEnabled`. An install record's
scope is not read: a plugin installed for another project still counts.

With `--known`, a name that no user skill, project skill or enabled plugin
carries prints nothing and exits 3 (a typed `/init` is not a skill).

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


def _enabled_map(config_dir, project):
    # enabledPlugins is {"<name>@<marketplace>": true|false}, read from the user, project and local
    # settings files; a later file wins for the plugins it names. Managed settings and --settings
    # are not read here. An unreadable file counts as naming nothing.
    merged = {}
    for path in (os.path.join(config_dir, "settings.json"),
                 os.path.join(project, ".claude", "settings.json"),
                 os.path.join(project, ".claude", "settings.local.json")):
        try:
            with open(path) as f:
                entries = json.load(f).get("enabledPlugins")
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(entries, dict):
            merged.update({k: v for k, v in entries.items() if isinstance(v, bool)})
    return merged


def lookup(short, config_dir, project):
    """(name to log, whether a skill of that name was found at all)."""
    for base in (config_dir, os.path.join(project, ".claude")):
        if os.path.isdir(os.path.join(base, "skills", short)):
            return short, True  # a real unnamespaced skill owns the name
    try:
        with open(os.path.join(config_dir, "plugins", "installed_plugins.json")) as f:
            plugins = json.load(f).get("plugins", {})
    except (OSError, ValueError, AttributeError):
        return short, False
    enabled = _enabled_map(config_dir, project)
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
            # An installed plugin that is not enabled ships nothing a session can call. With no
            # enabledPlugins entry the manifest's defaultEnabled decides (true when absent).
            if not enabled.get(key, manifest.get("defaultEnabled") is not False):
                continue
            name = manifest.get("name")
            if not isinstance(name, str) or not name:
                name = key.split("@")[0]  # no usable manifest name: fall back to the install key's plugin name
            entries = manifest.get("skills")
            if isinstance(entries, str):
                entries = [entries]
            if not isinstance(entries, list):
                entries = []
            if short in _skill_names(root, [e for e in entries if isinstance(e, str)]):
                matches.add(f"{name}:{short}")
    found = bool(matches)
    return (matches.pop() if len(matches) == 1 else short), found


if __name__ == "__main__":
    # skill-namespace.py [--known] <name>. With --known, a name no skill carries prints nothing and
    # exits 3: a typed slash command that is not a skill (/init, a custom command) is not a skill row.
    args = sys.argv[1:]
    known_only = args[:1] == ["--known"]
    if known_only:
        args = args[1:]
    if len(args) != 1:
        sys.exit(0)
    # CLAUDE_CONFIG_DIR moves ~/.claude, registry and user skills included (memory-dir.py reads it too).
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.environ.get("HOME", ""), ".claude")
    # The hook's cwd can be a subdirectory; CLAUDE_PROJECT_DIR is the project root when a hook runs.
    project = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    name, found = lookup(args[0], config_dir, project)
    if known_only and not found:
        sys.exit(3)
    print(name)
