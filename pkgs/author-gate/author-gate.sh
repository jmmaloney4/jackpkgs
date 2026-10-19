# author-gate — fail if Cursor cloud-agent identity landed on a commit.
#
# A flake's copied source in /nix/store has no .git, so a *pure* derivation
# cannot see author/committer emails. Fleet merge is `nix flake check -L` in a
# git worktree: that command therefore cannot enforce this rule by itself.
# This CLI is the actual gate. Run it in the worktree (nix run, just, pre-push).
#
# Usage:
#   author-gate                  # range: merge-base(origin/<default>, HEAD)..HEAD
#   author-gate --mode ident     # GIT_AUTHOR_IDENT / GIT_COMMITTER_IDENT (commit-msg)
#   author-gate --mode head      # HEAD only (post-commit)
#   author-gate --mode range     # explicit range mode (default)
#   author-gate --base ORIGIN/BRANCH
#   author-gate --bot-email-domain bots.roomofrequirement.xyz
#   author-gate --blocked-email cursoragent@cursor.com

mode="range"
base_ref=""
bot_email_domain="${AUTHOR_GATE_BOT_EMAIL_DOMAIN:-bots.roomofrequirement.xyz}"
blocked_emails=()

usage() {
  cat <<'EOF'
Usage: author-gate [--mode ident|head|range] [--base <rev>]
                   [--bot-email-domain <domain>] [--blocked-email <email>] ...

Fails when any inspected commit has author OR committer email matching a
blocked address (default: cursoragent@cursor.com). Jack's address and any
other author are ignored unless they use a blocked email.

Range (default) is merge-base(<base>, HEAD)..HEAD where <base> is
origin/HEAD, origin/main, origin/master, main, or master.

--mode ident  consults `git var GIT_AUTHOR_IDENT` / GIT_COMMITTER_IDENT
              (commit-msg hook: the in-flight commit is not on HEAD yet).
--mode head   inspects HEAD only (post-commit).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --mode)
    mode="$2"
    shift 2
    ;;
  --mode=*)
    mode="${1#--mode=}"
    shift
    ;;
  --base)
    base_ref="$2"
    shift 2
    ;;
  --base=*)
    base_ref="${1#--base=}"
    shift
    ;;
  --bot-email-domain)
    bot_email_domain="$2"
    shift 2
    ;;
  --bot-email-domain=*)
    bot_email_domain="${1#--bot-email-domain=}"
    shift
    ;;
  --blocked-email)
    blocked_emails+=("$2")
    shift 2
    ;;
  --blocked-email=*)
    blocked_emails+=("${1#--blocked-email=}")
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "author-gate: unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
  *)
    # pre-commit commit-msg passes COMMIT_EDITMSG; ignore the path.
    if [[ -f $1 ]]; then
      shift
      continue
    fi
    echo "author-gate: unexpected argument: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
done

