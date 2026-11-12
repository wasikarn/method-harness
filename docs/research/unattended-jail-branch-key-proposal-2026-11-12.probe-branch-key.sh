#!/usr/bin/env bash
# probe-branch-key.sh: live test of the "jail with a branch key" design (proposal version 4)
# against a THROWAWAY GitHub repository. It answers the facts no paper review could:
# what a write deploy key can and cannot push under a ruleset, and whether the freeze works.
#
# Status (2026-11-12): written for the proposal in
# unattended-jail-branch-key-proposal-2026-11-12.md and dry-run only
# against a local bare repository with stub `gh` and `ssh`. It has NOT been run against GitHub;
# the ruleset JSON in setup() was written from memory of the REST API and may need correcting.
#
# Run it on your own machine, with your own `gh` login. It never touches method-harness:
# it refuses any repository whose name contains "method-harness".
#
#   bash <this file> setup  <owner>/<test-repo>   # creates the repo, ruleset, deploy key
#   bash <this file> probe  <owner>/<test-repo>   # runs the probes, writes results.md
#   bash <this file> revoke <owner>/<test-repo>   # deletes the key, checks a push now fails
#
# Needs: git 2.29+, ssh, ssh-keygen, gh (logged in as the repo owner), jq.
# Everything it creates locally (the private deploy key, the clones, results.md) lives under
# $PROBE_BRANCH_KEY_DIR, default ~/.cache/mh/branch-key-probe: outside the repository, so the key
# cannot be committed. The path must not contain spaces (it goes into GIT_SSH_COMMAND unquoted).
# Delete the test repository yourself when done (Settings, Danger zone).
set -uo pipefail

cmd="${1:-}"; repo="${2:-}"
work="${PROBE_BRANCH_KEY_DIR:-$HOME/.cache/mh/branch-key-probe}"
key="$work/deploy_key"
out="$work/results.md"

