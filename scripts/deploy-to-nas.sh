#!/bin/sh
#
# Deploy the built modules and the boot-persistence layer to the NAS.
#
# The NAS is a deploy TARGET, not a clone (CLAUDE.md invariant 9): no git
# checkout, no build tree. Only four paths are read at boot, so only those four
# are copied. The host and directory are environment configuration and come
# from .env — nothing machine-specific is written down here (invariant 8).
#
#     sh scripts/deploy-to-nas.sh --dry-run     # show what would change
#     sh scripts/deploy-to-nas.sh               # do it
#
# It does not load or reload anything. Copying a .ko over one that is already
# loaded changes nothing until the next boot or an explicit load, so a running
# recording is unaffected; picking the change up is a separate, deliberate act.
#
# firmware/ is the one asymmetry. It is never vendored in this repo, so the
# build host usually has none and the NAS has the only copy — syncing it with
# --delete would wipe the Si2168 firmware and leave the tuner registering no
# adapter at all. So: push it only if there is something local to push, and
# never delete there. See docs/01-boot-and-persistence.md.

set -eo pipefail

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="${ENV_FILE:-$REPO/.env}"

DRY_RUN=0

usage() {
    cat <<'USAGE'
usage: sh scripts/deploy-to-nas.sh [--dry-run]

  -n, --dry-run   report what would change; touch nothing
  -h, --help      this

Reads DEPLOY_HOST and DEPLOY_DIR from .env (see .env.example).
USAGE
}