if [[ ${#blocked_emails[@]} -eq 0 ]]; then
  blocked_emails=("cursoragent@cursor.com")
fi

fold_email() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_blocked_email() {
  local email folded candidate
  folded="$(fold_email "$1")"
  for email in "${blocked_emails[@]}"; do
    candidate="$(fold_email "$email")"
    if [[ $folded == "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

email_from_ident() {
  # GIT_*_IDENT: "Name <email> timestamp tz"
  printf '%s' "$1" | sed -n 's/.*<\([^>]*\)>.*/\1/p'
}

require_git_worktree() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "author-gate: not a git worktree." >&2
    echo 'A flake copy in the Nix store has no .git, so a pure `nix flake check` derivation cannot see commit authors.' >&2
    echo "Run this CLI from the checkout (the fleet worktree), e.g.:" >&2
    echo "  nix run github:jmmaloney4/jackpkgs#author-gate" >&2
    exit 2
  fi
}

detect_base() {
  local candidate
  if [[ -n $base_ref ]]; then
    printf '%s' "$base_ref"
    return
  fi
  for candidate in origin/HEAD origin/main origin/master main master; do
    if git rev-parse --verify --quiet "$candidate" >/dev/null; then
      printf '%s' "$candidate"
      return
    fi
  done
  echo "author-gate: cannot determine default branch (tried origin/HEAD, origin/main, origin/master, main, master)." >&2
  echo "Pass --base <rev> explicitly." >&2
  exit 2
}

print_fix() {
  local merge_base="$1"
  local domain="$bot_email_domain"
  echo >&2
  echo "Cursor cloud agents must not land as Cursor Agent <cursoragent@cursor.com>." >&2
  echo 'Rewrite each offending commit from its `Bot: <name> (<Title>)` trailer' >&2
  echo '(matchers key on the email or the bare name before ` (`; do not drop the' >&2
  echo "title suffix). Email is <name>@${domain} (Cavins: bots.cavinsresearch.io)." >&2
  echo >&2
  echo "  git rebase --exec 'trailer=\$(git log -1 --pretty=\"%(trailers:key=Bot,valueonly)\"); if [ -z \"\$trailer\" ]; then echo \"author-gate fix: missing Bot: trailer\" >&2; exit 1; fi; name=\${trailer%% (*}; email=\"\${name}@${domain}\"; export GIT_COMMITTER_NAME=\"\$trailer\" GIT_COMMITTER_EMAIL=\"\$email\"; git commit --amend --no-edit --author=\"\$trailer <\$email>\"' ${merge_base}" >&2
  echo >&2
  echo "Then verify: nix run github:jmmaloney4/jackpkgs#author-gate" >&2
}

print_ident_fix() {
  local domain="$bot_email_domain"
  echo >&2
  echo "Cursor cloud agents must not land as Cursor Agent <cursoragent@cursor.com>." >&2
  echo "This is --mode ident (commit-msg): the commit is not on HEAD yet, so a" >&2
  echo "rebase --exec over HEAD would replay nothing. Fix the identity, then re-commit." >&2
  echo >&2
  echo "Preferred: persist the bot identity with git-bot-identity (writes --local" >&2
  echo "user.name / user.email from GROKBOT_GIT_NAME / GROKBOT_GIT_EMAIL):" >&2
  echo "  export GROKBOT_GIT_NAME='<name> (<Title>)' GROKBOT_GIT_EMAIL='<name>@${domain}'" >&2
  echo "  nix run github:jmmaloney4/jackpkgs#git-bot-identity" >&2
  echo >&2
  echo "Or set identity for this commit only (do not run unscoped git config user.*" >&2
  echo "— linked worktrees share .git/config):" >&2
  echo "  export GIT_AUTHOR_NAME='<name> (<Title>)' GIT_AUTHOR_EMAIL='<name>@${domain}' \\" >&2
  echo "         GIT_COMMITTER_NAME='<name> (<Title>)' GIT_COMMITTER_EMAIL='<name>@${domain}'" >&2
  echo "  git -c user.name='<name> (<Title>)' -c user.email='<name>@${domain}' commit ..." >&2
}

is_all_zeros_sha() {
  local ref="$1"
  [[ $ref =~ ^0+$ ]] && { [[ ${#ref} -eq 40 || ${#ref} -eq 64 ]]; }
}

# Pre-push supplies PRE_COMMIT_FROM_REF..PRE_COMMIT_TO_REF. Trust that range
# only when from-ref is a real local commit. All-zeros (new branch) and any
# sha missing locally used to make `git rev-list` fail, which the empty-range
# check swallowed as a pass — skip the gate on the agent-pushes-new-branch case.
pre_commit_from_ref_usable() {
  local from="$1"
  if [[ -z $from ]] || is_all_zeros_sha "$from"; then
    return 1
  fi
  git rev-parse --verify --quiet "${from}^{commit}" >/dev/null
}

report_and_fail() {
  local merge_base="$1"
  shift
  echo "author-gate: blocked commit(s) with author or committer email matching:" >&2
  local email
  for email in "${blocked_emails[@]}"; do
    echo "  - ${email}" >&2
  done
  echo >&2
  printf '%s\n' "$@" >&2
  print_fix "$merge_base"
  exit 1
}

check_pair() {
  local sha="$1" ae="$2" ce="$3" an="$4" cn="$5"
  local reasons=()
  if is_blocked_email "$ae"; then
    reasons+=("author=${an} <${ae}>")
  fi
  if is_blocked_email "$ce"; then
    reasons+=("committer=${cn} <${ce}>")
  fi
  if [[ ${#reasons[@]} -gt 0 ]]; then
    local joined
    joined=$(
      IFS=', '
      echo "${reasons[*]}"
    )
    echo "${sha}  ${joined}"
  fi
}

require_git_worktree

case "$mode" in
ident)
  author_ident="$(git var GIT_AUTHOR_IDENT)"
  committer_ident="$(git var GIT_COMMITTER_IDENT)"
  ae="$(email_from_ident "$author_ident")"
  ce="$(email_from_ident "$committer_ident")"
  hits=()
  if is_blocked_email "$ae"; then
    hits+=("ident  author=${author_ident}")
  fi
  if is_blocked_email "$ce"; then
    hits+=("ident  committer=${committer_ident}")
  fi
  if [[ ${#hits[@]} -gt 0 ]]; then
    echo "author-gate: blocked commit(s) with author or committer email matching:" >&2
    for email in "${blocked_emails[@]}"; do
      echo "  - ${email}" >&2
    done
    echo >&2
    printf '%s\n' "${hits[@]}" >&2
    print_ident_fix
    exit 1
  fi
  exit 0
  ;;
head)
  sha="$(git rev-parse --short HEAD)"
  ae="$(git log -1 --format='%ae')"
  ce="$(git log -1 --format='%ce')"
  an="$(git log -1 --format='%an')"
  cn="$(git log -1 --format='%cn')"
  line="$(check_pair "$sha" "$ae" "$ce" "$an" "$cn" || true)"
  if [[ -n ${line:-} ]]; then
    report_and_fail "$(git rev-parse HEAD^ 2>/dev/null || git rev-parse HEAD)" "$line"
  fi
  exit 0
  ;;
range) ;;
*)
  echo "author-gate: unknown --mode ${mode} (expected ident, head, or range)" >&2
  exit 2
  ;;
esac

if [[ -n ${PRE_COMMIT_FROM_REF:-} && -n ${PRE_COMMIT_TO_REF:-} ]] &&
  pre_commit_from_ref_usable "$PRE_COMMIT_FROM_REF"; then
  range="${PRE_COMMIT_FROM_REF}..${PRE_COMMIT_TO_REF}"
  merge_base="$PRE_COMMIT_FROM_REF"
else
  base="$(detect_base)"
  if ! merge_base="$(git merge-base "$base" HEAD 2>/dev/null)"; then
    if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" == "true" ]]; then
      echo "author-gate: shallow clone does not contain merge-base with ${base}." >&2
      echo "Unshallow so the gate can see the branch range:" >&2
      echo "  git fetch --unshallow" >&2
      echo "  git fetch --deepen=100" >&2
      exit 2
    fi
    echo "author-gate: cannot compute merge-base(${base}, HEAD)." >&2
    exit 2
  fi
  range="${merge_base}..HEAD"
fi

# Empty range (HEAD is the default branch, or nothing to push): pass.
# A failed rev-list is not empty — do not swallow it as a pass.
rev_list_status=0
rev_list_sample="$(git rev-list --max-count=1 "$range" 2>/dev/null)" || rev_list_status=$?
if [[ $rev_list_status -ne 0 ]]; then
  echo "author-gate: cannot list commits in range ${range} (git rev-list exited ${rev_list_status})." >&2
  echo "Fetch the missing ref or pass --base <rev>." >&2
  exit 2
fi
if [[ -z $rev_list_sample ]]; then
  exit 0
fi

hits=()
while
  IFS= read -r sha &&
    IFS= read -r ae &&
    IFS= read -r ce &&
    IFS= read -r an &&
    IFS= read -r cn
do
  line="$(check_pair "$sha" "$ae" "$ce" "$an" "$cn" || true)"
  if [[ -n ${line:-} ]]; then
    hits+=("$line")
  fi
done < <(git -c log.showSignature=false log --format='%h%n%ae%n%ce%n%an%n%cn' "$range")

if [[ ${#hits[@]} -gt 0 ]]; then
  report_and_fail "$merge_base" "${hits[@]}"
fi