die() { echo "probe-branch-key: $*" >&2; exit 1; }
case "$repo" in
  */*) ;;
  *) die "usage: $0 setup|probe|revoke <owner>/<test-repo>" ;;
esac
case "$repo" in *method-harness*) die "refusing to run against $repo: use a throwaway repository" ;; esac
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "odd repository name: $repo"
case "$work" in *[[:space:]]*) die "work dir has a space in it: $work (set PROBE_BRANCH_KEY_DIR)" ;; esac
for t in git ssh ssh-keygen gh jq; do command -v "$t" >/dev/null || die "$t not found"; done
ssh_url="git@github.com:$repo.git"
# The deploy key only: no agent, no other identity, no user ssh config.
export GIT_SSH_COMMAND="ssh -F /dev/null -i $key -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$work/known_hosts"
export GIT_TERMINAL_PROMPT=0

row() { printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" >>"$out"; }
# try <id> <expected ALLOW|DENY|RECORD> <description> <command...>: runs it, records the outcome
try() {
  local id="$1" want="$2" desc="$3"; shift 3
  local log; log="$("$@" 2>&1)"; local rc=$?
  local got="DENY"; [ "$rc" -eq 0 ] && got="ALLOW"
  local verdict="as expected"
  [ "$want" = RECORD ] && verdict="recorded"
  [ "$want" != RECORD ] && [ "$want" != "$got" ] && verdict="**UNEXPECTED**"
  local tail1; tail1="$(printf '%s' "$log" | tr '\n|' ' /' | cut -c1-140)"
  row "$id" "$desc" "$got ($verdict; wanted $want)" "$tail1"
  echo "$id: $got ($verdict) $desc"
}

setup() {
  mkdir -p "$work"
  gh repo view "$repo" >/dev/null 2>&1 && die "$repo already exists: pick a new name or delete it first"
  echo "creating public repository $repo"
  gh repo create "$repo" --public --add-readme --description "throwaway: branch-key experiment" >/dev/null || die "gh repo create failed"
  local tmp="$work/seed"; mkdir -p "$tmp"
  gh repo clone "$repo" "$tmp" -- -q || die "clone failed"
  git -C "$tmp" checkout -q -b develop && git -C "$tmp" push -q origin develop || die "push develop failed"
  git -C "$tmp" checkout -q -b claude/existing && git -C "$tmp" push -q origin claude/existing || die "push claude/existing failed"
  gh api -X PATCH "repos/$repo" -f default_branch=develop >/dev/null || die "could not set default branch"
  echo "disabling Actions"
  gh api -X PUT "repos/$repo/actions/permissions" -F enabled=false >/dev/null || echo "WARNING: could not disable Actions; do it in Settings, Actions" >&2
  echo "creating rulesets (admin role id 5 is the only bypass actor)"
  jq -n '{name:"only agent/** is writable", target:"branch", enforcement:"active",
          bypass_actors:[{actor_id:5, actor_type:"RepositoryRole", bypass_mode:"always"}],
          conditions:{ref_name:{include:["~ALL"], exclude:["refs/heads/agent/**"]}},
          rules:[{type:"creation"},{type:"update"},{type:"deletion"}]}' |
    gh api -X POST "repos/$repo/rulesets" --input - >/dev/null || die "branch ruleset failed (is the repo public? rulesets on Free need a public repo)"
  jq -n '{name:"no tags", target:"tag", enforcement:"active",
          bypass_actors:[{actor_id:5, actor_type:"RepositoryRole", bypass_mode:"always"}],
          conditions:{ref_name:{include:["~ALL"], exclude:[]}},
          rules:[{type:"creation"},{type:"update"},{type:"deletion"}]}' |
    gh api -X POST "repos/$repo/rulesets" --input - >/dev/null || die "tag ruleset failed"
  echo "creating a write deploy key"
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C "branch-key-experiment" -f "$key"
  gh repo deploy-key add "$key.pub" -R "$repo" --allow-write --title branch-key-experiment >/dev/null || die "deploy key add failed"
  echo "setup done. Next: $0 probe $repo"
}

probe() {
  [ -f "$key" ] || die "no key at $key: run setup first"
  : >"$out"
  {
    echo "# Branch-key experiment results"
    echo
    echo "Repository: \`$repo\`. Date: $(date -u +%Y-%m-%dT%H:%MZ). git $(git --version | cut -d' ' -f3)."
    echo
    echo "| id | what | outcome | last output |"
    echo "|---|---|---|---|"
  } >>"$out"
  local w="$work/jail-clone"; [ -d "$w" ] && die "$w exists from an earlier run: move it away first"
  git clone -q "$ssh_url" "$w" || die "clone with the deploy key failed"
  git -C "$w" config user.name "agent"; git -C "$w" config user.email "agent@example.invalid"
  c() { git -C "$w" "$@"; }
  commit() { echo "$1 $(date +%s%N)" >>"$w/note.txt"; c add note.txt; c commit -q -m "$1"; }
  c checkout -q -B work origin/develop

  # --- what the key may do ---
  commit "agent work 1"
  try K1 ALLOW "push agent/t1" git -C "$w" push origin HEAD:refs/heads/agent/t1
  local first; first="$(c rev-parse HEAD)"
  c reset -q --hard origin/develop; commit "agent work rewritten"
  try K2 ALLOW "force-push agent/t1 (the one form mh's gate allows)" git -C "$w" push --force-with-lease origin HEAD:refs/heads/agent/t1
  local tip; tip="$(c rev-parse HEAD)"

  # --- what the key must not do ---
  try D1 DENY "push to develop" git -C "$w" push origin HEAD:refs/heads/develop
  try D2 DENY "create claude/new" git -C "$w" push origin HEAD:refs/heads/claude/new
  try D3 DENY "update existing claude/existing" git -C "$w" push origin HEAD:refs/heads/claude/existing
  try D4 DENY "force-update claude/existing" git -C "$w" push --force origin HEAD:refs/heads/claude/existing
  try D5 DENY "delete claude/existing" git -C "$w" push origin :refs/heads/claude/existing
  try D6 DENY "create a tag" git -C "$w" push origin HEAD:refs/tags/v9.9.9
  try D7 DENY "create feat/x" git -C "$w" push origin HEAD:refs/heads/feat/x
  try D8 DENY "create a top-level branch named agent" git -C "$w" push origin HEAD:refs/heads/agent
  try D9 DENY "nested agent/a/b (pattern is one level)" git -C "$w" push origin HEAD:refs/heads/agent/a/b
  try D10 DENY "letter case: Agent/x" git -C "$w" push origin HEAD:refs/heads/Agent/x
  try D11 DENY "letter case: AGENT/x" git -C "$w" push origin HEAD:refs/heads/AGENT/x
  try D12 DENY "agent-x (no slash)" git -C "$w" push origin HEAD:refs/heads/agent-x

  # --- refs outside branches and tags, wiki, LFS: unknown, just record ---
  try R1 RECORD "push refs/notes/x" git -C "$w" push origin HEAD:refs/notes/x
  try R2 RECORD "push refs/foo/bar" git -C "$w" push origin HEAD:refs/foo/bar
  try R3 RECORD "push refs/pull/1/head" git -C "$w" push origin HEAD:refs/pull/1/head
  try R5 RECORD "push to the wiki repository" git -C "$w" push "git@github.com:$repo.wiki.git" HEAD:refs/heads/master
  # shellcheck disable=SC2086
  try R6 RECORD "git-lfs-authenticate with the deploy key" $GIT_SSH_COMMAND git@github.com "git-lfs-authenticate $repo.git upload"

  # --- a workflow file on an agent branch, Actions disabled ---
  mkdir -p "$w/.github/workflows"
  printf 'on: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ran\n' >"$w/.github/workflows/x.yml"
  c add .github/workflows/x.yml; c commit -q -m "workflow file"
  try W1 RECORD "push agent/wf holding a workflow file" git -C "$w" push origin HEAD:refs/heads/agent/wf
  sleep "${PROBE_WAIT:-30}"
  local runs; runs="$(gh api "repos/$repo/actions/runs" --jq '.total_count' 2>&1)"
  row W2 "workflow runs 30 s after that push (want 0)" "$runs" "Actions enabled: $(gh api "repos/$repo/actions/permissions" --jq .enabled 2>&1)"
  echo "W2: workflow runs = $runs"

  # --- the owner's side ---
  try O1 ALLOW "owner freezes: create claude/agent-t1 at the agent tip by API" gh api -X POST "repos/$repo/git/refs" -f "ref=refs/heads/claude/agent-t1" -f "sha=$tip"
  try O2 DENY "key force-pushes the frozen claude/agent-t1" git -C "$w" push --force origin "$first:refs/heads/claude/agent-t1"
  try O3 DENY "key deletes the frozen claude/agent-t1" git -C "$w" push origin :refs/heads/claude/agent-t1
  try O4 RECORD "owner freezes a commit no longer on any branch (the force-pushed-away one)" gh api -X POST "repos/$repo/git/refs" -f "ref=refs/heads/claude/agent-old" -f "sha=$first"
  local cmp; cmp="$(gh api "repos/$repo/compare/develop...$tip" --jq '"total_commits=\(.total_commits) listed=\(.commits|length) files=\(.files|length) parents=\([.commits[].parents|length]|tostring) patch=\([.files[]|has("patch")]|tostring)"' 2>&1)"
  row O5 "compare API shape for develop...<tip>" "recorded" "$cmp"
  # owner pushes with the owner's own credentials (admin bypass)
  local ow="$work/owner-clone"; [ -d "$ow" ] && die "$ow exists from an earlier run: move it away first"
  (unset GIT_SSH_COMMAND; gh repo clone "$repo" "$ow" -- -q) || die "owner clone failed"
  git -C "$ow" checkout -q -b claude/owner-branch origin/develop
  try O6 ALLOW "owner pushes claude/owner-branch (admin bypass)" env -u GIT_SSH_COMMAND git -C "$ow" push -q origin claude/owner-branch
  try O7 ALLOW "owner deletes claude/owner-branch" env -u GIT_SSH_COMMAND git -C "$ow" push -q origin :claude/owner-branch
  # negative refspec: an ordinary fetch must not bring agent/* down
  git -C "$ow" config --add remote.origin.fetch '^refs/heads/agent/*'
  git -C "$ow" for-each-ref --format='%(refname)' refs/remotes/origin/agent/ | while read -r r; do git -C "$ow" update-ref -d "$r"; done
  (unset GIT_SSH_COMMAND; git -C "$ow" fetch -q origin)
  local left; left="$(git -C "$ow" for-each-ref --format='%(refname:short)' refs/remotes/origin | tr '\n' ' ')"
  row O8 "remote refs after a plain fetch with the negative refspec (want no agent/*)" "recorded" "$left"

  # --- clean-up of what the key is allowed to clean ---
  try K3 ALLOW "key deletes agent/t1" git -C "$w" push origin :refs/heads/agent/t1
  echo
  echo "wrote $out"
  echo "Any row marked UNEXPECTED is a finding. Then run: $0 revoke $repo"
}

revoke() {
  [ -f "$key" ] || die "no key at $key"
  local w="$work/jail-clone"; [ -d "$w" ] || die "run probe first"
  local id; id="$(gh api "repos/$repo/keys" --jq '.[] | select(.title=="branch-key-experiment") | .id' | head -1)"
  [ -n "$id" ] || die "deploy key not found on $repo"
  gh api -X DELETE "repos/$repo/keys/$id" >/dev/null || die "could not delete the deploy key"
  echo "x $(date +%s)" >>"$w/note.txt"; git -C "$w" add note.txt; git -C "$w" commit -q -m "after revoke"
  try V1 DENY "push agent/t2 right after the key was deleted" git -C "$w" push origin HEAD:refs/heads/agent/t2
  echo "appended to $out. Delete the repository $repo yourself when you are done."
}

case "$cmd" in
  setup) setup ;;
  probe) probe ;;
  revoke) revoke ;;
  *) die "usage: $0 setup|probe|revoke <owner>/<test-repo>" ;;
esac
