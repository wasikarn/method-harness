# Memory vault redesign: verdict, swap mechanism, probes (2026-11-08)

**Status: NO-GO on moving the stores now; proposal ready to attack.** Not a GO. Follows `memory-vault-attack-proposal-2026-11-08.md` (its Correction note), `memory-vault-relocation-research-2026-11-08.md` and `agent-memory-proposals-audit-2026-11-08.md`. Design and probes only: no store was moved, no setting changed. Every probe ran in a scratch directory under `/tmp` with a throwaway fake home; the real stores were only listed and read.

## Verdict first: is the migration worth doing at all?

**Criterion (stated before the numbers).** Move the stores into a vault only if at least one of these is measured true:

- G1, load pressure: a store sits at 80% or more of the `MEMORY.md` load cap (lint `NEAR-BUDGET`) and `memory-lint.py --auto-archive --dry-run` cannot bring it under 80%.
- G2, a benefit that needs the real path: a benefit the operator names (one search root, an Obsidian graph, one backup folder) fails through the no-move route, shown by a probe. The no-move route is a qmd collection per store at its real path, or a vault whose folders are links to the stores.
- G3, loss: a recorded memory-loss incident that a vault would have prevented.

**Measured (2026-11-08, read-only, `memory-lint.py`'s own `collect_state` and `compute_depths` run over every store):**

| Measure | Value |
|---|---|
| Stores with a `MEMORY.md` | 22 (3 are 1-line test stores from memory-lint runs) |
| Topic files (lint count: top-level `.md`, not `MEMORY.md`) | 1,383; all `.md` including `_archive/`: 1,498 files, 4,987,076 B |
| Largest index share of the load cap | amplitube-presets 70% (18,072 B, 90 lines); method-harness 59% (15,220 B, 110 lines); dotfiles 52% |
| Stores at or above 80% | 0 |
| Topics with no link path from `MEMORY.md` | 0 in every store (the 14 found earlier are now linked) |
| Topics deeper than 2 hops | 246: method-harness 200 (deepest 7), tathep 32 (4), amplitube-presets 9 (4), dotfiles 5 (3), all others 0 |
| Lint findings | 20, all in 6 stores of 27 files or fewer; method-harness, dotfiles, tathep and amplitube-presets are clean |
| qmd | 2 of 22 stores indexed (`mh-memory`, `dotfiles-memory`), each at its real path |
| Backup | `tmutil destinationinfo`: "No destinations configured"; 2 of 22 stores are git repos with no remote (the remote was removed by operator choice) |
| Stores and `$HOME` on one volume | yes: every store, `$HOME` and `/private/tmp` report `st_dev` 16777230, APFS Data volume |

**Verdict: NO-GO on the move now.** G1 fails (highest 70%, none at 80%). G2 is not shown: the stores qmd indexes today it indexes at their real paths, and adding the other 20 is a `qmd collection add` per store with no move; a vault would add nothing a backup needs, because there is no backup destination either way. G3: no incident recorded. The one real structural fact, 246 topics deeper than 2 hops, is 81% one store and needs links, not a move. Revisit when G1, G2 or G3 turns true.

The rest of this document is the mechanism that would be built if the criterion flips, written so it can be attacked now, plus two checks (the depth ratchet and the `.vault-id` warning) specified so they can be tested. The depth ratchet can ship on its own; the `.vault-id` check needs a vault.

## The problem

Claude Code keeps auto-memory per project in `$HOME/.claude/projects/<enc>/memory/`. The operator wants one vault (`$HOME/Memory/`, one folder per project, separate from `~/llm-wiki`). The earlier design copied each store into the vault and swapped a symlink in; it never closed because the copy phase races live sessions: `rsync -a --update` drops a write made in the same second as the vault copy, the pointer-line union of two `MEMORY.md` files loses headings and edited lines, and the "is a session running" check never matched (Claude Code shows as `2.1.319` in `lsof`, not `claude`). The Correction note proposed renaming the directory into the vault, then installing the link with a temp link plus `os.rename`. Probe A below shows that two-step version fails too.

## The change

No copy phase. The store's directory inode moves into the vault in one atomic system call, which also puts the link in its place. Per project, a script does:

1. Refuse unless every precondition holds:
   - `memory` is a real directory (`lstat`, not a symlink). Probe E1: a symlinked `memory` would leave the vault folder as a link, not a directory.
   - The vault folder `V = $HOME/Memory/<slug>` does not exist (`lexists` is false) and its parent does. Probe E2: an existing `V` makes step 3 fail with `EEXIST`, which is the right refusal.
   - `st_dev` of `memory`'s parent equals `st_dev` of `V`'s parent. `RENAME_SWAP` cannot cross volumes.
   - `autoMemoryDirectory` is unset in every file the resolver reads (`./.claude/settings.local.json`, `./.claude/settings.json`, `$HOME/.claude/settings.json`) and in `$HOME/.claude/settings.local.json`; `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_PROJECT_DIR_NAME` are unset.
2. Write `.vault-id` (the resolver's `--enc` value) into `memory/`. It travels with the inode.
3. Create a symlink at `V` whose target is `V` itself (`os.symlink(V, V)`). It loops until step 4, and nothing uses `V` yet. `EEXIST` means something created `V` since step 1: abort.
4. `renamex_np(V, memory, RENAME_SWAP)`: one call swaps the two directory entries. The directory is now at `V`, and `memory` is a link whose target is `V`. On any error, unlink the self-loop at `V` and abort; nothing moved.
5. Verify: `memory` is a link to `V`, `V` is a real directory, `V/.vault-id` equals the ENC, `git -C memory status` exits 0 when the store has `.git`.
6. Watchers: restart the fswatch agent on `V` and repoint the qmd collection (probe E5: a watcher on the old path goes blind). This touches a launchd job, so the operator runs it.

Rollback, one project: `renamex_np(V, memory, RENAME_SWAP)` again (the directory returns to `memory`, `V` becomes the self-loop link), then `unlink(V)`. Probe E6 ran this.

This removes B1(a), B1(b) and B1(c) instead of patching them: no copy, so no rsync or `MEMORY.md` union; no window where `memory` is missing, so no process check is needed. Probe B ran 200 swaps against a live reader, a create-parent-then-write writer and an open append handle: 0 errors.

Not changed from revision 3: B2 is accepted (another config dir is another store by design); B4 (the `user-memory-redirect.py` vault-path scope) is still needed and is a dotfiles hook change the operator decides; flat vault folders (B7).

## Must stop

- A write landing outside the vault after the swap. Example: a Claude Code Write that creates missing parent directories runs while `memory` does not exist, recreates a real `memory/`, and its file stays there (probe A: 145 of 200 runs left such a stray directory and 59,895 probe writes outside the vault).
- The vault folder ending up a link instead of a directory. Example: `memory` was already a symlink (a half-done earlier run) and the swap moves the link into `V` (probe E1).
- Overwriting or merging into an existing vault folder. Example: `$HOME/Memory/<slug>` already holds an Obsidian note; the script must stop at step 3 (`EEXIST`, probe E2), never merge.
- Running across volumes or on a filesystem without `RENAME_SWAP`. Example: `$HOME/Memory` on an external disk, where `renamex_np` returns `EXDEV`; the script must stop at step 1, not fall back to a copy.
- A silently empty store after the vault folder goes missing. Example: `$HOME/Memory/<slug>` is deleted; Claude Code recreates it empty with no error (dangling-link probe, earlier document); the `.vault-id` check below must warn.
- A file indexer that keeps watching the old path. Example: fswatch started on `.../memory` reports nothing for a file written after the swap (probe E5), so qmd goes stale.
- A `type: user` memory written through the vault path that the redirect hook does not match (B4).

## Must allow

- A live session in the project keeps reading `MEMORY.md` and writing new topic files through `memory/` during and after the swap. Example: probe B's reader and writer saw no error in 200 swaps, and every write ended in `V`.
- A process with an open file in the store keeps writing to the same file. Example: probe B's append handle wrote every line into `V/log.md` (0 mismatches in 200 runs); probe E4's child with its cwd inside `memory/` wrote into `V` after the swap.
- The store's git history and the auto-commit hook keep working through the link. Example: probe E3, `git -C memory log` shows the earlier commit and `status` is clean after the swap.
- One-call rollback of one project. Example: probe E6.
- A project that has not been moved keeps working unchanged, and the hooks keep resolving `memory` by its usual path (the resolver never needs the vault path).

## Known facts

Verified:
- Two-step move (rename the directory into the vault, then rename a prepared link onto `memory`) loses writes when a writer creates missing parents: 145 of 200 runs raised `IsADirectoryError` (EISDIR) with a stray real `memory/`; with a 10 ms pause between the steps, 3 of 3. Source: probe A, this document.
- Self-loop link plus one `renamex_np(..., RENAME_SWAP)`: 200 of 200 runs with 0 reader errors, 0 writer errors, 0 writes outside the vault, 0 append mismatches. Source: probe B, this document (APFS, macOS 27.2).
- `RENAME_SWAP` swaps a directory with a non-directory atomically on filesystems that report `VOL_CAP_INT_RENAME_SWAP`; with `RENAME_SWAP`, `ENOENT` if the target does not exist. Source: `man 2 rename`, macOS 27.2.
- Edge cases E1-E6 as listed under Probes. Source: probe E, this document.
- Store numbers in the verdict table. Source: read-only run of `memory-lint.py`'s `collect_state`, `detector_findings` and `compute_depths` over each store, this session; `qmd status`; `tmutil`.
- A symlinked `memory/` is read through by Claude Code, and a dangling one is recreated as an empty directory with no error. Source: probes LYNX-5521 and the dangling-link probe, `memory-vault-attack-proposal-2026-11-08.md`.

Unverified:
- Claude Code itself during the swap. The probe reader and writer only stand in for it; no live session ran against a swap (a live probe would create a `$HOME/.claude/projects` entry, which this task forbids).
- Whether Claude Code's Write tool prompts for permission on a memory write once the path resolves outside `$HOME/.claude/projects` (it may compare resolved paths).
- qmd and Obsidian through a link. The fake-home qmd run was blocked by the session's guard and was not routed around. In the NO-GO case this does not matter: collections stay on the real paths.
- A memory-store git commit in flight during the swap (E3 shows git works after the swap, not during).
- What `auto-dream` background consolidation does to a linked store, and whether a Claude Code update replaces a symlinked `memory/`.
- Whether Claude Code creates the missing vault folder before or after SessionStart hooks run. The `.vault-id` check below gives the right answer either way.

## Checks specified for testing

### Depth ratchet (can ship now, independent of the vault)

- Measure: `N` = number of topics whose `compute_depths` value is greater than `MAX_HOPS` (2). Unreachable topics are not counted (they are already `UNINDEXED`).
- Baseline file: `$HOME/.claude/state/memory-lint-depth-baseline-<key>`, one integer. `<key>` is the resolver's `--enc` when lint resolves the directory itself, else the slug of the directory path as given (not its realpath, so a later link keeps the same key). Same folder as the nudge's lint cache.
- Rules: no baseline file: write `N`, no finding. `N` greater than baseline: one finding, `TOO DEEP: N topics are more than 2 hops from MEMORY.md (baseline B); deepest: a.md 7, b.md 6, ...` (5 deepest). `N` lower than baseline: rewrite the baseline to `N` (it only tightens), no finding. Equal: nothing.
- To accept a legitimate increase, the operator deletes the baseline file.
- Output: the summary line gains `deep>2: N (baseline B)`; nothing else, so the nudge (which prints only when findings are 1 or more) stays silent. This is why it no longer has to wait for a relink, which Revision 3 asked.
- Tests (temp `HOME`): fixture with 3 deep topics and no baseline: exit 0, baseline file reads 3. Add one deep topic: exit 1, one `TOO DEEP` line naming it. Remove two: exit 0, baseline reads 2. A store with an unreachable topic: counted as `UNINDEXED` only, not in `N`.
- Seed values it would write today: method-harness 200, tathep 32, amplitube-presets 9, dotfiles 5, others 0.

### `.vault-id` check (needs a vault; build with the move)

- Content: one line, the resolver's `--enc` value, written by the move script at step 2.
- Place: `hooks/session/memory-health-nudge.sh`, after `MEMDIR` is resolved and before the `[ -d "$MEMDIR" ] || exit 0` line and the clean-cache exit, because `-d` is false on a dangling link and the cache would hide the warning.
- Runs only when `[ -L "$MEMDIR" ]` and `MEMDIR` ends in `/projects/$ENC/memory` (so a configured `autoMemoryDirectory` is not checked).
- Warn loudly (one line naming the link target, the expected ENC and what was found), then continue, when: the link target does not exist; the target has no `.vault-id`; `.vault-id` differs from `$ENC`. Never cached, so it repeats every session until fixed.
- Tests (temp `HOME`, symlinked fixture): dangling link: warns; target with no `.vault-id`: warns; wrong ENC: warns; correct ENC: silent. A real directory with no `.vault-id`: silent (not a vault store).

## What a fresh attacker should target first

1. The criterion and the measurements: a measured need missed (G1-G3), or a benefit that truly needs the real path in one folder.
2. Steps 1-3 preconditions: whether a script that checks `lstat`, `lexists` and `st_dev` can still be raced between check and act (a writer creating `V` as a real directory before step 3 should give `EEXIST`; check every other ordering).
3. Claude Code itself during the swap, not a stand-in: its Write tool's permission check on a path that now resolves into `$HOME/Memory`, and any cached realpath.
4. A git commit or `index.lock` held by `memory-audit-commit.sh` while the swap runs.
5. Non-APFS or cross-volume setups, and whether the script stops before any change.
6. Rollback: the self-loop link left at `V` after the swap back, and what Obsidian or qmd do if they hit it.
7. The depth ratchet: a way to add deep topics without raising `N` (for example, slug links that `compute_depths` resolves differently from Claude Code), and the baseline key changing under a link or `autoMemoryDirectory`.
8. The `.vault-id` check: a dangling link the hook never reaches (an earlier exit), or a target that holds a copied `.vault-id`.

## Probes

All in `<scratch>` (a `mktemp -d /tmp/memvault-probe.XXXXXX` directory) with a fake home `<scratch>/<run>/home`; `<home>` below is that fake home. APFS, macOS 27.2, `st_dev` of `/tmp` equal to `$HOME`'s.

| Probe | Command | Result |
|---|---|---|
| A, gap 10 ms | `python3 -I swap_probe.py <scratch>/t1 A 3 0.01` | `err: EISDIR 3, not_linked 3, stray 3, writes_outside_vault 1439, append_mismatch 0` |
| B, gap 10 ms | `python3 -I swap_probe.py <scratch>/t1 B 3 0.01` | `err: {}, not_linked 0, stray 0, reader {}, writer {}, writes_outside_vault 0, append_mismatch 0` |
| A, no gap | `python3 -I swap_probe.py <scratch>/t2 A 200` | `err: EISDIR 145, not_linked 145, stray 145, reader ENOENT 933926, writer ENOENT 6, writes_outside_vault 59895, append_mismatch 0` |
| B, no gap | `python3 -I swap_probe.py <scratch>/t2 B 200` | `err: {}, not_linked 0, stray 0, reader {}, writer {}, writes_outside_vault 0, append_mismatch 0` |
| E1-E6 | `python3 -I edge_probe.py <scratch>/edge` | below |

Probe A's reader counts include reads after the stray directory appeared (it holds no `MEMORY.md`). In probe B the 10 ms pause sits between creating the self-loop and the swap, and changes nothing a reader sees.

Edge probe output (paths shortened to `<home>`):

```
E1 memory/ is already a symlink (to elsewhere) at swap time
  swap: ok
  after: .claude/projects/-enc/memory = link-><home>/Memory/proj
  after: Memory/proj = link-><home>/elsewhere
  memory/MEMORY.md readable: True | vault is a real dir: False
E2 vault folder already exists (non-empty dir) -> self-loop link cannot be made
  symlink: FileExistsError 17
E3 git store inside memory/ survives the swap
  swap: ok
  git log via link: c1 | status lines: 0
E4 process whose cwd is inside memory/ during the swap
  swap: ok
  child pwd -P after swap: Memory/proj | file landed in vault: True
E5 fswatch started on the memory/ path before the swap, write after
  swap: ok
  events: ['.claude/projects/-enc/memory/before.md', '.claude/projects/-enc/memory', '.claude/projects/-enc/memory']
E6 rollback: swap back (link at memory/, dir at vault)
  forward swap: ok
  back swap: ok
  after back: .claude/projects/-enc/memory = dir
  after back: Memory/proj = link-><home>/Memory/proj
  after unlink of self-loop: Memory/proj = missing
  memory/MEMORY.md readable: True
```

E5 reads: the watcher saw `before.md` and the swap itself, never `after.md`.

## Reproduce

`swap_probe.py`:

```python
#!/usr/bin/env python3
"""Probe: move a live memory/ dir into a vault and leave a symlink, on APFS.

Usage: swap_probe.py <scratch-root> <method> <iterations> [gap_sleep_s]
  method A: os.rename(memory, V); os.rename(tmp_link, memory)          (two steps)
  method B: symlink at V pointing at V itself, then renamex_np(V, memory, RENAME_SWAP)
Concurrent processes per iteration:
  reader  : open+read memory/MEMORY.md in a tight loop, counts outcomes by errno
  mkwriter: os.makedirs(memory, exist_ok=True) then write memory/w-<pid>-<n>.md (Claude Code's
            Write tool creates missing parents; the dangling-link probe showed CC recreating a dir)
  appender: one fd opened before the swap, appends a numbered line every loop until stopped
Everything lives under <scratch-root>/home (a throwaway fake HOME).
"""
import ctypes, errno, multiprocessing as mp, os, sys, time

libc = ctypes.CDLL("libc.dylib", use_errno=True)
RENAME_SWAP = 0x2


def renamex_swap(a, b):
    if libc.renamex_np(a.encode(), b.encode(), RENAME_SWAP) != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e), a)


def reader(mem, stop, q):
    c = {}
    while not stop.is_set():
        try:
            with open(os.path.join(mem, "MEMORY.md")) as f:
                k = "ok" if f.read().startswith("# Memory") else "badcontent"
        except OSError as e:
            k = errno.errorcode.get(e.errno, str(e.errno))
        c[k] = c.get(k, 0) + 1
    q.put(("reader", c))


def mkwriter(mem, stop, q):
    c, names, n = {}, [], 0
    while not stop.is_set():
        n += 1
        name = f"w-{os.getpid()}-{n}.md"
        try:
            os.makedirs(mem, exist_ok=True)
            with open(os.path.join(mem, name), "w") as f:
                f.write("x\n")
            names.append(name)
            k = "ok"
        except OSError as e:
            k = errno.errorcode.get(e.errno, str(e.errno))
        c[k] = c.get(k, 0) + 1
    q.put(("mkwriter", c, names))


def appender(mem, stop, q, ready):
    f = open(os.path.join(mem, "log.md"), "a", buffering=1)
    ready.set()
    n = 0
    while not stop.is_set():
        n += 1
        f.write(f"{n}\n")
    f.close()
    q.put(("appender", n))


def setup(root):
    home = os.path.join(root, "home")
    mem = os.path.join(home, ".claude/projects/-enc/memory")
    vault = os.path.join(home, "Memory/proj")
    os.makedirs(mem)
    os.makedirs(os.path.dirname(vault))
    with open(os.path.join(mem, "MEMORY.md"), "w") as f:
        f.write("# Memory\n- [a](a.md)\n")
    for i in range(50):
        with open(os.path.join(mem, f"t{i}.md"), "w") as f:
            f.write("t\n")
    return mem, vault


def swap(method, mem, vault, gap):
    if method == "A":
        tmp = mem + ".tmplink"
        os.symlink(vault, tmp)
        os.rename(mem, vault)
        if gap:
            time.sleep(gap)
        os.rename(tmp, mem)  # raises IsADirectoryError if a real dir reappeared in the gap
    else:
        os.symlink(vault, vault)       # self-loop link, unused until the swap
        if gap:
            time.sleep(gap)            # no effect on readers: memory/ is untouched until the swap
        renamex_swap(vault, mem)       # one syscall: dir -> vault path, link -> memory path


def one(root, method, gap):
    mem, vault = setup(root)
    stop, ready, q = mp.Event(), mp.Event(), mp.Queue()
    ps = [mp.Process(target=reader, args=(mem, stop, q)),
          mp.Process(target=mkwriter, args=(mem, stop, q)),
          mp.Process(target=appender, args=(mem, stop, q, ready))]
    for p in ps:
        p.start()
    ready.wait()
    time.sleep(0.03)
    err = None
    try:
        swap(method, mem, vault, gap)
    except OSError as e:
        err = f"{type(e).__name__}:{errno.errorcode.get(e.errno)}"
    time.sleep(0.03)
    stop.set()
    res = {}
    for _ in ps:
        item = q.get()
        res[item[0]] = item[1:]
    for p in ps:
        p.join()
    # where did things end up
    linked = os.path.islink(mem) and os.path.realpath(mem) == os.path.realpath(vault)
    stray = os.path.isdir(mem) and not os.path.islink(mem) and os.path.exists(vault)
    names = res["mkwriter"][1]
    in_vault = set(os.listdir(vault)) if os.path.isdir(vault) else set()
    lost = [n for n in names if n not in in_vault]
    lines = 0
    if os.path.isfile(os.path.join(vault, "log.md")):
        with open(os.path.join(vault, "log.md")) as f:
            lines = sum(1 for _ in f)
    return dict(err=err, linked=linked, stray_real_dir=stray, reader=res["reader"][0],
                writer=res["mkwriter"][0], writes_outside_vault=len(lost),
                appended=res["appender"][0], log_lines_in_vault=lines)


def main():
    root, method, iters = sys.argv[1], sys.argv[2], int(sys.argv[3])
    gap = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
    agg = dict(iters=iters, err={}, not_linked=0, stray=0, reader={}, writer={},
               writes_outside_vault=0, append_mismatch=0)
    for i in range(iters):
        r = one(os.path.join(root, f"{method}-{i}"), method, gap)
        if r["err"]:
            agg["err"][r["err"]] = agg["err"].get(r["err"], 0) + 1
        agg["not_linked"] += not r["linked"]
        agg["stray"] += r["stray_real_dir"]
        for k in ("reader", "writer"):
            for e, n in r[k].items():
                if e != "ok":
                    agg[k][e] = agg[k].get(e, 0) + n
        agg["writes_outside_vault"] += r["writes_outside_vault"]
        agg["append_mismatch"] += r["appended"] != r["log_lines_in_vault"]
    print(f"method={method} gap={gap}s", agg)


if __name__ == "__main__":
    main()
```

`edge_probe.py`:

```python
#!/usr/bin/env python3
"""Edge probes for the RENAME_SWAP move. Usage: edge_probe.py <scratch-root>"""
import ctypes, os, subprocess, sys, time

libc = ctypes.CDLL("libc.dylib", use_errno=True)


def swap(a, b):
    if libc.renamex_np(a.encode(), b.encode(), 0x2) != 0:
        e = ctypes.get_errno()
        return f"error errno={e} ({os.strerror(e)})"
    return "ok"


def fixture(root, name):
    home = os.path.join(root, name, "home")
    mem = os.path.join(home, ".claude/projects/-enc/memory")
    vault = os.path.join(home, "Memory/proj")
    os.makedirs(mem)
    os.makedirs(os.path.dirname(vault))
    with open(os.path.join(mem, "MEMORY.md"), "w") as f:
        f.write("# Memory\n")
    return home, mem, vault


def show(label, *paths):
    for p in paths:
        kind = "link->" + os.readlink(p) if os.path.islink(p) else ("dir" if os.path.isdir(p) else ("missing" if not os.path.lexists(p) else "file"))
        print(f"  {label}: {p.split('/home/')[-1]} = {kind}")


root = sys.argv[1]

print("E1 memory/ is already a symlink (to elsewhere) at swap time")
home, mem, vault = fixture(root, "e1")
other = os.path.join(home, "elsewhere")
os.rename(mem, other)
os.symlink(other, mem)
os.symlink(vault, vault)
print("  swap:", swap(vault, mem))
show("after", mem, vault)
print("  memory/MEMORY.md readable:", os.path.isfile(os.path.join(mem, "MEMORY.md")), "| vault is a real dir:", os.path.isdir(vault) and not os.path.islink(vault))

print("E2 vault folder already exists (non-empty dir) -> self-loop link cannot be made")
home, mem, vault = fixture(root, "e2")
os.makedirs(vault)
open(os.path.join(vault, "x.md"), "w").close()
try:
    os.symlink(vault, vault)
    print("  symlink: ok")
except OSError as e:
    print("  symlink:", type(e).__name__, e.errno)

print("E3 git store inside memory/ survives the swap")
home, mem, vault = fixture(root, "e3")
g = ["git", "-c", "user.name=p", "-c", "user.email=p@p", "-C"]
subprocess.run(g + [mem, "init", "-q"], check=True)
subprocess.run(g + [mem, "add", "MEMORY.md"], check=True)
subprocess.run(g + [mem, "commit", "-qm", "c1"], check=True)
os.symlink(vault, vault)
print("  swap:", swap(vault, mem))
r = subprocess.run(["git", "-C", mem, "log", "--oneline"], capture_output=True, text=True)
s = subprocess.run(["git", "-C", mem, "status", "--porcelain"], capture_output=True, text=True)
print("  git log via link:", r.stdout.strip().split(" ", 1)[1] if r.stdout else r.stderr.strip(), "| status lines:", len(s.stdout.splitlines()))

print("E4 process whose cwd is inside memory/ during the swap")
home, mem, vault = fixture(root, "e4")
p = subprocess.Popen(["/bin/sh", "-c", "sleep 0.3; pwd -P; echo hi > from-cwd.md"], cwd=mem, stdout=subprocess.PIPE, text=True)
time.sleep(0.1)
os.symlink(vault, vault)
print("  swap:", swap(vault, mem))
out = p.communicate()[0].strip()
print("  child pwd -P after swap:", out.split("/home/")[-1], "| file landed in vault:", os.path.isfile(os.path.join(vault, "from-cwd.md")))

print("E5 fswatch started on the memory/ path before the swap, write after")
home, mem, vault = fixture(root, "e5")
log = os.path.join(root, "e5", "fswatch.log")
fw = subprocess.Popen(["fswatch", "-r", mem], stdout=open(log, "w"))
time.sleep(1.0)
open(os.path.join(mem, "before.md"), "w").close()
time.sleep(1.0)
os.symlink(vault, vault)
print("  swap:", swap(vault, mem))
time.sleep(1.0)
open(os.path.join(mem, "after.md"), "w").close()
time.sleep(2.0)
fw.terminate()
fw.wait()
ev = [l.strip().split("/home/")[-1] for l in open(log)]
print("  events:", ev)

print("E6 rollback: swap back (link at memory/, dir at vault)")
home, mem, vault = fixture(root, "e6")
os.symlink(vault, vault)
print("  forward swap:", swap(vault, mem))
print("  back swap:", swap(vault, mem))
show("after back", mem, vault)
os.unlink(vault)
show("after unlink of self-loop", vault)
print("  memory/MEMORY.md readable:", os.path.isfile(os.path.join(mem, "MEMORY.md")))
```

Store measurement: import `skills/meta/memory-lint/scripts/memory-lint.py` with `importlib`, and for each `$HOME/.claude/projects/<enc>/memory` that holds a `MEMORY.md` call `collect_state`, `detector_findings`, `measured_index` and `compute_depths`; count depth values above 2 and files missing from the depth map. Read-only.
