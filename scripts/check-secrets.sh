#!/bin/sh
#
# check-secrets.sh — keep credentials, private IPs and machine-specific paths
# out of anything git would publish.
#
#   scripts/check-secrets.sh              scan this repo's publishable set
#   scripts/check-secrets.sh --staged     scan only what is staged for commit
#   scripts/check-secrets.sh --install    install .git/hooks/pre-commit here
#   scripts/check-secrets.sh [flags] DIR  run against another repo
#
# The publishable set is tracked files plus untracked files that are not
# gitignored — exactly what `git add -A && git commit && git push` exposes.
# Gitignored files (.env, host state) are deliberately NOT scanned: they are
# where secrets are supposed to live.
#
# The patterns are deliberately blunt. When a legitimate placeholder trips the
# check, mark the line with a trailing `secretscan:ignore` comment rather than
# weakening the rule — a rule that misses a real leak is worse than one that
# occasionally needs an exception.
#
# Exit 0 clean, 1 findings, 2 usage error. POSIX sh, no dependencies.

set -eu

PROG=$(basename "$0")

usage() {
    cat <<'EOF'
usage: check-secrets.sh [--staged] [--install] [repo-path]

  (no flags)   scan everything git would publish in the repo
  --staged     scan only staged content, for use as a pre-commit hook
  --install    write .git/hooks/pre-commit so every commit gets checked
  -h, --help   this text
EOF
}

mode=scan
repo=
for arg in "$@"; do
    case "$arg" in
        --staged)  mode=staged ;;
        --install) mode=install ;;
        -h|--help) usage; exit 0 ;;
        -*)        echo "$PROG: unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *)         repo=$arg ;;
    esac
done
[ -n "$repo" ] || repo=.

# Resolve our own path before changing directory, so --install can record an
# absolute path that keeps working from any checkout.
self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

root=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || {
    echo "$PROG: not inside a git repository: $repo" >&2
    exit 2
}
cd "$root"

# --install ------------------------------------------------------------------

if [ "$mode" = install ]; then
    hook="$root/.git/hooks/pre-commit"
    mkdir -p "$root/.git/hooks"
    cat > "$hook" <<EOF
#!/bin/sh
# Installed by $PROG. Delete this file to stop the check.
exec "$self" --staged
EOF
    chmod +x "$hook"
    echo "installed $hook -> $self --staged"
    exit 0
fi

# Patterns -------------------------------------------------------------------
#
# HARD: a match is a secret in any file, no exceptions.
HARD='(-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|ghs_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{32,}|ya29\.[A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})'
#
# SOFT: suspicious but sometimes legitimate — filtered through PLACEHOLDER.
# The marker at the end of the next statement stops the pattern table from
# matching itself; the filter is line-based, so it has to sit on that line.
SOFT='((password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret|private[_-]?key)[A-Za-z_]*[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9!@#$%^&*_.+/-]{8,}|(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)|/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/|C:/Users/[A-Za-z0-9._-]+/|/share/|/mnt/|(^|[^0-9A-Fa-f-])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}([^0-9A-Fa-f-]|$))'   # secretscan:ignore
#
# A line matching this is not reported.
PLACEHOLDER='(\$\{|\$[A-Za-z_][A-Za-z0-9_]*|CHANGEME|changeme|REPLACE|placeholder|PLACEHOLDER|your[_-]|YOUR[_-]|xxx|XXX|<[A-Za-z_][A-Za-z0-9_ .-]*>|secretscan:ignore|example\.(com|org|net|invalid)|test@|fake_|dummy)'

# File list ------------------------------------------------------------------

if [ "$mode" = staged ]; then
    files=$(git diff --cached --name-only --diff-filter=ACM)
else
    files=$(git ls-files -co --exclude-standard)
fi

# Scan -----------------------------------------------------------------------

findings=0

# Split on newlines only, and do not glob, so paths with spaces survive.
old_ifs=$IFS
IFS='
'
set -f
for f in $files; do
    [ -f "$f" ] || continue

    base=${f##*/}
    case "$base" in
        .env|.env.local|.env.*)
            case "$base" in
                *.example|*.sample|*.template) ;;
                *) echo "  ENVFILE  $f"; findings=$((findings + 1)); continue ;;
            esac
            ;;
    esac
    case "$base" in
        *.pem|*.p12|*.pfx|*.ppk|id_rsa|id_dsa|id_ecdsa|id_ed25519|.netrc|_netrc|credentials.json|token.json|known_hosts)
            echo "  KEYFILE  $f"; findings=$((findings + 1)); continue ;;
    esac

    hits=$(grep -InE "$HARD" -- "$f" 2>/dev/null | grep -v 'secretscan:ignore' || true)
    if [ -n "$hits" ]; then
        echo "  SECRET   $f"
        printf '%s\n' "$hits" | cut -c1-160 | sed 's/^/             /'
        findings=$((findings + 1))
    fi

    # -i matters here: the assignments that leak are almost always SCREAMING_CASE
    # env vars (TVH_PASSWORD=, SA_PRIVATE_KEY_ID=), which a case-sensitive match
    # walks straight past.
    soft=$(grep -IniE "$SOFT" -- "$f" 2>/dev/null | grep -viE "$PLACEHOLDER" || true)
    if [ -n "$soft" ]; then
        echo "  DETAIL   $f"
        printf '%s\n' "$soft" | cut -c1-160 | sed 's/^/             /'
        findings=$((findings + 1))
    fi
done
IFS=$old_ifs
set +f

# Verdict --------------------------------------------------------------------

printf '\n'
if [ "$findings" -eq 0 ]; then
    echo "OK: nothing publishable in $root"
    exit 0
fi
cat <<'EOF'
FAIL: the files above would publish credentials, private addresses or
machine-specific paths. Move the values into a gitignored .env and leave
anonymised placeholders in .env.example, or mark a deliberate exception
with a trailing 'secretscan:ignore' comment on the line.
EOF
exit 1