die() { echo "deploy-to-nas: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; exit 2 ;;
    esac
    shift
done

# --- configuration ----------------------------------------------------------

[ -f "$ENV_FILE" ] || die "no $ENV_FILE — copy .env.example to .env and fill it in"
# shellcheck disable=SC1090
. "$ENV_FILE"

[ -n "${DEPLOY_HOST:-}" ] || die "DEPLOY_HOST is not set in $ENV_FILE (an ssh destination; a ~/.ssh/config alias is safest)"
[ -n "${DEPLOY_DIR:-}" ]  || die "DEPLOY_DIR is not set in $ENV_FILE (the directory the boot path reads on the NAS)"

case "$DEPLOY_DIR" in
    /build/*) die "DEPLOY_DIR=$DEPLOY_DIR is a container path — it must be the NAS-side directory, not a build path" ;;
    /*) ;;
    *) die "DEPLOY_DIR must be an absolute path on the NAS" ;;
esac

# --- refuse to sync into a hole ---------------------------------------------
# Every sync below carries --delete, so a missing or empty local directory does
# not "deploy nothing" — it erases the target. These are the only thing between
# a typo and a NAS that boots with no modules.

for d in scripts drivers modules; do
    [ -d "$REPO/$d" ] || die "$d/ does not exist here — refusing to sync (--delete would empty the target)"
    [ -n "$(ls -A "$REPO/$d" 2>/dev/null)" ] || die "$d/ is empty — refusing to sync (--delete would empty the target)"
done

[ -f "$REPO/scripts/load-modules.sh" ] || die "scripts/load-modules.sh is missing — $REPO does not look like the repo root"
[ -f "$REPO/drivers/dvb/manifest.sh" ] || die "drivers/dvb/manifest.sh is missing — the loader would find no manifests and silently load nothing"

mod_count=$(find "$REPO/modules" -name '*.ko' -type f | wc -l | tr -d ' ')
[ "$mod_count" -gt 0 ] || die "modules/ holds no .ko files — nothing has been built here"

# firmware/ may legitimately not exist on a fresh clone, and `find` on a missing
# directory exits non-zero — which `set -o pipefail` would turn into a dead script.
if [ -d "$REPO/firmware" ]; then
    fw_count=$(find "$REPO/firmware" -type f | wc -l | tr -d ' ')
else
    fw_count=0
fi

# --- go ---------------------------------------------------------------------

COMMIT=$(cd "$REPO" && git rev-parse --short HEAD 2>/dev/null) \
    || die "cannot read the current commit — is this a git checkout?"
DIRTY=""
[ -n "$(cd "$REPO" && git status --porcelain)" ] && DIRTY=" (working tree dirty)"

echo "deploy-to-nas: $REPO -> $DEPLOY_HOST:$DEPLOY_DIR"
echo "  commit    $COMMIT$DIRTY"
echo "  modules   $mod_count .ko"
if [ "$fw_count" -gt 0 ]; then
    echo "  firmware  $fw_count file(s) — pushed, never deleted"
else
    echo "  firmware  none locally — left alone on the target, which holds the only copy"
fi
echo

# -rlpt, not -a: -a drags in -o and -g, and the Mac's petekaik:staff has no
# counterpart on the NAS. rsync would then either fail chown and take the whole
# script down with `set -e`, or "succeed" by handing the boot-path files to a uid
# that does not exist there. Ownership on the target stays native; the loader
# runs as root regardless.
RSYNC="-rlpt -i"
if [ "$DRY_RUN" -eq 1 ]; then
    RSYNC="$RSYNC -n"
    echo "--- dry run: nothing below is written ---"
fi

for d in scripts drivers modules; do
    echo "== $d/ (--delete: removals here propagate)"
    # shellcheck disable=SC2086
    rsync $RSYNC --delete -e ssh -- "$REPO/$d/" "$DEPLOY_HOST:$DEPLOY_DIR/$d/"
done

if [ "$fw_count" -gt 0 ]; then
    echo "== firmware/ (no --delete — the target may hold the only copy)"
    # shellcheck disable=SC2086
    rsync $RSYNC -e ssh -- "$REPO/firmware/" "$DEPLOY_HOST:$DEPLOY_DIR/firmware/"
else
    echo "== firmware/ skipped (nothing local to push)"
fi
echo

# --- manifest ---------------------------------------------------------------
# Rewritten from here rather than kept as a file, so the two cannot drift.

if [ "$DRY_RUN" -eq 1 ]; then
    echo "--- dry run: would rewrite $DEPLOY_DIR/.deploy-manifest with source-commit: $COMMIT ---"
    exit 0
fi

ssh "$DEPLOY_HOST" "cat > '$DEPLOY_DIR/.deploy-manifest'" <<EOF
# Deploy manifest — this directory is a deploy TARGET, not a git checkout.
#
# There is deliberately no .git here. This tree is the *output* of the builder,
# not a copy of it. Do not clone into it; do not git pull.
#
# Written by scripts/deploy-to-nas.sh from the source repo. Do not hand-edit;
# the next deploy overwrites it.

source-repo:    $(cd "$REPO" && git config --get remote.origin.url 2>/dev/null || echo "(no origin)")
source-commit:  $COMMIT
deployed:       $(date +%Y-%m-%d)

# The four paths the boot path reads. Everything else (builder scripts, Dockerfile,
# GPL kernel source, docs) stays on the build host — it is not needed here.
#   scripts/    loader, watchdog, installer
#   drivers/    manifests — the loader's source of truth for load order
#   modules/    compiled .ko files
#   firmware/   Si2168 demod firmware — exists ONLY here; never synced with --delete

loader:         scripts/load-modules.sh   (via /etc/init.d/dvb-loader.sh at boot)
watchdog:       scripts/dvb-watchdog.sh   (QTS cron, every 5 minutes)
install:        scripts/qnap-install.sh   (idempotent — re-run after a QTS update)

# To update: sh scripts/deploy-to-nas.sh from the source repo, then re-run
# scripts/qnap-install.sh if the boot path itself changed.
# To verify the boot path after any change:
#   DRY_RUN=1 sh scripts/load-modules.sh; tail logs/module-boot.log
EOF

echo "manifest:    $DEPLOY_DIR/.deploy-manifest -> source-commit: $COMMIT"
echo

# --- verify -----------------------------------------------------------------
# sha256 of every regular file, both sides, same relative paths. Independent of
# rsync's own view of what it did. Symlinks are not content-hashed here — rsync
# preserves them and the trees are identical by construction.

tmp=$(mktemp -d "${TMPDIR:-/tmp}/deploy-to-nas.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

failed=0
for d in scripts drivers modules firmware; do
    # A firmware/ that is empty locally was never pushed, so there is nothing to
    # compare against — the target's copy legitimately differs (it is the only one).
    if [ "$d" = firmware ] && [ "$fw_count" -eq 0 ]; then
        printf '  %-9s skipped (none local)\n' "$d/"
        continue
    fi

    ( cd "$REPO" && find "$d" -type f -exec shasum -a 256 {} + ) | sort > "$tmp/local"
    ssh "$DEPLOY_HOST" "cd '$DEPLOY_DIR' && find '$d' -type f -exec sha256sum {} +" | sort > "$tmp/remote"

    n_local=$(wc -l < "$tmp/local" | tr -d ' ')
    if diff -q "$tmp/local" "$tmp/remote" >/dev/null; then
        printf '  %-9s OK    %s file(s) identical\n' "$d/" "$n_local"
    else
        printf '  %-9s FAIL  differs:\n' "$d/"
        diff "$tmp/local" "$tmp/remote" | sed 's/^/            /' | head -20
        failed=1
    fi
done

echo
if [ "$failed" -eq 0 ]; then
    echo "deploy-to-nas: verified. Boot path unchanged until the next reboot."
else
    die "verification failed — the target does not match the working tree"
fi
