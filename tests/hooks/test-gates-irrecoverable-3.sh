#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal \$ in test payload strings is intentional
# Gate unit tests: simulates PreToolUse JSON payloads and asserts allow/deny/ask.
# Each test_deny call expects exit 2; test_allow expects exit 0 + empty stdout;
# test_ask expects exit 0 + a permissionDecision: ask JSON on stdout.
# Run standalone: bash tests/hooks/test-gates-irrecoverable-3.sh
# Part 3 of 5 of the gate tests (see test-gates.sh); helpers in tests/_lib/gates-harness.sh.
set -uo pipefail
# A git hook exports GIT_DIR; the sandbox git init/config would then target the real repo
# (GH #234, tests/scripts/test-git-env-unset-lint.sh). run-gauntlet.sh does the same unset.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tests/_lib/gates-harness.sh"

echo "=== irrecoverable gate (part 3) ==="
# GH #562 follow-up: PR #572 regressed an empty value to a read. The token window drops an empty word, and the
# word window's git scan dropped it too, so `core.hooksPath ""` read as the key alone. An empty hooksPath
# unwires every hook. Removing or renaming the core section drops core.hooksPath without naming it.
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath \"\" (empty value unwires every hook)" "$(bash_payload 'git config core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath '' (single-quoted empty value)" "$(bash_payload "git config core.hooksPath ''")"
test_deny  "$IRRECOVERABLE" "GH #562: git config set core.hooksPath \"\"" "$(bash_payload 'git config set core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --replace-all core.hooksPath \"\"" "$(bash_payload 'git config --replace-all core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath \"\" git-hooks (git-hooks is the value-pattern)" "$(bash_payload 'git config core.hooksPath "" git-hooks')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --remove-section core" "$(bash_payload 'git config --remove-section core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config remove-section core" "$(bash_payload 'git config remove-section core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --remove-section Core (section names ignore case)" "$(bash_payload 'git config --remove-section Core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rem core (unique prefix)" "$(bash_payload 'git config --rem core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rename-section core x" "$(bash_payload 'git config --rename-section core x')"
test_deny  "$IRRECOVERABLE" "GH #562: git config rename-section core x" "$(bash_payload 'git config rename-section core x')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rename-section x core (renaming onto core writes it)" "$(bash_payload 'git config --rename-section x core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --file .git/config --remove-section core" "$(bash_payload 'git config --file .git/config --remove-section core')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config get core.hooksPath" "$(bash_payload 'git config get core.hooksPath')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --remove-section alias" "$(bash_payload 'git config --remove-section alias')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --rename-section alias x" "$(bash_payload 'git config --rename-section alias x')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --get core.hooksPath \"\" (a value-pattern on a read)" "$(bash_payload 'git config --get core.hooksPath ""')"
_hp_pad_cmd="git config core.hooksPath git-hooks$(python3 -c 'print(" \"\"" * 46000)')"
_timed_case 'GH #562: a 140 KB run of empty words after core.hooksPath is denied in bounded time' 2 "$_hp_pad_cmd"

# GH #562 round 2: git runs no hooks with an empty core.hooksPath (git 2.43, a marker pre-commit hook in a
# throwaway repo), so a -c pair with an empty value is the same bypass; the rows above use /tmp/evil.
test_deny  "$IRRECOVERABLE" "GH #562: git -c \"core.hooksPath=\" commit (quoted)" "$(bash_payload 'git -c "core.hooksPath=" commit -m x')"
test_deny  "$IRRECOVERABLE" "GH #562: git --config-env=core.hooksPath=V commit still denies" "$(bash_payload 'git --config-env=core.hooksPath=V commit -m x')"
test_deny  "$IRRECOVERABLE" "GH #562: GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0= still denies" "$(bash_payload 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0= git commit -m x')"
# A section name built at run time counts only when its literal prefix can still become core.
test_allow "$IRRECOVERABLE" "GH #562 control: --rename-section alias \"x\$Y\" (cannot become core)" "$(bash_payload 'git config --rename-section alias "x$Y"')"
test_allow "$IRRECOVERABLE" "GH #562 control: --remove-section alias\$(date) (cannot become core)" "$(bash_payload 'git config --remove-section alias$(date)')"
test_deny  "$IRRECOVERABLE" "GH #562: --remove-section \"\$S\" (may be core)" "$(bash_payload 'git config --remove-section "$S"')"
test_deny  "$IRRECOVERABLE" "GH #562: --remove-section co\$X (may be core)" "$(bash_payload 'git config --remove-section co$X')"
test_deny  "$IRRECOVERABLE" "GH #562: --rename-section alias C\$(echo ore) (may be core)" "$(bash_payload 'git config --rename-section alias C$(echo ore)')"

# Empty config values (git 2.43, live-checked): git reads an empty boolean as false, so a stored
# `clean.requireForce ""` lets a later bare `git clean` delete; the git scan dropped the empty word, so the
# write read as a key alone. An empty `-c core.hooksPath=` skips every hook (the commit lands past a failing
# pre-commit); the -c check required a non-empty value.
test_deny  "$IRRECOVERABLE" "empty value: git config clean.requireForce \"\"" "$(bash_payload 'git config clean.requireForce ""')"
test_deny  "$IRRECOVERABLE" "empty value: git config clean.requireForce ''" "$(bash_payload "git config clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git config set clean.requireForce \"\"" "$(bash_payload 'git config set clean.requireForce ""')"
test_deny  "$IRRECOVERABLE" "empty value: git config clean.requireForce \"\$(true)\" (blanks to empty)" \
  "$(bash_payload 'git config clean.requireForce "$(true)"')"
# The write forms that skip options before the key (_git_config_write's options()) see the empty word too.
test_deny  "$IRRECOVERABLE" "empty value: git config --add clean.requireForce ''" "$(bash_payload "git config --add clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git config --replace-all clean.requireForce ''" "$(bash_payload "git config --replace-all clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git config --global clean.requireForce ''" "$(bash_payload "git config --global clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git config --file .git/config clean.requireForce ''" "$(bash_payload "git config --file .git/config clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git config --type=bool clean.requireForce ''" "$(bash_payload "git config --type=bool clean.requireForce ''")"
test_deny  "$IRRECOVERABLE" "empty value: git -c core.hooksPath= commit" "$(bash_payload 'git -c core.hooksPath= commit -m x')"
test_deny  "$IRRECOVERABLE" "empty value: git -c core.hooksPath=\"\" commit" "$(bash_payload 'git -c core.hooksPath="" commit -m x')"
test_deny  "$IRRECOVERABLE" "empty value: git -ccore.hooksPath= commit (joined)" "$(bash_payload 'git -ccore.hooksPath= commit -m x')"
test_deny  "$IRRECOVERABLE" "empty value: git --config-env=core.hooksPath= commit" "$(bash_payload 'git --config-env=core.hooksPath= commit -m x')"
test_allow "$IRRECOVERABLE" "empty value control: git config user.name \"\"" "$(bash_payload 'git config user.name ""')"
test_allow "$IRRECOVERABLE" "empty value control: git config clean.requireForce true" "$(bash_payload 'git config clean.requireForce true')"
test_allow "$IRRECOVERABLE" "empty value control: git -c user.name= commit" "$(bash_payload 'git -c user.name= commit -m x')"
# A risk key whose empty value is git's false is safe: remote.<name>.mirror "" is no mirror.
test_allow "$IRRECOVERABLE" "empty value control: git config remote.origin.mirror ''" "$(bash_payload "git config remote.origin.mirror ''")"

# GH #563 follow-up review of PR #573: send-pack's -f is --force (bundled too); git rm reads its
# options in order with last-wins for each pair (--cached/--no-cached, -n/--no-dry-run, -f/--no-force),
# stops at "--", and --pathspec-from-file takes the next word; branch -f bundled with -m/-c onto main.
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: send-pack -f overwrites like --force" "$(bash_payload 'git send-pack -f url main')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: send-pack -vf (bundled force)" "$(bash_payload 'git send-pack -vf url main')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: send-pack -qf --all (bundled force)" "$(bash_payload 'git send-pack -qf --all url')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: send-pack url HEAD:main (no force)" "$(bash_payload 'git send-pack url HEAD:main')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: git rm --pathspec-from-file -n -f (-n is the file)" "$(bash_payload 'git rm --pathspec-from-file -n -f')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: git rm --cached --no-cached -f (last one wins)" "$(bash_payload 'git rm --cached --no-cached -f a.py')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up: git rm -- -f (-f after -- is a path)" "$(bash_payload 'git rm -- -f')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up: git rm --no-dry-run -nf (the later -n wins)" "$(bash_payload 'git rm --no-dry-run -nf a.py')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: git rm --no-cached --cached -f (last one wins)" "$(bash_payload 'git rm --no-cached --cached -f a.py')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: git rm -f --no-force" "$(bash_payload 'git rm -f --no-force a.py')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: git rm a.py -f (an option after a path)" "$(bash_payload 'git rm a.py -f')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: git rm --pathspec-from-file=l -f" "$(bash_payload 'git rm --pathspec-from-file=l -f')"
for _c in 'git branch -fm feat main' 'git branch -mf feat main' 'git branch -fc feat main' 'git branch -cf feat main' 'git branch -vfm feat master'; do
  test_deny  "$IRRECOVERABLE" "GH #563 follow-up: $_c (bundled force move/copy onto main)" "$(bash_payload "$_c")"
done
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: git branch -f feat HEAD" "$(bash_payload 'git branch -f feat HEAD')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: git branch -m old new" "$(bash_payload 'git branch -m old new')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up control: git branch -fm old new" "$(bash_payload 'git branch -fm old new')"
test_deny  "$IRRECOVERABLE" "GH #563 follow-up: git rm -f --end-of-options -n (-n is a path)" "$(bash_payload 'git rm -f --end-of-options -n')"
test_allow "$IRRECOVERABLE" "GH #563 follow-up: git rm --end-of-options -f (-f is a path)" "$(bash_payload 'git rm --end-of-options -f')"
_rm_pad_cmd="$(python3 -c 'print("git rm " + "-n --no-dry-run --cached --no-cached " * 3800 + "-f a.py")')"
_timed_case 'GH #563 follow-up: a 140 KB git rm option list is read in bounded time' 2 "$_rm_pad_cmd"

# GH #584 (bypass hunt 2026-10-23 F6): only `docker exec <flags> <container> <cmd>` re-pointed argv0 to
# the command run inside, so SQL (or any rule) behind compose or kubectl passed; so did a docker exec
# value flag (`-u postgres` read as the container) and a shell body run in the container.
for _c in \
  "docker compose exec db psql -c 'DROP TABLE users'" \
  "docker compose -f prod.yml exec -T db psql -c 'DROP TABLE users'" \
  "docker-compose exec db mysql -e 'DROP DATABASE prod'" \
  "kubectl exec db -- psql -c 'DROP TABLE users'" \
  "kubectl -n prod exec -it db-0 -c pg -- psql -c 'DROP TABLE users'" \
  "kubectl exec db-0 -n prod -- sh -c \"psql -c 'DROP TABLE users'\"" \
  "kubectl exec db -- rm -rf /data" \
  "docker exec -u postgres db psql -c 'DROP TABLE users'" \
  "docker exec -e PGPASSWORD=x -w /tmp db psql -c 'DROP TABLE users'" \
  "docker exec db sh -c 'rm -rf /data'" \
  "podman exec db psql -c 'DROP TABLE users'" \
  "docker exec db env PGPASSWORD=x psql -c 'DROP TABLE users'" \
  "docker exec db sudo -u postgres psql -c 'DROP TABLE users'" \
  'docker exec db timeout 5 rm -rf /data' \
  'kubectl exec db -- env A=1 rm -rf /data' \
  "docker exec -itu postgres db psql -c 'DROP TABLE users'" \
  'docker --tlscacert ca.pem exec db rm -rf /data' \
  'podman --runtime crun exec db rm -rf /data' \
  'kubectl -v 9 exec db -- rm -rf /data' ; do
  test_deny "$IRRECOVERABLE" "GH #584: a rule's command run inside a container: $_c" "$(bash_payload "$_c")"
done
for _c in \
  "docker compose exec db psql -c 'select 1'" \
  "kubectl exec db -- psql -c 'select 1'" \
  'kubectl exec db -- ls /data' \
  "docker compose exec db echo 'DROP TABLE users'" \
  'docker compose logs db' \
  'kubectl get pods -n prod' \
  'docker exec -u postgres db ls' ; do
  test_allow "$IRRECOVERABLE" "GH #584 control: nothing destructive runs in the container: $_c" "$(bash_payload "$_c")"
done


# GH #585 (bypass hunt 2026-10-23 F8): dd-device matched the literal prefix `of=/dev/` on argv0 `dd`.
for _c in \
  'dd if=x of=//dev/disk2' \
  'dd if=x of=/./dev/disk2' \
  'dd if=x of=/dev//disk2' \
  'gdd if=/dev/zero of=/dev/disk2' \
  'sudo gdd if=x of=/dev/rdisk2' \
  '/opt/homebrew/bin/gdd if=x of=/dev/disk2' \
  'dd of=/dev/$DISK' \
  'sudo dd if=img of=/dev/rdisk${N} bs=4m' \
  'dd of="/dev/disk$N"' \
  'dd of=/dev/$(echo disk2)' \
  'find /dev -name sda | xargs gdd if=/dev/zero of=/dev/sda' ; do
  test_deny "$IRRECOVERABLE" "GH #585: dd to a raw device by another spelling: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'dd if=x of=$DISK' \
  'dd if=x of="$DISK"' \
  'dd if=x of=${TARGET}' \
  'dd if=x of=${HOME}/disk.img' \
  'dd if=x of=$PWD/../../dev/sda' ; do
  test_ask_says "$IRRECOVERABLE" "GH #585: dd to a target the text does not show asks: $_c" "$(bash_payload "$_c")" "dd"
done
for _c in \
  'dd if=/dev/zero of=out.img bs=1m count=1' \
  'dd if=disk.img of=copy.img' \
  'dd if=/dev/disk2 of=backup.img' \
  'dd if=x of=./dev/disk2' \
  'gdd if=x of=y.img' \
  'echo of=$DISK' \
  'dd if=/dev/zero of=/dev/null bs=1m count=100' \
  'dd if=x of=/dev/stdout' \
  'dd if=x of=$PWD/out.img' \
  'dd if=x of="$TMPDIR/out.img"' \
  'dd if=x of=$HOME/disk.img' ; do
  test_allow "$IRRECOVERABLE" "GH #585 control: dd to a file, or no dd: $_c" "$(bash_payload "$_c")"
done

# GH #562 follow-up: PR #572 regressed an empty value to a read. The token window drops an empty word, and the
# word window's git scan dropped it too, so `core.hooksPath ""` read as the key alone. An empty hooksPath
# unwires every hook. Removing or renaming the core section drops core.hooksPath without naming it.
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath \"\" (empty value unwires every hook)" "$(bash_payload 'git config core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath '' (single-quoted empty value)" "$(bash_payload "git config core.hooksPath ''")"
test_deny  "$IRRECOVERABLE" "GH #562: git config set core.hooksPath \"\"" "$(bash_payload 'git config set core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --replace-all core.hooksPath \"\"" "$(bash_payload 'git config --replace-all core.hooksPath ""')"
test_deny  "$IRRECOVERABLE" "GH #562: git config core.hooksPath \"\" git-hooks (git-hooks is the value-pattern)" "$(bash_payload 'git config core.hooksPath "" git-hooks')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --remove-section core" "$(bash_payload 'git config --remove-section core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config remove-section core" "$(bash_payload 'git config remove-section core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --remove-section Core (section names ignore case)" "$(bash_payload 'git config --remove-section Core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rem core (unique prefix)" "$(bash_payload 'git config --rem core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rename-section core x" "$(bash_payload 'git config --rename-section core x')"
test_deny  "$IRRECOVERABLE" "GH #562: git config rename-section core x" "$(bash_payload 'git config rename-section core x')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --rename-section x core (renaming onto core writes it)" "$(bash_payload 'git config --rename-section x core')"
test_deny  "$IRRECOVERABLE" "GH #562: git config --file .git/config --remove-section core" "$(bash_payload 'git config --file .git/config --remove-section core')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config get core.hooksPath" "$(bash_payload 'git config get core.hooksPath')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --remove-section alias" "$(bash_payload 'git config --remove-section alias')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --rename-section alias x" "$(bash_payload 'git config --rename-section alias x')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config user.name \"\" (empty value, unrelated key)" "$(bash_payload 'git config user.name ""')"
test_allow "$IRRECOVERABLE" "GH #562 control: git config --get core.hooksPath \"\" (a value-pattern on a read)" "$(bash_payload 'git config --get core.hooksPath ""')"
_hp_pad_cmd="git config core.hooksPath git-hooks$(python3 -c 'print(" \"\"" * 46000)')"
_timed_case 'GH #562: a 140 KB run of empty words after core.hooksPath is denied in bounded time' 2 "$_hp_pad_cmd"

# GH #586 (bypass hunt 2026-10-23 F9): find-exec-rm needed an `rm` word among find's own words, and
# find-delete compared a word to `-delete` exactly.
for _c in \
  "find . -exec sh -c 'rm \"\$1\"' _ {} \;" \
  "find . -exec bash -c 'rm -- \"\$0\"' {} \;" \
  "find . -execdir sh -c 'rm {}' \;" \
  "find . -exec sh -c 'echo \"\$1\"; rm \"\$1\"' _ {} \;" \
  "find . -exec sh -c 'sudo rm \"\$1\"' _ {} +" \
  'find . -$(echo delete)' \
  'find . -de$(echo l)ete' \
  'find . -$(echo exec) rm {} \;' \
  "find . -exec echo {} \\; -exec sh -c 'rm \"\$1\"' _ {} \\;" \
  'find . -exec cat {} \; -delete' \
  'find . -exec echo {} \; -exec rm -rf {} \;' \
  'find . -exec find {} -exec rm {} \; \;' \
  "find . -exec sh -c 'for f do rm \"\$f\"; done' _ {} +" \
  "find . -exec sh -c 'sh -c \"rm \\\$1\"' _ x \\;" \
  "find . -exec sh -c 'eval rm \"\$1\"' _ {} \\;" \
  "find . -exec sh -c 'busybox rm \"\$1\"' _ {} \\;" \
  'find . -name x | xargs -I {} rm {}' \
  'find . -name -name -delete' \
  'find . -name -size -delete' \
  'find . -printf -name -delete' \
  'find . -name x -name -name -delete' \
  'find . -iname -path -execdir rm {} +' \
  'find . -exec cat {} \;>/dev/null -delete' \
  'find . -exec cat {} \;2>/dev/null -delete' \
  'find . -exec cat {}>/dev/null \; -delete' \
  'find . -fprintf f -name -delete' \
  'find . -fprintf f -name -exec rm {} \;' \
  'find . -newerma -name -delete' \
  'find . -newerBt -iname -delete' \
  'find . -files0-from -name -delete' ; do
  test_deny "$IRRECOVERABLE" "GH #586: find deletes through a shell body or a spliced action: $_c" "$(bash_payload "$_c")"
done
for _c in \
  "find . -exec sh -c 'echo \"\$1\"' _ {} \;" \
  "find . -exec sh -c 'grep -l rm \"\$1\"' _ {} \;" \
  "find . -name '*.sh' -exec sh -n {} \;" \
  'find . -name "$(cat pattern)"' \
  'find . -newer x -exec ls {} \;' \
  'find . -name x -print' \
  'find . -name "-$(date +%s)" -print' \
  'find . -newer "-$(cat f)" -print' \
  "find . -exec sh -c 'for f do echo \"\$f\"; done' _ {} +" \
  "find . -ok sh -c 'rm \"\$1\"' _ {} \\;" \
  'find . -exec echo {} \; -print' ; do
  test_allow "$IRRECOVERABLE" "GH #586 control: find runs no delete: $_c" "$(bash_payload "$_c")"
done

# GH #607: the rest of the data-destroying client commands, on argv and on stdin.
test_deny  "$IRRECOVERABLE" "GH #607: DELETE FROM with no WHERE" "$(bash_payload "psql -c 'DELETE FROM users'")"
test_deny  "$IRRECOVERABLE" "GH #607: UPDATE SET with no WHERE" "$(bash_payload "psql -c 'UPDATE users SET pw = NULL'")"
test_deny  "$IRRECOVERABLE" "GH #607: DROP INDEX" "$(bash_payload "mysql -e 'DROP INDEX i ON t'")"
test_deny  "$IRRECOVERABLE" "GH #607: DELETE FROM echoed into psql" "$(bash_payload "echo 'DELETE FROM t' | psql db")"
test_deny  "$IRRECOVERABLE" "GH #607: mongosh dropDatabase" "$(bash_payload "mongosh --eval 'db.dropDatabase()'")"
test_deny  "$IRRECOVERABLE" "GH #607: mongo deleteMany({})" "$(bash_payload "mongo --eval 'db.users.deleteMany({})'")"
test_deny  "$IRRECOVERABLE" "GH #607: redis-cli FLUSHALL" "$(bash_payload 'redis-cli FLUSHALL')"
test_ask   "$IRRECOVERABLE" "GH #607: rsync --delete asks" "$(bash_payload 'rsync -a --delete src/ dst/')"
test_allow "$IRRECOVERABLE" "GH #607 control: DELETE with WHERE" "$(bash_payload "psql -c 'DELETE FROM users WHERE id = 1'")"
test_allow "$IRRECOVERABLE" "GH #607 control: UPDATE with WHERE on the next line" \
  "$(bash_payload "$(printf "psql db <<'SQL'\nUPDATE t SET a = 1\nWHERE id = 3;\nSQL")")"
test_allow "$IRRECOVERABLE" "GH #607 control: mysql FLUSH PRIVILEGES" "$(bash_payload "mysql -e 'FLUSH PRIVILEGES'")"
test_allow "$IRRECOVERABLE" "GH #607 control: mongosh deleteMany with a filter" "$(bash_payload "mongosh --eval 'db.users.deleteMany({age: 3})'")"
test_allow "$IRRECOVERABLE" "GH #607 control: rsync without --delete" "$(bash_payload 'rsync -a src/ dst/')"
_timed_case 'GH #607: 10000 UPDATE ... SET words before a WHERE are read in bounded time' 2 \
  "psql -c '$(python3 -c "print('UPDATE t SET ' * 10000 + 'WHERE x')")'"

# GH #587 (bypass hunt 2026-10-23 F10): chmod-world's root-or-home test knew only `/` and `~` (and
# their `/*`, `/.` forms); a find action applies the mode to every file it finds, as -R does.
for _c in \
  'chmod 777 $HOME' \
  'chmod 777 "$HOME"' \
  'chmod a+rwx $HOME/' \
  'chmod 777 ${HOME}' \
  'chmod 777 "${HOME}"' \
  'chmod 777 "${HOME:-}"' \
  'chmod 777 ${HOME%/}' \
  'echo hi; chmod 777 ${HOME}' \
  $'chmod 777 \\\n${HOME}' \
  $'chmod 777 \\\n"${HOME}"' \
  'chmod 777 ${HOME}>/dev/null' \
  "bash -c 'chmod 777 \"\${HOME}\"'" \
  'chmod 777 ${HOME}/' \
  'chmod 777 $HOME/./' \
  'chmod 777 $HOME//' \
  'chmod 777 ~/./' \
  "find . -exec sh -c 'chmod 777 \"\$1\"' _ {} \\;" \
  "find . -exec bash -c 'sudo chmod -R a+rwx \"\$0\"' {} \\;" \
  "chmod 777 $HOME" \
  "chmod -R 777 $HOME/" \
  'chmod 777 //' \
  'find . -exec chmod 777 {} +' \
  'find . -type f -execdir chmod a+rwx {} \;' \
  'find . -exec sudo chmod 0777 {} +' \
  'gchmod -R 777 .' \
  '/opt/homebrew/bin/gchmod 777 /' ; do
  test_deny "$IRRECOVERABLE" "GH #587: chmod 777 on home, root or every file find yields: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'chmod 777 f' \
  'chmod 777 $HOME/f' \
  "chmod 777 $HOME/project/run.sh" \
  'chmod 755 $HOME' \
  'chmod -R 755 .' \
  'find . -exec chmod 644 {} +' \
  'find . -name "*.sh" -exec chmod +x {} \;' \
  'gchmod 644 f' \
  'chmod 777 ${HOME}/f' \
  'chmod 777 $HOME/./f' \
  'chmod 777 "$(mktemp)"; echo ${HOME}' \
  'chmod 777 $(mktemp) && ls ${HOME}' \
  'chmod 777 `pwd`; echo ${HOME}' \
  'chmod 777 ${PWD}; echo ${HOME}' \
  "find . -exec sh -c 'chmod 644 \"\$1\"' _ {} \\;" \
  'echo chmod 777 $HOME' ; do
  test_allow "$IRRECOVERABLE" "GH #587 control: chmod that is not world-writable on home, root or a find set: $_c" "$(bash_payload "$_c")"
done


# GH #606, #611 review: the -i exception of rule rm-recursive holds only when rm prompts per file
# and nothing in the command can answer. Finding 1: the command feeds rm's stdin (a pipe, <, <<,
# <<<, <&, a heredoc, a coproc), read over the whole command since a group, loop or shell body
# passes its stdin on. Finding 2: the last of -f/-i/-I/--interactive[=WHEN] wins, as GNU rm reads
# them. Finding 3: a -i after -- is a filename. #636 review: options end at the first operand, as BSD/macOS rm
# and GNU rm under POSIXLY_CORRECT read them (operator decision), so a -i after an operand grants nothing
# (`rm -r build -i` deletes build there), while a later -f/-I/--interactive=never still voids it (GNU
# permutes); an interpreter one-liner's process API can feed stdin itself; a terminal driver counts only as
# a command word, not a path part.
for _c in \
  'yes | rm -ri build' \
  'rm -ri build <<< "$(yes | head -1000)"' \
  'rm -ri build < answers.txt' \
  'rm -ri build 0<answers.txt' \
  'rm -ri build <&3' \
  $'rm -ri build <<EOF\ny\ny\nEOF' \
  'yes |& rm -ri build' \
  'yes | (rm -ri build)' \
  '{ rm -ri build; } <<< y' \
  'while :; do rm -ri build; done < answers.txt' \
  "yes | bash -c 'rm -ri build'" \
  "bash -c 'rm -ri build <<< y'" \
  'exec 0<answers.txt; rm -ri build' \
  $'eval $\'yes \\x7c rm -ri build\'' \
  'coproc rm -ri build; yes >&"${COPROC[1]}"' \
  'rm -ri --interactive=never build' \
  'rm -ri -I build' \
  'rm -i -rI build' \
  'rm -ri --interactive=once build' \
  'rm -ri --inter=never build' \
  'rm -ri --interactive=n build' \
  'rm -ri --interactive=no build' \
  'rm -ri --interactive=o build' \
  'rm -ri --interactive= build' \
  'rm -ri --interactive=bogus build' \
  'rm -rfi build' \
  'rm -ri -f build' \
  'rm -ri "$OPTS" build' \
  'rm -ri $(printf %s -f) build' \
  'rm -r -- -i build' \
  'rm -r build -- -i' \
  'POSIXLY_CORRECT=1 rm -r build -i' \
  'rm -r build -i' \
  'rm -r build --interactive' \
  'rm -rI build -i' \
  'rm -ri build -f' \
  'rm -ri build -I' \
  'rm -ri build --interactive=never' \
  'script -qc "rm -ri build" /dev/null' \
  'unbuffer rm -ri build' \
  'sudo expect -f answer.exp; rm -ri build' \
  "python3 -c \"import subprocess; subprocess.run(['rm','-ri','build'], input=b'y\\n'*99)\"" \
  "node -e \"require('child_process').execSync('rm -ri build', {input: 'y\\n'.repeat(99)})\"" \
  "perl -e 'system(\"rm -ri build\")'" ; do
  test_deny "$IRRECOVERABLE" "GH #606/#611 review: rm -r with no per-file prompt nothing answers: $_c" "$(bash_payload "$_c")"
done
# xargs rm already denies whatever its flags (rule xargs-rm); GNU xargs gives rm /dev/null as stdin
# unless -a or -o, so it would answer no, but the rule stays.
for _c in 'echo build | xargs rm -ri' 'xargs -a list.txt rm -ri' 'find . -name build -exec rm -ri {} +' ; do
  test_deny "$IRRECOVERABLE" "GH #606/#611 review confirm: xargs/find hand rm its paths: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'rm -ri build' \
  'rm -ri build/script' \
  'rm -ri tmux' \
  'rm -ri ./expect screen' \
  'rm -ri build; echo script done' \
  'rm -rI -i build' \
  'rm -r --interactive build' \
  'rm -r --interactive=always build' \
  'rm -r --interactive=a build' \
  'rm -r --interactive=yes build' \
  'rm -r --inter build' \
  'rm -r -I --interactive=always build' \
  'rm -ri build > log.txt 2>&1' \
  'rm -ri -- build' \
  'rm -i file.txt' \
  'rm file.txt' \
  'rm -d emptydir' \
  'git rm -r --cached dir' \
  'echo y | rm -i file.txt' \
  'yes | rm -f file.txt' ; do
  test_allow "$IRRECOVERABLE" "GH #606/#611 review control: per-file prompt nothing answers, or not recursive: $_c" "$(bash_payload "$_c")"
done

# GH #588 (bypass hunt 2026-10-23 F11): the spawn anchor reads the literal word `claude` at a command
# position, so a name made by a substitution, or claude run by a find action, passed.
for _c in \
  '$(echo claude) -p hi' \
  '`echo claude` -p hi' \
  '${C:-claude} -p hi' \
  "\$(echo claude) 'fix the test'" \
  'env $(echo claude) --print hi' \
  'find . -maxdepth 0 -exec claude -p hi \;' \
  'find . -exec env claude -p x \;' \
  'find . -exec claude hi \;' \
  'find . -name x -execdir claude --bg {} +' \
  'cat p | $(which claude)' \
  'echo hi | $(echo claude)' \
  '$(echo claude) <<< hi' \
  '$(echo /usr/local/bin/claude) -p x' \
  '${C:-"claude"} -p x' \
  'ls; $(echo claude) -p x' \
  '"$(echo claude)" "-p" x' \
  '"$(echo claude)" -p x' \
  'if $(echo claude) -p x; then :; fi' \
  '! $(echo claude) -p x' \
  'for i in 1; do $(echo claude) -p x; done' \
  'case x in x) $(echo claude) -p x;; esac' \
  'x=$(echo hi) $(echo claude) -p x' \
  'bash -c "\$(echo claude) -p x"' \
  'bash -c "$(echo claude) -p x"' \
  'eval "$(echo claude) -p x"' \
  'find . -exec $(echo claude) -p x \;' \
  'sh -c "echo hi; $(echo claude) -p x"' \
  'sh -c "x=1 $(echo claude) -p x"' \
  'sh -c "if true; then $(echo claude) -p x; fi"' \
  'bash -lc "$(echo claude) -p x"' \
  'bash -c  "$(echo claude) -p x"' \
  'eval $(echo claude) -p x' \
  'bash -o pipefail -c "$(echo claude) -p x"' \
  'bash -O extglob -c "$(echo claude) -p x"' \
  'bash --norc -c "$(echo claude) -p x"' \
  'bash +e -c "$(echo claude) -p x"' \
  'bash -c -- "$(echo claude) -p x"' \
  'bash -c "$(echo "claude") -p x"' \
  'bash -c "$(printf %s "claude") -p x"' \
  '\bash -c "$(echo claude) -p hi"' \
  'true; \sh -c "$(echo claude) -p hi"' \
  'bash -e -e -e -e -e -e -e -e -e -c "$(echo claude) -p x"' \
  'bash -o pipefail -o errexit -o nounset -O a -O b -O c -O d -O e -c "$(echo claude) -p x"' \
  'bash --rcfile /dev/null -c "$(echo claude) -p x"' \
  'bash --init-file x -c "$(echo claude) -p x"' \
  'bash +c "$(echo claude) -p x"' ; do
  test_deny "$IRRECOVERABLE" "GH #588: subagent spawn behind a substitution or a find action: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in \
  '$(echo claude) --version' \
  '$(which claude) --help' \
  '$(cat claude.txt) -p x' \
  '$(git rev-parse --show-toplevel)/run.sh -p x' \
  'find . -exec claude --version \;' \
  'find . -name claude -print' \
  'find . -exec grep -l claude {} +' \
  'V=$(claude --version); $(which python3) run.py' \
  'ls $(echo claude); $(npm bin) hi' \
  '$(which python3) run.py # `which claude`' \
  '$(which claude) mcp list' \
  '$(echo claude)x -p hi' \
  'if [ -x "$(which claude)" ]; then echo ok; fi' \
  'bash -c "$(which claude) --version"' \
  'grep -c "$(echo claude)" file' \
  'du -c "$(which claude)" "$(which node)"' \
  'foo -c "$(which claude)" -p' \
  'eval "$(echo claude) --help"; eval "$(echo claude) --help"' \
  'echo "$(echo claude) is installed"; ls' ; do
  test_allow "$IRRECOVERABLE" "GH #588 control: no session is started: $_c" "$(bash_agent_payload "$_c" fork)"
done
for _c in '$(echo claude) -p hi' 'find . -exec claude -p hi \;' ; do
  test_allow "$IRRECOVERABLE" "GH #588 control: the main session may start one: $_c" "$(bash_agent_payload "$_c" '')"
done


# GH #589 (bypass hunt 2026-10-23 F12): a substitution in a flag position blanks to a placeholder with no
# flag letters, so rm's recursive flag (rm-rf, rm-recursive) was never seen. The "subst-literal" view reads
# the command again with each literal substitution replaced by what it prints.
for _c in \
  'rm $(echo -rf) build' \
  'rm `echo -rf` build' \
  'rm -${X:-rf} build' \
  'rm ${F:--rf} build' \
  'rm ${F:+-rf} build' \
  'rm $(printf -- -rf) build' \
  'rm $(echo -r) build' \
  'rm "$(echo -rf)" build' \
  '/bin/rm $(echo -rf) build' \
  'rm --$(echo recursive) build' \
  'rm $(cat l) "a;b" $(echo -rf) build' \
  'rm $(echo -r) x; rm $(echo -i) y' \
  'sudo rm $(echo -rf) /data' \
  'rm $( echo -rf ) x' \
  'rm ` echo -rf` x' \
  'rm ${X:-${Y:--rf}} x' \
  'rm $(echo $(echo -rf)) x' \
  'rm $(command echo -rf) x' \
  'rm $(/bin/echo -rf) x' \
  'rm ${F:-"-rf"} /tmp/x' \
  "rm \${F:-'-rf'} /tmp/x" \
  "rm \${F:-'-r'}f /tmp/x" \
  'rm -${F:-"r"}f /tmp/x' \
  'git reset ${M:-"--hard"}' \
  'rm "${F:-"-rf"}" /tmp/x' \
  'rm "${F:-\\"x"}" ${G:-"-rf"} /' \
  'rm "${F:-\\"x"}" ${G:--rf} /' \
  'git reset "${F:-\\"x"}" ${M:-"--hard"}' \
  'rm "${F:-\\\\"x"}" ${G:-"-rf"} /' ; do
  test_deny "$IRRECOVERABLE" "GH #589: rm's recursive flag held in a substitution: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'rm $(cat list.txt)' \
  'rm $(echo build.log)' \
  'rm -${X:-i} build.log' \
  'rm -f $(git ls-files -d)' \
  'rm $(echo -ri) build' \
  'echo rm $(echo -rf)' \
  'rm $(cat list); echo rm -rf $(date)' \
  'git rm $(git ls-files -d)' \
  'rm "${TMPDIR:-/tmp}/x"' \
  'rm ${X:-build}' \
  'git commit -m "${MSG:-"chore: x && git reset --hard"}"' \
  'echo "${X:-"a && git reset --hard"}"' \
  "printf '%s\\n' \"\${Q:-\\\"}\" \"; git push --force origin main; \" \"\${Q:-\\\"}\"" ; do
  test_allow "$IRRECOVERABLE" "GH #589 control: rm with no recursive delete: $_c" "$(bash_payload "$_c")"
done

# GH #589 x #585: the subst-literal view shows dd's target, so a device named by a literal echo denies.
# The main reading asks first (a substitution target), so stdout holds that ask: exit 2 is what blocks.
_rc=$(bash_payload 'dd if=x of=$(echo /dev/disk2)' | bash "$IRRECOVERABLE" >/dev/null 2>&1; echo $?)
if [[ "$_rc" == "2" ]]; then
  echo "  ✅ DENY (exit 2): GH #589: dd if=x of=\$(echo /dev/disk2)"; pass=$((pass + 1))
else
  echo "  ❌ exit 2 EXPECTED, got $_rc: GH #589: dd if=x of=\$(echo /dev/disk2)" >&2; fail=$((fail + 1))
fi


# GH #590 (bypass hunt 2026-10-23 F13): a shell (or source / .) reading a process substitution as its
# script ran the substitution's printed text unscanned. (`bash -c "$(echo ...)"` is read by #589's view.)
for _c in \
  'bash <(echo rm -rf build)' \
  'sh <(printf "rm -rf build")' \
  'bash -e <(echo git push --force origin main)' \
  'source <(echo rm -rf build)' \
  '. <(echo git reset --hard)' \
  'bash -c "$(echo rm -rf build)"' \
  'zsh <( echo rm -rf build )' \
  '\bash <(echo rm -rf x)' \
  'bash -o pipefail <(echo rm -rf x)' \
  'bash < <(echo rm -rf build)' \
  'bash -s < <(echo rm -rf build)' \
  "bash <(printf '%s\\n' 'rm -rf build')" \
  'bash <(printf %s "rm -rf build")' \
  'bash -- <(echo rm -rf x)' \
  'bash - <(echo rm -rf x)' \
  'bash -x -- <(echo rm -rf x)' \
  'bash -eo pipefail <(echo rm -rf x)' \
  'bash -euo pipefail <(echo rm -rf x)' \
  'bash -xO extglob <(echo rm -rf x)' \
  "bash <(printf '%s %s %s\\n' rm -rf x)" ; do
  test_deny "$IRRECOVERABLE" "GH #590: a shell runs a substitution's printed text: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'bash <(echo ls)' \
  'cat <(echo rm -rf build)' \
  'diff <(echo a) <(echo b)' \
  'bash <(curl -s https://example.com/install.sh)' \
  'source <(kubectl completion bash)' \
  'bash -c "$(cat x.sh)"' \
  'bash -x script.sh <(echo rm -rf x)' \
  'bash -e build.sh <(echo rm -rf x)' \
  'sh -x ./run.sh < <(echo rm -rf x)' \
  'bash -c x <(echo rm -rf x)' ; do
  test_allow "$IRRECOVERABLE" "GH #590 control: nothing destructive the text shows runs: $_c" "$(bash_payload "$_c")"
done


# GH #591 (bypass hunt 2026-10-23 F14): xargs feeds mkfs its device on stdin, so the mkfs rule saw no
# operand. (`find ... -exec mkfs.ext4 {} \;` denies since #586 made `{}` a word.)
for _c in \
  'xargs mkfs.ext4 <<< /dev/sda1' \
  'echo /dev/sda1 | xargs mkfs -t ext4' \
  'echo /dev/sda1 | xargs sudo mkfs.ext4' \
  'echo /dev/sda1 | xargs -n1 mke2fs' \
  'find /dev -name sda1 -exec mkfs.ext4 {} \;' \
  'xargs mkfs -V -t ext4 <<< /dev/sda1' \
  'xargs mkfs.ext4 -L -V <<< /dev/sda1' \
  'xargs mkfs.ext4 -L --version <<< /dev/sda1' \
  'printf "0 /dev/sdb" | xargs mkfs.vfat -h' \
  'echo d | xargs mkfs.fat -h' ; do
  test_deny "$IRRECOVERABLE" "GH #591: mkfs on a device xargs or find hands it: $_c" "$(bash_payload "$_c")"
done
for _c in \
  'xargs mkfs.ext4 --help' \
  'xargs mkfs --version' \
  'echo x | xargs echo mkfs.ext4' \
  'echo mkfs.ext4' \
  'man mkfs' \
  'git ls-files | xargs grep -l mkfs' ; do
  test_allow "$IRRECOVERABLE" "GH #591 control: no filesystem is made: $_c" "$(bash_payload "$_c")"
done


# GH #647: a PH argv0 reads as every dangerous verb, gh included, and each such window searched the whole
# command for a written `gh <sub>`: quadratic, so padding pushed a later deny past the 8 s hook timeout.
_timed_case "GH #647: 60 KB of 'sudo \${a} x;' then git reset --hard, denied in bounded time" 2 \
  "git status; $(printf 'sudo ${a} x; %.0s' $(seq 4600))git reset --hard"
_timed_case "GH #647: a written gh, then 4000 distinct PH subcommands, then git reset --hard, denied in bounded time" 2 \
  "gh -R o/r issue list; $(for i in $(seq 4000); do printf 'sudo ${a} x%d; ' "$i"; done)git reset --hard"
# the gh-unknown-subcommand reading it replaced: a `gh <sub>` the command writes, past gh's own flags
test_ask   "$IRRECOVERABLE" "GH #647: gh -R o/r nuke still asks" "$(bash_payload 'gh -R o/r nuke')"
test_ask   "$IRRECOVERABLE" "GH #647: gh --repo o/r nuke still asks" "$(bash_payload 'gh --repo o/r nuke')"
test_ask   "$IRRECOVERABLE" "GH #647: ls;gh nuke still asks" "$(bash_payload 'ls;gh nuke')"
test_ask   "$IRRECOVERABLE" "GH #647: gh nuke, then the sub glued to a separator" "$(bash_payload 'gh nuke;ls')"
test_allow "$IRRECOVERABLE" "GH #647 control: a PH argv0 with no gh written" "$(bash_payload 'sudo ${a} x')"
test_allow "$IRRECOVERABLE" "GH #647 control: gh-nuke is a different program" "$(bash_payload 'echo gh-nuke x')"
# GH #594: after a bare `--` every word is an operand, so `rm -- -rf` deletes a file named -rf. GNU rm
# still permutes the options before `--` (`rm build -rf` is -rf).
test_allow "$IRRECOVERABLE" "GH #594: rm -- -rf removes a file named -rf" "$(bash_payload 'rm -- -rf')"
test_allow "$IRRECOVERABLE" "GH #594: rm -f -- -r removes a file named -r" "$(bash_payload 'rm -f -- -r')"
test_deny  "$IRRECOVERABLE" "GH #594: rm -r -- -f is still rm -r (rm-recursive)" "$(bash_payload 'rm -r -- -f')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm -rf -- build" "$(bash_payload 'rm -rf -- build')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm build -rf (options permute before --)" "$(bash_payload 'rm build -rf')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm -r build -- -f still has -r" "$(bash_payload 'rm -r build -- -f')"
# a -- a substitution builds may not be one: a non-empty $(x) makes it an operand and leaves -rf a flag
test_deny  "$IRRECOVERABLE" "GH #594 control: rm \$(x)-- -rf build" "$(bash_payload 'rm $(x)-- -rf build')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm --x -rf build (not a bare --)" "$(bash_payload 'rm --x -rf build')"
# the tokenizer splits at a carriage return and bash does not: `a<CR>--` is one operand, and -rf after it a flag
test_deny  "$IRRECOVERABLE" "GH #594 control: rm a<CR>-- -rf build (not a bare --)" "$(bash_payload $'rm a\r-- -rf build')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm a<CR>-- -r build (rm-recursive)" "$(bash_payload $'rm a\r-- -r build')"
# ...nor one the gate decodes from `$'\r'` into a bash -c or eval body
test_deny  "$IRRECOVERABLE" "GH #594 control: bash -c \$'rm a\\r-- -rf b'" "$(bash_payload "bash -c \$'rm a\\r-- -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #594 control: eval \$'rm a\\r-- -rf b'" "$(bash_payload "eval \$'rm a\\r-- -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #594 control: eval rm a\$'\\r'-- -rf b" "$(bash_payload "eval rm a\$'\\r'-- -rf b")"
test_allow "$IRRECOVERABLE" "GH #594: rm -r -i -- -f prompts for every file" "$(bash_payload 'rm -r -i -- -f')"
# ...nor one a redirect or an interpreter's argv only seems to show: the stop needs a plain rm command
test_deny  "$IRRECOVERABLE" "GH #594 control: rm a <<- -- -rf b (-- is the heredoc word)" "$(bash_payload $'rm a <<- -- -rf b\n--')"
test_deny  "$IRRECOVERABLE" "GH #594 control: rm a >x> -- -rf b (-- is a redirect target)" "$(bash_payload 'rm a >x> -- -rf b')"
test_deny  "$IRRECOVERABLE" "GH #594 control: subprocess.run([rm, 'a --', -rf, b])" \
  "$(bash_payload 'python3 -c '"'"'import subprocess; subprocess.run(["rm", "a --", "-rf", "b"])'"'"'')"
test_allow "$IRRECOVERABLE" "GH #594: rm -f -- -r ./x.log (plain operands)" "$(bash_payload 'rm -f -- -r ./x.log')"

# GH #662: `busybox [--] APPLET args` runs the applet, so every rule reads the applet as the command.
test_deny  "$IRRECOVERABLE" "GH #662: busybox rm -rf b" "$(bash_payload 'busybox rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox -- rm -rf b" "$(bash_payload 'busybox -- rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #662: /bin/busybox rm -r b" "$(bash_payload '/bin/busybox rm -r b')"
test_deny  "$IRRECOVERABLE" "GH #662: sudo busybox rm -rf b" "$(bash_payload 'sudo busybox rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox dd of=/dev/sda" "$(bash_payload 'busybox dd if=/dev/zero of=/dev/sda')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox mkfs.ext2 /dev/sda1" "$(bash_payload 'busybox mkfs.ext2 /dev/sda1')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox find . -delete" "$(bash_payload 'busybox find . -delete')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox sh -c 'rm -rf b'" "$(bash_payload "busybox sh -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: busybox xargs rm -rf" "$(bash_payload 'echo b | busybox xargs rm -rf')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox chmod -R 777 /" "$(bash_payload 'busybox chmod -R 777 /')"
# the rules that walk their own wrapper list (xargs, find -exec, a shell reading stdin) read past it too
test_deny  "$IRRECOVERABLE" "GH #662: xargs busybox rm" "$(bash_payload 'echo b | xargs busybox rm')"
test_deny  "$IRRECOVERABLE" "GH #662: xargs busybox mkfs.ext2" "$(bash_payload 'echo /dev/sdb1 | xargs busybox mkfs.ext2')"
test_deny  "$IRRECOVERABLE" "GH #662: find -exec busybox chmod 777" "$(bash_payload 'find . -exec busybox chmod 777 {} +')"
test_deny  "$IRRECOVERABLE" "GH #662: find -exec busybox sh -c 'rm b'" "$(bash_payload "find . -exec busybox sh -c 'rm b' \\;")"
test_deny  "$IRRECOVERABLE" "GH #662: echo 'rm -rf b' | busybox sh" "$(bash_payload "echo 'rm -rf b' | busybox sh")"
test_deny  "$IRRECOVERABLE" "GH #662: busybox sh <<< 'rm -rf b'" "$(bash_payload "busybox sh <<< 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: cat <<EOF | busybox sh" "$(bash_payload $'cat <<EOF | busybox sh\nrm -rf b\nEOF')"
# busybox's shells, and busybox's other names
test_deny  "$IRRECOVERABLE" "GH #662: busybox ash -c 'rm -rf b'" "$(bash_payload "busybox ash -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: busybox hush -c 'rm -rf b'" "$(bash_payload "busybox hush -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: ash -c 'rm -rf b'" "$(bash_payload "ash -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: cat <<EOF | busybox ash" "$(bash_payload $'cat <<EOF | busybox ash\nrm -rf b\nEOF')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox.static rm -rf b" "$(bash_payload '/bin/busybox.static rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox-static rm -rf b" "$(bash_payload 'busybox-static rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #662: toybox dd of=/dev/sda" "$(bash_payload 'toybox dd if=/dev/zero of=/dev/sda')"
# ash and dash take the next word for every o in a cluster (bash's reading), and +c runs CMD as -c does
test_deny  "$IRRECOVERABLE" "GH #662: ash -oc pipefail 'rm -rf b'" "$(bash_payload "ash -oc pipefail 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: busybox ash -ooc errexit pipefail 'rm -rf b'" "$(bash_payload "busybox ash -ooc errexit pipefail 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: dash -oc pipefail 'rm -rf b'" "$(bash_payload "dash -oc pipefail 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: ash +c 'rm -rf b'" "$(bash_payload "ash +c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: bash +c 'rm -rf b'" "$(bash_payload "bash +c 'rm -rf b'")"
# the echo upstream of a stdin shell, written through busybox or a path
test_deny  "$IRRECOVERABLE" "GH #662: busybox echo 'rm -rf b' | sh" "$(bash_payload "busybox echo 'rm -rf b' | sh")"
test_deny  "$IRRECOVERABLE" "GH #662: toybox echo 'rm -rf b' | ash" "$(bash_payload "toybox echo 'rm -rf b' | ash")"
test_deny  "$IRRECOVERABLE" "GH #662: /bin/echo 'rm -rf b' | sh" "$(bash_payload "/bin/echo 'rm -rf b' | sh")"
# busybox's `--`, and command's -p / --, before a stdin shell, its echo, or a find body's applet
test_deny  "$IRRECOVERABLE" "GH #662: echo 'rm -rf b' | busybox -- sh" "$(bash_payload "echo 'rm -rf b' | busybox -- sh")"
test_deny  "$IRRECOVERABLE" "GH #662: busybox -- sh <<< 'rm -rf b'" "$(bash_payload "busybox -- sh <<< 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #662: cat <<EOF | busybox -- sh" "$(bash_payload $'cat <<EOF | busybox -- sh\nrm -rf b\nEOF')"
test_deny  "$IRRECOVERABLE" "GH #662: busybox -- echo 'rm -rf b' | sh" "$(bash_payload "busybox -- echo 'rm -rf b' | sh")"
test_deny  "$IRRECOVERABLE" "GH #662: command -p echo 'rm -rf b' | sh" "$(bash_payload "command -p echo 'rm -rf b' | sh")"
test_deny  "$IRRECOVERABLE" "GH #662: command -- echo 'rm -rf b' | sh" "$(bash_payload "command -- echo 'rm -rf b' | sh")"
test_deny  "$IRRECOVERABLE" "GH #662: find -exec sh -c 'busybox -- chmod 777 \"\$1\"'" \
  "$(bash_payload "find . -exec sh -c 'busybox -- chmod 777 \"\$1\"' _ {} \\;")"
test_allow "$IRRECOVERABLE" "GH #662 control: ash +x script.sh" "$(bash_payload 'ash +x script.sh')"
test_allow "$IRRECOVERABLE" "GH #662 control: busybox echo 'ls' | sh" "$(bash_payload "busybox echo 'ls' | sh")"
test_allow "$IRRECOVERABLE" "GH #662 control: busybox sh -c 'ls -la'" "$(bash_payload "busybox sh -c 'ls -la'")"
test_allow "$IRRECOVERABLE" "GH #662 control: toybox ls" "$(bash_payload 'toybox ls')"
test_allow "$IRRECOVERABLE" "GH #662 control: cat <<EOF | busybox ash (echo body)" "$(bash_payload $'cat <<EOF | busybox ash\necho hi\nEOF')"
test_allow "$IRRECOVERABLE" "GH #662 control: busybox ls -la" "$(bash_payload 'busybox ls -la')"
test_allow "$IRRECOVERABLE" "GH #662 control: busybox --list" "$(bash_payload 'busybox --list')"
test_allow "$IRRECOVERABLE" "GH #662 control: busybox rm x.log" "$(bash_payload 'busybox rm x.log')"
test_allow "$IRRECOVERABLE" "GH #662 control: echo busybox rm -rf b" "$(bash_payload 'echo busybox rm -rf b')"

# GH #661: bash brace-expands rm's own words before rm parses them: `--{r,f}` is `--r --f`, i.e. -rf.
test_deny  "$IRRECOVERABLE" "GH #661: rm --{r,f} b" "$(bash_payload 'rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: rm --{recursive,force} b" "$(bash_payload 'rm --{recursive,force} b')"
test_deny  "$IRRECOVERABLE" "GH #661: rm {-r,-f} b" "$(bash_payload 'rm {-r,-f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: rm --{r,} b (rm-recursive)" "$(bash_payload 'rm --{r,} b')"
test_deny  "$IRRECOVERABLE" "GH #661: rm --{rec,verbose} b (rm-recursive)" "$(bash_payload 'rm --{rec,verbose} b')"
test_deny  "$IRRECOVERABLE" "GH #661: sudo rm --{r,f} b" "$(bash_payload 'sudo rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: bash -c 'rm --{r,f} b'" "$(bash_payload "bash -c 'rm --{r,f} b'")"
test_deny  "$IRRECOVERABLE" "GH #661: rm --no-preserve-{root,x} -r /" "$(bash_payload 'rm --no-preserve-{root,x} -r /')"
# a shadowed brace-view hit earlier in the command does not end the view before the rm
test_deny  "$IRRECOVERABLE" "GH #661: fi{nd,nd} ... -delete; rm --{r,f} b" "$(bash_payload 'fi{nd,nd} /nonexistent -delete; rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: git push --fo{rce,rce} ...; rm --{r,f} b" "$(bash_payload 'git push --fo{rce,rce} --dry-run origin main; rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: git br{anch,anch} -D x; r{m,} -rf /tmp/x" "$(bash_payload 'git br{anch,anch} -D nosuchbranch; r{m,} -rf /tmp/x')"
test_deny  "$IRRECOVERABLE" "GH #661: true && fi{nd,nd} ... || r{m,} -rf /tmp/x" "$(bash_payload 'true && fi{nd,nd} /nonexistent -delete || r{m,} -rf /tmp/x')"
# ...nor a word window the first pass already saw, nor another rule firing first in the rm's own window
test_deny  "$IRRECOVERABLE" "GH #661: decoy; sudo -u \$U r{m,} -rf b" "$(bash_payload 'fi{nd,nd} x -delete; sudo -u $U r{m,} -rf b')"
test_deny  "$IRRECOVERABLE" "GH #661: decoy; X=\$Y r{m,} -rf b" "$(bash_payload 'fi{nd,nd} x -delete; X=$Y r{m,} -rf b')"
test_deny  "$IRRECOVERABLE" "GH #661: GIT_CONFIG_PARAMETERS=core.hooks{path,path} rm --{r,f} b" \
  "$(bash_payload 'GIT_CONFIG_PARAMETERS=core.hooks{path,path} rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: echo b | xargs r{m,} -rf" "$(bash_payload 'echo b | xargs r{m,} -rf')"
# a structural limit only the expanded text reaches (an eval chain past the depth limit, the xargs handover
# budget) denies in the enforced pass, as it does in the main reading
test_deny  "$IRRECOVERABLE" "GH #661: e{val,val} x3 rm --{r,f} b" "$(bash_payload 'e{val,val} e{val,val} e{val,val} rm --{r,f} b')"
test_deny  "$IRRECOVERABLE" "GH #661: 55 xargs e{nv,} decoys, then xargs env r{m,} -rf b" \
  "$(bash_payload "$(printf ': | xargs e{nv,} true; %.0s' $(seq 55)): | xargs env r{m,} -rf b")"
# a word glued to a substitution is not every verb in the enforced pass's word windows (as in _run_words)
test_allow "$IRRECOVERABLE" "GH #661 control: decoy; sudo -u \$U ./build\"\$(date +%s)\" -r out" \
  "$(bash_payload 'echo {a,b}; f{ind,ind} . -name x -delete; sudo -u $U ./build"$(date +%s)" -r out')"
test_allow "$IRRECOVERABLE" "GH #661 control: decoy; sudo -u \$U python\"\$(echo 3)\" -m compileall -r 2 {a,b}" \
  "$(bash_payload 'fi{nd,nd} x -delete; sudo -u $U python"$(echo 3)" -m compileall -r 2 {a,b}')"

# GH #309: push's force, mirror and protected-delete rules read the brace-expanded words too (`--{force,force}`).
test_deny  "$IRRECOVERABLE" "GH #309: git push --{force,force} origin main" "$(bash_payload 'git push --{force,force} origin main')"
test_deny  "$IRRECOVERABLE" "GH #309: git push -{f,f} origin main" "$(bash_payload 'git push -{f,f} origin main')"
test_deny  "$IRRECOVERABLE" "GH #309: git push --fo{rce,rce} origin HEAD:feat" "$(bash_payload 'git push --fo{rce,rce} origin HEAD:feat')"
test_deny  "$IRRECOVERABLE" "GH #309: git push origin +{main,main}:main" "$(bash_payload 'git push origin +{main,main}:main')"
test_deny  "$IRRECOVERABLE" "GH #309: git push --{mirror,mirror} origin" "$(bash_payload 'git push --{mirror,mirror} origin')"
test_deny  "$IRRECOVERABLE" "GH #309: git push origin :{main,main}" "$(bash_payload 'git push origin :{main,main}')"
test_deny  "$IRRECOVERABLE" "GH #309: echo {a,b}; git push --{force,force} origin main" "$(bash_payload 'echo {a,b}; git push --{force,force} origin main')"
test_allow "$IRRECOVERABLE" "GH #309 control: git push origin HEAD:{feat1,feat2}" "$(bash_payload 'git push origin HEAD:{feat1,feat2}')"
# the enforced pass runs no spawn scan: a subagent body the main reading fits is not denied as a spawn
test_allow "$IRRECOVERABLE" "GH #661 control: subagent bash -c with 800 statements, then echo {a,b}" \
  "$(bash_agent_payload "bash -c '$(printf 'true; %.0s' $(seq 800))true'; echo {a,b}" fork)"
# the pass reads rm's rules only and runs no spawn scan, so an expansion that copies a long eval body many times
# spends no scan budget there: allowed, as on develop, and the rm in or after that body is still read
_x661="eval '$(printf 'true;%.0s' $(seq 50))true'{$(seq -s, 0 29)}"
test_allow "$IRRECOVERABLE" "GH #661 control: subagent eval 'true;...'{0..29} (no spawn scan in the pass)" \
  "$(bash_agent_payload "$_x661" fork)"
test_deny  "$IRRECOVERABLE" "GH #661: subagent: the rm inside the body that spends the budget" \
  "$(bash_agent_payload "eval '$(printf 'true;%.0s' $(seq 50))true'{$(seq -s, 0 29)} '; rm --{r,f} b'" fork)"
test_deny  "$IRRECOVERABLE" "GH #661: subagent: budget-spending expansion, then bash -c 'rm --{r,f} b'" \
  "$(bash_agent_payload "$_x661; bash -c 'rm --{r,f} b'" fork)"
test_deny  "$IRRECOVERABLE" "GH #661: subagent: budget-spending expansion, then e{val,val} x3 rm --{r,f} b" \
  "$(bash_agent_payload "$_x661; e{val,val} e{val,val} e{val,val} rm --{r,f} b" fork)"
test_allow "$IRRECOVERABLE" "GH #661 control: rm {a,b}.log" "$(bash_payload 'rm {a,b}.log')"
test_allow "$IRRECOVERABLE" "GH #661 control: rm -f {a,b}.tmp" "$(bash_payload 'rm -f {a,b}.tmp')"
test_allow "$IRRECOVERABLE" "GH #661 control: rm --{verbose,force} b (no -r)" "$(bash_payload 'rm --{verbose,force} b')"
# GH #663: `sh -c BODY ARG0 ARGS...` sets $0 to ARG0 and $1.. / "$@" to ARGS, so the body runs with them.
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \"\$@\"' -- -rf b" "$(bash_payload "bash -c 'rm \"\$@\"' -- -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: sh -c 'rm \$@' _ -rf b" "$(bash_payload "sh -c 'rm \$@' _ -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: sh -c 'rm \"\$1\" \"\$2\"' _ -rf b" "$(bash_payload "sh -c 'rm \"\$1\" \"\$2\"' _ -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \$*' _ -r b" "$(bash_payload "bash -c 'rm \$*' _ -r b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \"\${@}\"' x -rf b" "$(bash_payload "bash -c 'rm \"\${@}\"' x -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c '\$1 -rf b' _ rm (the verb as a parameter)" "$(bash_payload "bash -c '\$1 -rf b' _ rm")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'git \"\$@\"' _ push --force origin main" "$(bash_payload "bash -c 'git \"\$@\"' _ push --force origin main")"
test_deny  "$IRRECOVERABLE" "GH #663: sudo sh -c 'rm \"\$@\"' sh -rf b" "$(bash_payload "sudo sh -c 'rm \"\$@\"' sh -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c \"rm \\\"\\\$@\\\"\" -- -rf b (double-quoted body)" "$(bash_payload 'bash -c "rm \"\$@\"" -- -rf b')"
# slices, multi-digit and operator forms, and a leading shift
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \${@:1}' _ -rf b" "$(bash_payload "bash -c 'rm \${@:1}' _ -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \"\${@:2}\"' _ x -rf b" "$(bash_payload "bash -c 'rm \"\${@:2}\"' _ x -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \${10} \${11}' _ 1..9 -rf b" "$(bash_payload "bash -c 'rm \${10} \${11}' _ 1 2 3 4 5 6 7 8 9 -rf b")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'rm \"\${1:-}\" b' _ -rf" "$(bash_payload "bash -c 'rm \"\${1:-}\" b' _ -rf")"
test_deny  "$IRRECOVERABLE" "GH #663: bash -c 'shift; git \$1 \$2' _ x push --force" "$(bash_payload "bash -c 'shift; git \$1 \$2 origin main' _ x push --force")"
# a parameter inside a larger quoted string is text (a message), and one in single quotes never expands
test_allow "$IRRECOVERABLE" "GH #663 control: git commit -m \"fix: \$1\" with it's" "$(bash_payload "bash -c 'git commit -m \"fix: \$1\"' _ \"it's done\"")"
test_allow "$IRRECOVERABLE" "GH #663 control: echo \"x \$1 y\" with an arg that holds ; rm -rf" "$(bash_payload "bash -c 'echo \"x \$1 y\"' _ 'a\" ; rm -rf b ; \"'")"
test_allow "$IRRECOVERABLE" "GH #663 control: echo \"args: \$@\" with it's" "$(bash_payload "bash -c 'echo \"args: \$@\"' _ \"it's\" b")"
# the filled body is capped: 1500 "\$@" times 1500 words would be millions of words
_timed_case "GH #663: 1500 \"\$@\" x 1500 args then rm -rf b, denied in bounded time" 2 \
  "sh -c 'echo $(printf '"\$@" %.0s' $(seq 1500))' _ $(printf 'a %.0s' $(seq 1500)); rm -rf b"
# GH #663 review 2: escapes, word splitting, glued parameters, redirects, slices and operators
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'echo a\\; rm "$@"'"'"' _ -rf b (an escaped backslash ends the word)' "$(bash_payload 'sh -c '"'"'echo a\\; rm "$@"'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'echo "a\\" ; rm "$@"'"'"' _ -rf b' "$(bash_payload 'sh -c '"'"'echo "a\\" ; rm "$@"'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'x=\"; rm "$@"'"'"' _ -rf b' "$(bash_payload 'sh -c '"'"'x=\"; rm "$@"'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'$1'"'"' _ '"'"'rm -rf b'"'"' (an unquoted value is word-split)' "$(bash_payload 'sh -c '"'"'$1'"'"' _ '"'"'rm -rf b'"'"'')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'git $1 origin main'"'"' _ '"'"'push --force'"'"'' "$(bash_payload 'sh -c '"'"'git $1 origin main'"'"' _ '"'"'push --force'"'"'')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "$@">/dev/null'"'"' _ -rf b' "$(bash_payload 'sh -c '"'"'rm "$@">/dev/null'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'rm ${@: -2}'"'"' _ x -rf b' "$(bash_payload 'bash -c '"'"'rm ${@: -2}'"'"' _ x -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "${1#x}" b'"'"' _ x-rf' "$(bash_payload 'sh -c '"'"'rm "${1#x}" b'"'"' _ x-rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "${1,,}" b'"'"' _ -RF' "$(bash_payload 'sh -c '"'"'rm "${1,,}" b'"'"' _ -RF')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "${1/x/r}" b'"'"' _ -xf' "$(bash_payload 'sh -c '"'"'rm "${1/x/r}" b'"'"' _ -xf')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm -$1 b'"'"' _ rf (glued to text)' "$(bash_payload 'sh -c '"'"'rm -$1 b'"'"' _ rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'r$1 -rf b'"'"' _ m' "$(bash_payload 'sh -c '"'"'r$1 -rf b'"'"' _ m')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm $1$2 b'"'"' _ -r f' "$(bash_payload 'sh -c '"'"'rm $1$2 b'"'"' _ -r f')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "-$1" b'"'"' _ rf' "$(bash_payload 'sh -c '"'"'rm "-$1" b'"'"' _ rf')"
test_allow "$IRRECOVERABLE" 'GH #663 control: sh -c '"'"'echo $1'"'"' _ '"'"'a; rm -rf b'"'"' (a value'"'"'s ; is not a separator)' "$(bash_payload 'sh -c '"'"'echo $1'"'"' _ '"'"'a; rm -rf b'"'"'')"
test_allow "$IRRECOVERABLE" 'GH #663 control: sh -c '"'"'echo '"'"'"'"'"'"'"'"'$1'"'"'"'"'"'"'"'"''"'"' _ rm -rf (single quotes never expand)' "$(bash_payload 'sh -c '"'"'echo '"'"'"'"'"'"'"'"'$1'"'"'"'"'"'"'"'"''"'"' _ rm -rf')"
# the filled text is capped across the whole command: 20 bodies of 300 "$@" x 245 words each fill ~3 MB
_f663="$(printf '"$@" %.0s' $(seq 300))"; _a663="$(printf 'a %.0s' $(seq 245))"
_s663=""; for _i in $(seq 20); do _s663+="sh -c 'echo $_f663' _ $_a663; "; done
_timed_case 'GH #663: subagent flood of filled bodies denied in bounded time' 2 "${_s663}rm -rf b" fork
# GH #663 review 3: default words, shift past $#, ${!#}, pattern quoting, anchors, comments, $'...'
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm ${1+"$@"}'"'"' _ -rf b' "$(bash_payload 'sh -c '"'"'rm ${1+"$@"}'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm ${3:-$2} b'"'"' _ x -rf' "$(bash_payload 'sh -c '"'"'rm ${3:-$2} b'"'"' _ x -rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm ${3:-${2}} b'"'"' _ x -rf' "$(bash_payload 'sh -c '"'"'rm ${3:-${2}} b'"'"' _ x -rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'shift 3; rm $1 $2'"'"' _ -rf b (a failed shift keeps the args)' "$(bash_payload 'bash -c '"'"'shift 3; rm $1 $2'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'rm ${!#} b'"'"' _ -rf' "$(bash_payload 'bash -c '"'"'rm ${!#} b'"'"' _ -rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "${1#"x"}" b'"'"' _ x-rf' "$(bash_payload 'sh -c '"'"'rm "${1#"x"}" b'"'"' _ x-rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'rm "${1#[^x]}" b'"'"' _ a-rf' "$(bash_payload 'bash -c '"'"'rm "${1#[^x]}" b'"'"' _ a-rf')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'rm "${1/#x/-}" b'"'"' _ xrf' "$(bash_payload 'bash -c '"'"'rm "${1/#x/-}" b'"'"' _ xrf')"
_c663=$'bash -c \'echo hi # it\'"\'"\'s\nrm "$@"\' _ -rf b'
test_deny  "$IRRECOVERABLE" 'GH #663: a comment with an apostrophe before rm "$@"' "$(bash_payload "$_c663")"
test_allow "$IRRECOVERABLE" 'GH #663 control: sh -c '"'"'sh -c "echo \"\$@\"" _ "$@"'"'"' _ a b (nested forwarding)' "$(bash_payload 'sh -c '"'"'sh -c "echo \"\$@\"" _ "$@"'"'"' _ a b')"
_timed_case "GH #663: a \${1##*/} cut on a 100 KB value is read in bounded time" 2 \
  "sh -c 'echo \"\${1##*/}\"; rm -rf b' _ $(printf 'a/%.0s' $(seq 45000))"
# GH #663 review 4: comments after an expansion, backticks in quotes, glob replacements, shift forms, assignments
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'echo $9#; rm "$@"'"'"' _ -rf b ($9# is a word, not a comment)' "$(bash_payload 'sh -c '"'"'echo $9#; rm "$@"'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: a backtick in double quotes holding an apostrophe' "$(bash_payload 'sh -c '"'"'x="`echo "it'"'"'"'"'"'"'"'"'s"`"; rm "$@"'"'"' _ -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #663: sh -c '"'"'rm "${1/#*x/-}" b'"'"' _ zzxrf' "$(bash_payload 'sh -c '"'"'rm "${1/#*x/-}" b'"'"' _ zzxrf')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'git push "${1/%/-force}" origin main'"'"' _ -' "$(bash_payload 'bash -c '"'"'git push "${1/%/-force}" origin main'"'"' _ -')"
test_deny  "$IRRECOVERABLE" 'GH #663: bash -c '"'"'shift || exit; rm $1 b'"'"' _ x -rf' "$(bash_payload 'bash -c '"'"'shift || exit; rm $1 b'"'"' _ x -rf')"
test_allow "$IRRECOVERABLE" 'GH #663 control: sh -c '"'"'msg=$1; git commit -m "$msg"'"'"' _ '"'"'docs: rm -rf is replaced'"'"' (no split in an assignment)' "$(bash_payload 'sh -c '"'"'msg=$1; git commit -m "$msg"'"'"' _ '"'"'docs: rm -rf is replaced'"'"'')"
test_allow "$IRRECOVERABLE" 'GH #663 control: bash -c '"'"'f=$1; cp "$f" "$f.bak"'"'"' _ '"'"'notes rm -rf b.txt'"'"'' "$(bash_payload 'bash -c '"'"'f=$1; cp "$f" "$f.bak"'"'"' _ '"'"'notes rm -rf b.txt'"'"'')"
_timed_case "GH #663: 9000 unclosed \${ in a body are read in bounded time" 2 \
  "sh -c 'echo $(printf '\${%.0s' $(seq 9000))' _ a; rm -rf b"
_timed_case "GH #663: a \${1//a/<30000 b>} on 30000 a's is charged before it is built" 2 \
  "sh -c 'echo \"\${1//a/$(printf 'b%.0s' $(seq 30000))}\"' _ $(printf 'a%.0s' $(seq 30000)); rm -rf b"
# GH #663 review 5: a shift's glued redirects and a / replacement on a long value are read in bounded time
_timed_case "GH #663: shift with 30 glued <a redirects, then a force push outside the body" 2 \
  "bash -c 'shift$(printf '<a%.0s' $(seq 30)) x y; echo \$1' _ a; git push --force origin main"
_timed_case "GH #663: a \${1//*z/x} on a 120000-character value is bounded" 2 \
  "sh -c 'echo \"\${1//*z/x}\"' _ $(printf 'a%.0s' $(seq 120000)); git push --force origin main"
_timed_case "GH #663: a \${1/%*z/x} on a 60000-character value is bounded" 2 \
  "sh -c 'echo \"\${1/%*z/x}\"' _ $(printf 'a%.0s' $(seq 60000)); git push --force origin main"
test_allow "$IRRECOVERABLE" "GH #663 control: bash -c 'shift 2>/dev/null; ls \$1' _ a -la" "$(bash_payload "bash -c 'shift 2>/dev/null; ls \$1' _ a -la")"
test_allow "$IRRECOVERABLE" "GH #663 control: bash -c 'rm \"\$@\"' _ a.log b.log" "$(bash_payload "bash -c 'rm \"\$@\"' _ a.log b.log")"
test_allow "$IRRECOVERABLE" "GH #663 control: bash -c 'echo \"\$@\"' _ rm -rf b" "$(bash_payload "bash -c 'echo \"\$@\"' _ rm -rf b")"
test_allow "$IRRECOVERABLE" "GH #663 control: sh -c 'ls \$1' _ -la" "$(bash_payload "sh -c 'ls \$1' _ -la")"
# GH #664: a here-string or echo argument written with ANSI-C quoting is decoded before the stdin shell's body is read.
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \$'rm -rf b'" "$(bash_payload "bash <<< \$'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: sh <<< \$'rm\\x20-rf b'" "$(bash_payload "sh <<< \$'rm\\x20-rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \$'ls\\nrm -rf b'" "$(bash_payload "bash <<< \$'ls\\nrm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: zsh <<< \$\"rm -rf b\"" "$(bash_payload 'zsh <<< $"rm -rf b"')"
test_deny  "$IRRECOVERABLE" "GH #664: echo \$'rm -rf b' | sh" "$(bash_payload "echo \$'rm -rf b' | sh")"
test_deny  "$IRRECOVERABLE" "GH #664: dash <<< \$'git push --force origin main'" "$(bash_payload "dash <<< \$'git push --force origin main'")"
# an even backslash run escapes nothing, and \u, \U and \cX are decoded too (also at the top level)
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \\\\\$\"rm -rf b\"" "$(bash_payload 'bash <<< \\$"rm -rf b"')"
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \$'\\u0072m -rf b'" "$(bash_payload "bash <<< \$'\\u0072m -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \$'\\U00000072m -rf b'" "$(bash_payload "bash <<< \$'\\U00000072m -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: bash <<< \$'echo hi\\cJrm -rf b'" "$(bash_payload "bash <<< \$'echo hi\\cJrm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #664: \$'\\u0072m' -rf b (top level)" "$(bash_payload "\$'\\u0072m' -rf b")"
# \cX is X & 0x1f as bash computes it, a NUL ends the $'...' value, and a \U past U+10FFFF is empty
test_deny  "$IRRECOVERABLE" 'GH #664: bash <<< $'"'"'echo hi\c*rm -rf b'"'"' (\c* is a newline)' "$(bash_payload 'bash <<< $'"'"'echo hi\c*rm -rf b'"'"'')"
test_deny  "$IRRECOVERABLE" 'GH #664: bash <<< $'"'"'rm\c)-rf\c)b'"'"' (\c) is a tab)' "$(bash_payload 'bash <<< $'"'"'rm\c)-rf\c)b'"'"'')"
test_deny  "$IRRECOVERABLE" 'GH #664: r$'"'"'\u0000'"'"'m -rf b (a NUL ends the value)' "$(bash_payload 'r$'"'"'\u0000'"'"'m -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664: r$'"'"'\0'"'"'m -rf b' "$(bash_payload 'r$'"'"'\0'"'"'m -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664: r$'"'"'\UFFFFFFFF'"'"'m -rf b' "$(bash_payload 'r$'"'"'\UFFFFFFFF'"'"'m -rf b')"
test_allow "$IRRECOVERABLE" 'GH #664 control: echo $'"'"'\cß'"'"' (no crash)' "$(bash_payload 'echo $'"'"'\cß'"'"'')"
test_allow "$IRRECOVERABLE" 'GH #664 control: bash <<< $'"'"'echo hi\c{rm -rf b'"'"' (\c{ is ESC, not ;)' "$(bash_payload 'bash <<< $'"'"'echo hi\c{rm -rf b'"'"'')"
test_allow "$IRRECOVERABLE" "GH #664 control: echo \"\\\$\" | sh" "$(bash_payload 'echo "\$" | sh')"
# a $'...' inside double quotes is literal to that shell (the stdin shell decodes it later), and \x{HH} decodes
test_deny  "$IRRECOVERABLE" 'GH #664: bash <<< "$'"'"'\x22'"'"'; rm -rf b; #"' "$(bash_payload 'bash <<< "$'"'"'\x22'"'"'; rm -rf b; #"')"
test_deny  "$IRRECOVERABLE" 'GH #664: echo "x$'"'"'\x22'"'"'; rm -rf b; : $'"'"'\x22'"'"'" | bash' "$(bash_payload 'echo "x$'"'"'\x22'"'"'; rm -rf b; : $'"'"'\x22'"'"'" | bash')"
test_deny  "$IRRECOVERABLE" 'GH #664: echo "$'"'"'\x22'"'"'"; rm -rf b; echo "$'"'"'\x22'"'"'" (top level)' "$(bash_payload 'echo "$'"'"'\x22'"'"'"; rm -rf b; echo "$'"'"'\x22'"'"'"')"
test_deny  "$IRRECOVERABLE" 'GH #664: bash <<< $'"'"'\x{72}m -rf b'"'"'' "$(bash_payload 'bash <<< $'"'"'\x{72}m -rf b'"'"'')"
test_deny  "$IRRECOVERABLE" 'GH #664: $'"'"'\x{172}m'"'"' -rf b (top level, & 0xFF)' "$(bash_payload '$'"'"'\x{172}m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664: bash -c "$'"'"'\x72m'"'"' -rf b" (decoded when the body is read)' "$(bash_payload 'bash -c "$'"'"'\x72m'"'"' -rf b"')"
test_deny  "$IRRECOVERABLE" 'GH #664: a literal $'"'"' in "..." does not swallow a live one after it' "$(bash_payload '"$'"'"'" ; $'"'"'\x72m'"'"' -rf b')"
test_allow "$IRRECOVERABLE" 'GH #664 control: echo "$'"'"'say hi'"'"'"' "$(bash_payload 'echo "$'"'"'say hi'"'"'"')"
test_allow "$IRRECOVERABLE" "GH #664 control: bash <<< \$'echo hi'" "$(bash_payload "bash <<< \$'echo hi'")"
test_allow "$IRRECOVERABLE" "GH #664 control: grep x <<< \$'rm -rf b'" "$(bash_payload "grep x <<< \$'rm -rf b'")"
# GH #664 review 4: a $'...' the line's own shell reads is decoded wherever it sits, as develop did.
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: $(true)# is no comment' "$(bash_payload 'echo $(true)#; $'"'"'\x72m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: $((1))# is no comment' "$(bash_payload 'echo $((1))#; $'"'"'\x72m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: an escaped blank before # is no comment' "$(bash_payload 'echo a\ #; $'"'"'\x72m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: an escaped ; before # is no comment' "$(bash_payload 'echo x\;#; $'"'"'\x72m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: a line continuation before # is no comment' "$(bash_payload 'echo a\
#; $'"'"'\x72m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: octal after $(true)#' "$(bash_payload 'echo $(true)#; $'"'"'\162m'"'"' -rf b')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: git verb after $(true)#' "$(bash_payload 'echo $(true)#; git $'"'"'\x70ush'"'"' --force origin main')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 4: case ) inside $(...) inside "..."' "$(bash_payload 'echo "$(case x in x) $'"'"'\x72m'"'"' -rf b;; esac)"')"
test_allow "$IRRECOVERABLE" 'GH #664 review 4 control: \x{} is a NUL that ends the value' "$(bash_payload 'bash <<< $'"'"'\x{}\nrm -rf b'"'"'')"
test_allow "$IRRECOVERABLE" 'GH #664 review 4 control: \U past U+10FFFF spells no verb' "$(bash_payload '$'"'"'\U110000a'"'"'rm -rf b')"
# GH #664 review 5: a decoded " \ $ or backtick in "..." is escaped there, not left undecoded.
test_deny  "$IRRECOVERABLE" 'GH #664 review 5: a nested shell'"'"'s eval of \$'"'"'...'"'"' whose text holds a $' "$(bash_payload 'sh -c "eval \$'"'"'\x72m -rf b \x24x'"'"'"')"
test_deny  "$IRRECOVERABLE" 'GH #664 review 5: a nested shell'"'"'s eval of \$'"'"'...'"'"' whose text holds a "' "$(bash_payload 'sh -c "eval \$'"'"'\x72m -rf b \x22'"'"'"')"
test_allow "$IRRECOVERABLE" 'GH #664 review 5 control: a decoded " inside $(case) in "..."' "$(bash_payload 'echo "$(case x in x) echo $'"'"'a\x22b'"'"';; esac)"')"

# GH #693: a $(...)/backtick in the word of a ${...} (default, pattern, subscript, offset) runs, and a bash 5.3
# funsub/valsub (`${ cmd; }`, `${| cmd; }`) is a command; the ${...} body was never read.
_p693=('echo ${x:-$(@V@)}' 'echo ${x-$(@V@)}' 'echo ${x:=$(@V@)}' 'echo ${x:?$(@V@)}' 'echo ${x:+$(@V@)}'
  'echo ${x#$(@V@)}' 'echo ${x##$(@V@)}' 'echo ${x%$(@V@)}' 'echo ${x%%$(@V@)}' ': ${x/$(@V@)/}'
  ': ${x//$(@V@)/y}' 'echo ${x[$(@V@)]}' 'echo ${x:$(@V@)}' 'echo ${x:0:$(@V@)}' 'echo "${x:-$(@V@)}"'
  'echo ${x:-`@V@`}' 'echo ${x:-${y:-$(@V@)}}' 'x=${x:-$(@V@)}' 'echo ${x:-a #$(@V@)}'
  "echo \"\${x:-'\$(@V@)'}\"" 'echo ${ @V@; }' 'echo ${| @V@; }' 'echo ${ echo $(@V@); }'
  'echo ${ echo `@V@`; }'
  # a quoted word holding "}" is not the funsub's closer (the quote-blind closer cut the body there)
  "echo \${ echo 'a}'; @V@; }" 'echo ${ echo "a}"; @V@; }' "echo \${| REPLY='a}'; @V@; }"
  "echo \${ echo 'a}'; }; @V@")
for _v in 'rm -rf ~/x' 'git push --force origin main'; do
  for _t in "${_p693[@]}"; do
    _c=${_t//@V@/"$_v"}
    test_deny "$IRRECOVERABLE" "GH #693: $_c" "$(bash_payload "$_c")"
  done
done
for _c in 'ls ${HOME:-/tmp}' 'echo ${x:-$(date)}' 'echo "${x:-$(date)}"' 'echo ${x//a/b}' 'echo ${#x}' \
  'echo ${PWD##*/}' 'echo ${1:?usage}' 'cmd ${var:+--flag}' 'printf %s "${arr[@]}"' 'echo $((1+$(date +%s)))' \
  'echo ${x:-$(rm --help)}' 'echo "${HOME}/rm -rf"' 'echo ${ date; }' 'echo ${x:- default}' \
  "echo '\${x:-\$(rm -rf ~/x)}'" 'echo ${x:-\$(rm -rf ~/x)}' "echo \${ echo 'a}'; }; echo \"\$PWD\"" \
  "echo \${ printf '%s}' x; }; echo \"\$PWD\""; do
  test_allow "$IRRECOVERABLE" "GH #693 control: $_c" "$(bash_payload "$_c")"
done
_timed_case 'GH #693: 10000 ${x:-$(date)} words are read in bounded time' 0 \
  "echo $(printf '${x:-$(date)} %.0s' $(seq 10000))"
_timed_case 'GH #693: a ${x:-$(rm -rf ~/x)} target before 9000 padding words denies in bounded time' 2 \
  "echo \${x:-\$(rm -rf ~/x)} $(printf '${x:-$(date)} %.0s' $(seq 9000))"
_timed_case 'GH #693: a ${x:-$(rm -rf ~/x)} target after 9000 padding words denies in bounded time' 2 \
  "echo $(printf '${x:-$(date)} %.0s' $(seq 9000)) \${x:-\$(rm -rf ~/x)}"
_timed_case 'GH #693: a flood of unclosed ${ is read in bounded time' 2 \
  "echo $(printf '${x:-a %.0s' $(seq 20000))"
# each nested funsub level appends its body blanked, not raw, so nested text is not read once per level.
# GH #761: timed against one funsub around the same words, not a fixed 4 s. GH #800: 7750 words took ~2.2 s
# and asked at the 4 s deadline under load; at 4000 (32 KB) the fixed gate takes ~1.1 s at ~2.4x and raw
# bodies ~3 s at 5.4-7.7x on a 4-core host, so the regression fails the ratio before the deadline.
_timed_ratio_case 'GH #693: 12 nested funsubs around 32 KB of words run within the gate'"'"'s deadline and 4x one funsub' 0 4 \
  "echo \${ echo $(printf "'a}' x; %.0s" $(seq 4000)); }" \
  "echo $(printf '${ echo %.0s' $(seq 12))$(printf "'a}' x; %.0s" $(seq 4000))$(printf '; }%.0s' $(seq 12))"

# GH #702: the ${...} closer counted every "{" and ignored quotes, escapes and nested $(...)/backtick, so it
# ended the word before bash (a "}" in a nested substitution) or after it (a "\{", a bare "{"), and a "#"
# comment in a funsub or <(...) held a closer bash skips. bash 5.3 runs @V@ in each.
_N=$'\n'
_p702=('echo ${x:-$(@V@; echo })}' 'echo ${x:-`@V@; echo }`}' 'echo "${x:-$(@V@; echo })}"'
  'echo ${x:-"$(@V@; echo })"}' "echo \${x:-\${ echo 'a}'; @V@; }}" "echo \"\${x:-\${ echo 'a}'; @V@; }}\""
  "echo \${ : # }'$_N@V@$_N: # '$_N}" "cat <( : # )'$_N@V@$_N: # '$_N)"
  "echo \${x:-\\{}$_N@V@${_N}echo }" "echo \"\${x:-\\{}\"$_N@V@${_N}echo }" "echo \${x:-{}$_N@V@${_N}echo }"
  "echo \${x:-\`echo {\`}$_N@V@${_N}echo }" "echo \${x:-\$'\\{'}$_N@V@${_N}echo }"
  "echo \"\${x:-'{'}\"$_N@V@${_N}echo }" "echo \${x:-\${y:-\\{}}$_N@V@${_N}echo }"
  # a plain "..." is let through only when it ends the gate's word early; a "{" in one still denies
  "echo \${x:-\"a{\"}$_N@V@${_N}echo }" 'echo ${x:-"a}"}; @V@'
  # already denied before #702; kept so the new closer cannot lose them
  'echo ${x:-$(case a in a) @V@; echo };; esac)}' 'echo ${x:-$(case a in a) echo };; esac; @V@)}'
  "echo \${x:-\$(cat <<E$_N})${_N}E$_N@V@)}" "echo \${x:-'a}'}$_N@V@" "echo \"\${x:-'a}'}\"$_N@V@")
for _v in 'rm -rf ~/x' 'git push --force origin main'; do
  for _t in "${_p702[@]}"; do
    _c=${_t//@V@/"$_v"}
    test_deny "$IRRECOVERABLE" "GH #702: $_c" "$(bash_payload "$_c")"
  done
done
for _c in 'echo ${x//\"/}' 'echo ${x:-"a b"}' "echo \${x:-'a b'}" 'echo ${x:-$(echo "a b")}' 'echo ${x:-`date`}' \
  'echo ${x:-${y:-z}}' 'echo ${x:-$((1+2))}' 'echo ${arr[$i]}' 'echo "${x:-$(date +%s)}"' 'echo ${x/#\//}' \
  "echo \${ echo x # note$_N}" "cat <(echo a # note$_N)" 'echo ${x:-$(echo "}")}' "echo \${x:-\$(echo '}')}" 'echo ${y:-"a}b"}'; do
  test_allow "$IRRECOVERABLE" "GH #702 control: $_c" "$(bash_payload "$_c")"
done
# the funsub body's odd quote comes from the inner word's wrong close, so that reason is the one shown
test_deny_says "$IRRECOVERABLE" "GH #702: a funsub holding \${x:-'a}'} names the \${...} word, not the depth budget" \
  "$(bash_payload "echo \${ echo \${x:-'a}'}; }")" "ends at a different place" "depth-scan budget"
test_deny_says "$IRRECOVERABLE" "GH #702: a bash -c body keeps the \${...} word reason" \
  "$(bash_payload "bash -c 'echo \${x:-\\{}${_N}rm -rf ~/x${_N}echo }'")" "ends at a different place" "depth-scan budget"
_timed_case 'GH #702: a ${x:-\{} target before 9000 padding words denies in bounded time' 2 \
  "echo \${x:-\\{}$_N$(printf '${x:-a} %.0s' $(seq 9000))"
_timed_case 'GH #702: a ${x:-\{} target after 9000 padding words denies in bounded time' 2 \
  "echo $(printf '${x:-a} %.0s' $(seq 9000))\${x:-\\{}"
_timed_case 'GH #702: 10000 ${y:-"a}b"} words (the plain-quote exemption) are read in bounded time' 0 \
  "echo $(printf '${y:-"a}b"} %.0s' $(seq 10000))"

# GH #676: chroot, taskset, unshare, nsenter, chpst and setuidgid run the command after their own options
# and positionals (chroot NEWROOT, taskset's mask, setuidgid's account). Option syntax checked on util-linux
# 2.39 / coreutils 9.4 (live), runit 2.1.2's chpst getopt string and daemontools 0.76's setuidgid (man pages).
test_deny  "$IRRECOVERABLE" "GH #676: chroot / rm -rf b" "$(bash_payload 'chroot / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: taskset 1 rm -rf b" "$(bash_payload 'taskset 1 rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare rm -rf b" "$(bash_payload 'unshare rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -t 1 rm -rf b" "$(bash_payload 'nsenter -t 1 rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chpst -u x rm -rf b" "$(bash_payload 'chpst -u x rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: setuidgid x rm -rf b" "$(bash_payload 'setuidgid x rm -rf b')"
# value options, attached or as the next word, and `--`
test_deny  "$IRRECOVERABLE" "GH #676: chroot --userspec u:g / rm -rf b" "$(bash_payload 'chroot --userspec u:g / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chroot --groups=g --skip-chdir / rm -rf b" "$(bash_payload 'chroot --groups=g --skip-chdir / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chroot -- / rm -rf b" "$(bash_payload 'chroot -- / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: taskset -c 0-3 rm -rf b" "$(bash_payload 'taskset -c 0-3 rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: taskset -a 0x3 rm -rf b" "$(bash_payload 'taskset -a 0x3 rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare -S 0 -G 0 rm -rf b" "$(bash_payload 'unshare -S 0 -G 0 rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare -R /x -w /y rm -rf b" "$(bash_payload 'unshare -R /x -w /y rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare --map-user 0 --setgroups deny rm -rf b" "$(bash_payload 'unshare --map-user 0 --setgroups deny rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare -m -f --mount-proc rm -rf b" "$(bash_payload 'unshare -m -f --mount-proc rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -t 1 -m -u -i -n -p rm -rf b" "$(bash_payload 'nsenter -t 1 -m -u -i -n -p rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -S 0 -G 0 -W/x -t 1 rm -rf b" "$(bash_payload 'nsenter -S 0 -G 0 -W/x -t 1 rm -rf b')"
# nsenter's -W, like -m -r -w, takes an optional value that must be attached: `-W cmd` runs cmd
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -W rm -rf b" "$(bash_payload 'nsenter -W rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -t 1 --wdns rm -rf b" "$(bash_payload 'nsenter -t 1 --wdns rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter --wdns=/x -t 1 rm -rf b" "$(bash_payload 'nsenter --wdns=/x -t 1 rm -rf b')"
# an attached optional value is part of its flag word (nsenter's m u i n p C U T r w W are "::"), however
# it ends: `-m/proc/1/ns/mnt` is -m with that path, not -t. Bundled clusters are GH #709.
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -m/proc/1/ns/mnt rm -rf b" "$(bash_payload 'nsenter -m/proc/1/ns/mnt rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -n/proc/1/ns/net rm -rf b" "$(bash_payload 'nsenter -n/proc/1/ns/net rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -t 1 -m/proc/1/ns/mnt sh -c 'rm -rf b'" "$(bash_payload "nsenter -t 1 -m/proc/1/ns/mnt sh -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -t 1 -r/mnt rm -rf b" "$(bash_payload 'nsenter -t 1 -r/mnt rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter -rS rm -rf b" "$(bash_payload 'nsenter -rS rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: unshare -fw/x rm -rf b" "$(bash_payload 'unshare -fw/x rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: subagent: nsenter -m/proc/1/ns/mnt claude -p x" "$(bash_agent_payload 'nsenter -m/proc/1/ns/mnt claude -p x' fork)"
test_deny  "$IRRECOVERABLE" "GH #676: nsenter --target 1 -r -w rm -rf b" "$(bash_payload 'nsenter --target 1 -r -w rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chpst -u x -/ /r -b y rm -rf b" "$(bash_payload 'chpst -u x -/ /r -b y rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chpst -v -P -n 5 rm -rf b" "$(bash_payload 'chpst -v -P -n 5 rm -rf b')"
# nested, behind another wrapper or a path, and the other rules and shell bodies through them
test_deny  "$IRRECOVERABLE" "GH #676: busybox chroot / rm -rf b" "$(bash_payload 'busybox chroot / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: sudo chroot / rm -rf b" "$(bash_payload 'sudo chroot / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: /usr/sbin/chroot / rm -rf b" "$(bash_payload '/usr/sbin/chroot / rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: taskset 1 setuidgid x rm -rf b" "$(bash_payload 'taskset 1 setuidgid x rm -rf b')"
test_deny  "$IRRECOVERABLE" "GH #676: chroot / bash -c 'rm -rf b'" "$(bash_payload "chroot / bash -c 'rm -rf b'")"
test_deny  "$IRRECOVERABLE" "GH #676: unshare dd of=/dev/sda" "$(bash_payload 'unshare dd if=/dev/zero of=/dev/sda')"
test_deny  "$IRRECOVERABLE" "GH #676: subagent: taskset 1 claude -p x" "$(bash_agent_payload 'taskset 1 claude -p x' fork)"
test_allow "$IRRECOVERABLE" "GH #676 control: chroot /srv/root ls" "$(bash_payload 'chroot /srv/root ls')"
test_allow "$IRRECOVERABLE" "GH #676 control: chroot /srv/root (a shell, no command)" "$(bash_payload 'chroot /srv/root')"
test_allow "$IRRECOVERABLE" "GH #676 control: taskset -p 700" "$(bash_payload 'taskset -p 700')"
test_allow "$IRRECOVERABLE" "GH #676 control: taskset -c 0 make -j4" "$(bash_payload 'taskset -c 0 make -j4')"
test_allow "$IRRECOVERABLE" "GH #676 control: unshare -r id" "$(bash_payload 'unshare -r id')"
test_allow "$IRRECOVERABLE" "GH #676 control: nsenter -t 1 -n ip addr" "$(bash_payload 'nsenter -t 1 -n ip addr')"
test_allow "$IRRECOVERABLE" "GH #676 control: nsenter -W ls" "$(bash_payload 'nsenter -W ls')"
test_allow "$IRRECOVERABLE" "GH #676 control: chpst -u www ls" "$(bash_payload 'chpst -u www ls')"
test_allow "$IRRECOVERABLE" "GH #676 control: setuidgid www ls -la" "$(bash_payload 'setuidgid www ls -la')"
test_allow "$IRRECOVERABLE" "GH #676 control: echo chroot / rm -rf b" "$(bash_payload 'echo chroot / rm -rf b')"

# GH #690: brace-view's expanded text is also read with the ifs-split and subst-literal rewrites applied.
test_deny  "$IRRECOVERABLE" 'GH #690: r{m,m}${IFS}-rf b' "$(bash_payload 'r{m,m}${IFS}-rf b')"
test_deny  "$IRRECOVERABLE" 'GH #690: rm${IFS}--{r,f} b' "$(bash_payload 'rm${IFS}--{r,f} b')"
test_deny  "$IRRECOVERABLE" 'GH #690: rm --{r,f}${IFS}b' "$(bash_payload 'rm --{r,f}${IFS}b')"
test_deny  "$IRRECOVERABLE" 'GH #690: rm $(echo --{r,f}) b' "$(bash_payload 'rm $(echo --{r,f}) b')"
test_deny  "$IRRECOVERABLE" 'GH #690: rm `echo --{r,f}` b' "$(bash_payload 'rm `echo --{r,f}` b')"
test_deny  "$IRRECOVERABLE" 'GH #690: r{m,m}${IFS}$(echo -{r,f}) b' "$(bash_payload 'r{m,m}${IFS}$(echo -{r,f}) b')"
test_deny  "$IRRECOVERABLE" 'GH #690: rm $(printf -- --{recursive,force}) b' "$(bash_payload 'rm $(printf -- --{recursive,force}) b')"
test_allow "$IRRECOVERABLE" 'GH #690 control: echo {a,b}${IFS}x; ls' "$(bash_payload 'echo {a,b}${IFS}x; ls')"
test_allow "$IRRECOVERABLE" 'GH #690 control: mkdir -p {a,b}/c && echo $(echo hi)' "$(bash_payload 'mkdir -p {a,b}/c && echo $(echo hi)')"
test_allow "$IRRECOVERABLE" 'GH #690 control: rm -f {a,b}.log $(echo c.log)' "$(bash_payload 'rm -f {a,b}.log $(echo c.log)')"
# The composed copies run on ~63 KB of brace text here; develop allows the second row, so it proves they ran.
_timed_case 'GH #690: 3000 {a,b}${IFS}$(echo c) words are read in bounded time' 0 \
  "echo $(printf '{a,b}${IFS}$(echo c) %.0s' $(seq 3000))"
_timed_case 'GH #690: r{m,m}${IFS}-rf after 3000 brace words denies in bounded time' 2 \
  "echo $(printf '{a,b}${IFS}$(echo c) %.0s' $(seq 3000)); r{m,m}\${IFS}-rf b"

# GH #713: the $(...) closer had no comment state, so a commented ")" ended it before bash and the "'" in the
# comment hid the rest; and a funsub ended at any "}", where bash ends it only at a "}" in command position,
# so a "}" argument inside "..." left the rest in the gate's quotes. bash 5.3 runs @V@ in each.
_p713=("echo \$( : # )'$_N@V@$_N: # '$_N)" "echo \${x:-\$( : # )'$_N@V@$_N: # '$_N)}"
  "echo \"\$( : # )'$_N@V@$_N: # '$_N)\"" "echo \$(: #)'$_N@V@$_N#'$_N)" "x=\$( : # )'$_N@V@$_N: # '$_N)"
  'echo "${ echo }; @V@; }"' 'echo "${ echo a}b; @V@; }"' 'echo "${| echo }; @V@; }"' 'x="${ echo }; @V@; }"'
  'echo "${ printf %s }; @V@; }"' 'echo "${ echo {; @V@; }"' 'echo "${ echo \;}; @V@; }"'
  # a "#" after an escaped char is mid-word, so bash closes the $(...) at the next ")"
  "echo \"\$( : \\ #)'\"$_N@V@$_N\"'$_N)\"" "echo \"\$( : \\;#)'\"$_N@V@$_N\"'$_N)\""
  "x=\"\$( : \\ #)'\"$_N@V@$_N\"'$_N)\"")
for _v in 'rm -rf ~/x' 'git push --force origin main'; do
  for _t in "${_p713[@]}"; do
    _c=${_t//@V@/"$_v"}
    test_deny "$IRRECOVERABLE" "GH #713: $_c" "$(bash_payload "$_c")"
  done
done
for _c in 'echo $(grep "#" f)' "echo \$(grep '#' f)" 'echo $(echo ${#x})' 'echo $(( 16#ff ))' \
  "echo \$(awk -F'#' '{print \$1}' f)" 'echo $(sed "s/#.*//" f)' "echo \$(git log --format='%h #%s' -1)" \
  "echo \$(ls # list$_N)" 'echo ${ echo {a,b}; }' 'echo ${ f() { echo; }; f; }' \
  'echo ${ if true; then { echo; }; fi; }' 'echo "${ echo a; }"' 'echo ${x:-${ echo a; }}' \
  'echo "${ true && { echo a; }; }"' 'echo "${ (echo a) }"' "echo \"\${ echo a$_N}\"" 'echo "${ echo a;}"' \
  'echo $(echo \ #)' 'echo "$(printf %s \ #)"' 'echo $(echo a\ #b)'; do
  test_allow "$IRRECOVERABLE" "GH #713 control: $_c" "$(bash_payload "$_c")"
done
test_deny_says "$IRRECOVERABLE" "GH #713: a funsub whose \"}\" argument ends it early names the substitution" \
  "$(bash_payload 'echo "${ echo }; rm -rf ~/x; }"')" "substitution ends at a different place"
# kept on purpose: a harmless funsub with a "}" argument over-denies (fail closed), quoted or not
test_deny_says "$IRRECOVERABLE" "GH #713: a funsub with a \"}\" argument over-denies, by design" \
  "$(bash_payload 'echo ${ echo }; }')" "substitution ends at a different place"
_timed_case 'GH #713: a commented-) $(...) target before 9000 $(echo #) words denies in bounded time' 2 \
  "echo \$( : # )'${_N}rm -rf ~/x$_N: # '$_N) $(printf '$(echo "#") %.0s' $(seq 9000))"
_timed_case 'GH #713: a commented-) $(...) target after 9000 $(echo #) words denies in bounded time' 2 \
  "echo $(printf '$(echo "#") %.0s' $(seq 9000))\$( : # )'${_N}rm -rf ~/x$_N: # '$_N)"
_timed_case 'GH #713: 10000 $(echo #) words are read in bounded time' 0 \
  "echo $(printf '$(echo "#") %.0s' $(seq 10000))"
_timed_case 'GH #713: 5000 "${ echo a; }" funsubs are read in bounded time' 0 \
  "echo $(printf '"${ echo a; }" %.0s' $(seq 5000))"

# GH #726: the same $(...) inside a ${...} word with "..." around the ${...} or inside the word: the word is read
# quote-blind, so #713's newline split (done only inside "...") never ran. bash 5.3 runs @V@ in each.
_p726=("echo \"\${x:-\$( : # )'$_N@V@$_N: # '$_N)}\"" "echo \${x:-\"\$( : # )'$_N@V@$_N: # '$_N)\"}"
  "z=\"\${x:+\$(: #)'$_N@V@$_N#'$_N)}\"" "echo \"a\${x#\$( : # )'$_N@V@$_N: # '$_N)}b\""
  "echo \${x/\"\$(: #)'$_N@V@$_N#'$_N)\"/y}" "echo \"\${x:-\${x:-\$( : # )'$_N@V@$_N: # '$_N)}}\""
  "echo \"\${x:-\$(: #)'$_N@V@$_N#'$_N)}\"")
for _v in 'rm -rf ~/x' 'git push --force origin main'; do
  for _t in "${_p726[@]}"; do
    _c=${_t//@V@/"$_v"}
    test_deny "$IRRECOVERABLE" "GH #726: $_c" "$(bash_payload "$_c")"
  done
done
for _c in "echo \"\${x:-\$(ls # list$_N)}\"" "echo \${x:-\"\$(date$_N)\"}" "echo \"\${x:-\$(echo a$_N echo b)}\""; do
  test_allow "$IRRECOVERABLE" "GH #726 control: $_c" "$(bash_payload "$_c")"
done

# GH #674: a shell reads its commands on stdin behind a wrapper, with its own wrapper options, or with its own
# -o NAME / +o NAME pairs; the echo feeding it may sit behind a wrapper or an assignment too.
for _c674 in "echo 'rm -rf b' | command -p sh" "echo 'rm -rf b' | time -p sh" "echo 'rm -rf b' | bash -o pipefail" \
  "bash -o pipefail <<< 'rm -rf b'" "echo 'rm -rf b' | nice sh" "echo 'rm -rf b' | nice -n 5 sh" \
  "echo 'rm -rf b' | timeout 5 sh" "echo 'rm -rf b' | timeout -s KILL 5 sh" "echo 'rm -rf b' | env -i sh" \
  "echo 'rm -rf b' | env -u HOME sh" "echo 'rm -rf b' | sudo -u bob sh" "echo 'rm -rf b' | dash -o errexit" \
  "echo 'rm -rf b' | bash +o histexpand" "echo 'rm -rf b' | bash -eo pipefail" "echo 'rm -rf b' | builtin command sh" \
  "echo 'rm -rf b' | FOO=1 sh" "echo 'rm -rf b' | nohup nice timeout 5 sh" \
  "echo 'rm -rf b' | nsenter -t 1 sh" "echo 'rm -rf b' | chroot / sh" "chroot / sh <<< 'rm -rf b'" \
  "echo 'rm -rf b' | unshare sh" "echo 'rm -rf b' | taskset 1 bash" "echo 'rm -rf b' | chpst -u x sh" \
  "echo 'rm -rf b' | setuidgid x sh" "echo 'rm -rf b' | flock f sh" "echo 'rm -rf b' | strace -o log sh" \
  "sudo echo 'rm -rf b' | sh" "env echo 'rm -rf b' | sh" "FOO=1 echo 'rm -rf b' | sh" \
  "timeout 5 echo 'rm -rf b' | sh" "nice -n 5 printf 'rm -rf b' | sh" "echo 'rm -rf b' | watch sh" \
  "echo 'rm -rf b' | bash -O extglob" "bash +O extglob <<< 'rm -rf b'" "echo 'rm -rf b' | timeout 5 bash -o nounset -O extglob" \
  "echo 'rm -rf b' | sudo --prompt x sh" "echo 'rm -rf b' | sudo -T 5 sh" \
  "echo 'rm -rf b' | sh 2>/dev/null" "echo 'rm -rf b' | sh 2>&1" "echo 'rm -rf b' | sh >log" "echo 'rm -rf b' | sh > log" \
  "echo 'rm -rf b' | 2>/dev/null sh" "echo 'rm -rf b' | timeout 5 sh 2>/dev/null" "echo 'rm -rf b' | sh &>log" \
  "sh 2>/dev/null <<< 'rm -rf b'"; do
  test_deny "$IRRECOVERABLE" "GH #674: $_c674" "$(bash_payload "$_c674")"
done
test_deny  "$IRRECOVERABLE" "GH #674: cat <<EOF | timeout 5 sh" "$(bash_payload $'cat <<EOF | timeout 5 sh\nrm -rf b\nEOF')"
test_deny  "$IRRECOVERABLE" "GH #674: cat <<EOF | nsenter -t 1 sh" "$(bash_payload $'cat <<EOF | nsenter -t 1 sh\nrm -rf b\nEOF')"
for _c674 in "echo 'ls' | timeout 5 sh" "echo 'rm -rf b' | bash -o pipefail x.sh" "echo 'rm -rf b' | timeout 5 sh x.sh" \
  "echo 'rm -rf b' | flock f -c ls" "echo 'rm -rf b' | sh < in.sh" "echo 'rm -rf b' | bash -O extglob x.sh" \
  "echo 'rm -rf b' | sh x.sh 2>/dev/null" "echo 'rm -rf b' | sudo -u bob cat" "echo 'rm -rf b' | nice grep rm" \
  "echo 'rm -rf b' | env -i bash -c ls" "printf 'ls\n' | nice sh"; do
  test_allow "$IRRECOVERABLE" "GH #674 control: $_c674" "$(bash_payload "$_c674")"
done

# Force-push spec v3: the WHOLE command, as one plain `git [-C P] push [opts] <remote> <src:dst>...` with no
# protected dst or lease ref, is the one allowed force push. Leases count as forced everywhere else.
for _c in 'git push -f origin HEAD:feat' 'git push --force origin HEAD:feat' 'git push origin +HEAD:feat' \
  'git push -f origin feat:refs/heads/feat' 'git push -fu origin HEAD:feat' 'git push -fq origin HEAD:feat' \
  'git push -fv origin HEAD:feat' 'git push -fn origin HEAD:feat' 'git push -f -u -q -v -n origin HEAD:feat' \
  'git push --force --set-upstream origin HEAD:feat' 'git push --force --quiet origin HEAD:feat' \
  'git push --force --verbose origin HEAD:feat' 'git push --force --dry-run origin HEAD:feat' \
  'git push --force --atomic origin HEAD:feat' 'git push --force --porcelain origin HEAD:feat' \
  'git push --force --progress origin HEAD:feat' 'git push --force --no-progress origin HEAD:feat' \
  'git push --force-with-lease origin HEAD:feat' 'git push --force-if-includes --force-with-lease origin HEAD:feat' \
  'git push --force-with-lease=feat origin HEAD:feat' 'git push --force-with-lease=feat:abc1234 origin HEAD:feat' \
  'git push --force-with-lease=refs/heads/feat:0123456789abcdef0123456789abcdef01234567 origin HEAD:feat' \
  'git -C ~/x push -f origin HEAD:feat' 'git -C ../repo push -f origin HEAD:feat' 'git -C push push -f origin HEAD:feat' \
  'git push -f origin a:feat-a +b:feat-b c:refs/heads/feat-c' 'git push -f upstream v1.2@x:feature/main' \
  'git push -f origin HEAD:mainline' 'git push -f origin HEAD:release' '  git push -f origin HEAD:feat  '; do
  test_allow "$IRRECOVERABLE" "force-push v3 strict allow: $_c" "$(bash_payload "$_c")"
done
for _d in main master develop production staging release/1.0 Main MASTER Develop refs/heads/main heads/develop \
  Refs/Heads/Staging RELEASE/x refs/heads/release/2; do
  test_deny "$IRRECOVERABLE" "force-push v3: protected dst $_d" "$(bash_payload "git push -f origin HEAD:$_d")"
done
for _c in 'git push -f origin a:feat b:main' 'git push origin +HEAD:production' 'git push --force-with-lease origin HEAD:main' \
  'git push --force-with-lease=main origin HEAD:feat' 'git push --force-with-lease=refs/heads/main:abc1234 origin HEAD:feat' \
  'git push --force-with-lease=Release/9:abcd origin HEAD:feat' 'git push --force-with-lease=main:abc origin HEAD:feat' \
  'git push -f origin a:b:feat' 'git push 2>&1 -f origin HEAD:feat' 'git push -f origin HEAD:feat &>/dev/null' \
  'git push -f origin HEAD:feat <<< x' 'git push --repo=origin -f HEAD:feat' 'echo HEAD:feat | xargs git push -f origin' \
  'legit=1 xargs git push -f origin HEAD:feat' 'git push --force-with-lease origin :/msg:main' \
  'git push --recurse-submodules=on-demand -f origin HEAD:feat' 'git push -fo ci.skip origin HEAD:feat' \
  'git push -f -o ci.skip origin HEAD:feat' 'git push --m -f origin HEAD:feat' 'git push -f git@github.com:o/r.git HEAD:feat' \
  'git push -f https://github.com/o/r HEAD:feat' 'cd $(mktemp -d) && git push -f origin HEAD:feat' \
  'git push> x -f origin HEAD:feat' 'git push -f origin HEAD:feat && echo ok' 'git push  -f origin HEAD:feat' \
  $'git push\t-f origin HEAD:feat' $'git push -f origin HEAD:feat\necho ok' 'git push -f origin "HEAD:feat"' \
  "git push -f origin 'HEAD:feat'" 'git push -f --mirror HEAD:feat' 'git push -f --all origin:feat' \
  'git push --force -u HEAD:feat' 'git -c remote.origin.push=+HEAD:main push -f origin HEAD:feat' \
  'git push --force-with-lease origin develop' 'git push --force-with-lease=main:12345 origin develop' \
  'git push --force-with-lease --force-if-includes origin develop' 'git push --force-if-includes origin feat' \
  'git push --force-with-lease origin feat' 'sudo git push -f origin HEAD:feat' 'git send-pack -f origin HEAD:feat'; do
  test_deny "$IRRECOVERABLE" "force-push v3 deny: $_c" "$(bash_payload "$_c")"
done

# GH #750: the Bash tool sources the user's shell snapshot, so oh-my-zsh's git-plugin push aliases and
# functions run `git push`. Each is read as its git push text; none gets the strict force-push allow.
for _c in 'gp -f' 'gpf' 'ggp -f' 'gpu --force' \
  'gp -f origin main' 'gpd -f origin main' 'gpf origin feat' 'gpf! origin feat' 'gpsup -f' 'gpsupf' \
  'gpv -f origin main' 'gpoat -f' 'gpod -f origin x' 'ggpush -f' 'gpu -f main' 'ggf' 'ggf feat' 'ggfl feat' \
  'ggp --force main' 'gp origin +HEAD:main' 'gp --mirror origin' 'gpod main' 'gp origin :develop' \
  'sudo gp -f origin main' 'env gp -f origin main' "sh -c 'gpf! origin feat'" 'echo x && gp -f origin main' \
  '"gp" -f origin main' 'gp -f origin HEAD:feat' 'ggp -f origin HEAD:feat' \
  'ggpnp -f' 'grename main foo' 'grename develop x' 'echo x; grename Master y' 'grename feat -f'; do
  test_deny "$IRRECOVERABLE" "GH #750 push alias: $_c" "$(bash_payload "$_c")"
done
for _c in 'gp' 'gp origin feat' 'gpu' 'ggp' 'ggp feat' 'gpsup' 'gpd origin main' 'gpv' 'ggpush' 'gpoat' \
  'gpod feat' 'gpg --verify x.sig' 'echo gp -f' 'git push origin HEAD:feat' \
  'ggpnp' 'ggpnp feat' 'grename feat x' 'grename'; do
  test_allow "$IRRECOVERABLE" "GH #750 push alias control: $_c" "$(bash_payload "$_c")"
done
# Operator 2026-10-31: #750 stays push-only, so `alias g='git'` is not read (the general alias table is #781).
# These pin that scope; #781 flips them if it widens the table.
for _c in 'g push -f origin main' 'g reset --hard' 'g>/dev/null push -f origin main'; do
  test_allow "$IRRECOVERABLE" "GH #750 scope: g is not read as git: $_c" "$(bash_payload "$_c")"
done
echo ""
echo "=== GH #771: the python gate's own deadline asks, never times out silently ==="
# "irrecoverable: ran out of time" in full, the needle of _gate_ran_out_of_time in tests/_lib/gates-harness.sh:
# _timed_case, _timed_ratio_case and _len_diag find a deadline ask by it (GH #800). This row and the _len_diag
# tag row below both fail if the gate's wording and that needle drift apart.
MH_IRR_DEADLINE_SECS=0.001 test_ask_says "$IRRECOVERABLE" "forced deadline expiry on an allowed candidate command asks, reason says time" \
  "$(bash_payload 'git status && git log -1')" "irrecoverable: ran out of time"
# _len_diag tags a deadline ask and leaves a normal run untagged (the diagnostic runs only on a failure, so
# nothing else would notice it dropping the tag).
_dl=$(MH_IRR_DEADLINE_SECS=0.001 _len_diag 'git status && git log -1' 2>&1 >/dev/null)
if [[ "$_dl" == *"(gate deadline)"* && "$_dl" == *"exit 0 in "* ]]; then
  echo "  ✅ _len_diag tags a gate-deadline rerun"; pass=$((pass + 1))
else
  echo "  ❌ _len_diag did not tag a gate-deadline rerun: $_dl" >&2; fail=$((fail + 1))
fi
# The untagged side runs a stub gate that allows at once, so host load cannot push it to the real deadline.
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$_JOURNAL_TMP/allow-gate.sh"
_dl=$(IRRECOVERABLE="$_JOURNAL_TMP/allow-gate.sh" _len_diag 'git status' 2>&1 >/dev/null)
if [[ "$_dl" == *"rerun without the 2 s limit: exit 0 in "* && "$_dl" != *"(gate deadline)"* ]]; then
  echo "  ✅ _len_diag leaves an ordinary rerun untagged"; pass=$((pass + 1))
else
  echo "  ❌ _len_diag tagged or garbled an ordinary rerun: $_dl" >&2; fail=$((fail + 1))
fi
MH_IRR_DEADLINE_SECS=0.001 test_ask "$IRRECOVERABLE" "forced deadline expiry emits exactly one ask JSON" "$(bash_payload 'git status')"
if python3 - "$ROOT/hooks/gates/irrecoverable.py" "$ROOT/hooks/hooks.json" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^DEADLINE_SECS = ([0-9.]+)", src, re.M)
hooks = [h for e in json.load(open(sys.argv[2]))["hooks"]["PreToolUse"] for h in e["hooks"]]
irr = [h for h in hooks if "irrecoverable.sh" in h["command"]]
others = [h for h in hooks if "irrecoverable.sh" not in h["command"] and "onFailure" in h]
assert m and len(irr) == 1, "constant or entry missing"
assert float(m.group(1)) <= irr[0]["timeout"] / 2, "deadline not well under the hook timeout"
assert irr[0].get("onFailure") == "block", "irrecoverable.sh lacks onFailure block"
assert not others, "onFailure set on another entry"
PY
then echo "  ✅ DEADLINE_SECS is at most half the hooks.json timeout; onFailure block on irrecoverable.sh only"; pass=$((pass + 1))
else echo "  ❌ deadline/onFailure contract broken" >&2; fail=$((fail + 1)); fi


gates_summary
