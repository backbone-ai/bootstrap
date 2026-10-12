#!/usr/bin/env bash
# Blank Mac -> fully provisioned, in one pasted command.
#
# This is the ONE mile the in-repo provisioner can't cover: a bare macOS account has
# no git, no GitHub auth, and no checkout, so it can't reach `make provision-macos`
# (which lives inside the repo). This gets there — install Nix, authenticate GitHub
# once, clone backbone — then hands off to provision_macos.py, which owns everything
# else (Xcode CLT, nix-darwin, home-manager, 1Password op + git-signing, colima).
#
# Detection-first: every step reuses what's already on the machine and only installs
# what's genuinely missing, so it's safe on a bare account AND a half-set-up one.
# `--status` reports the detection read-only without touching anything.
#
# It must run before any dev tool exists, so it is thin bash (the one interpreter a
# bare Mac always has) and delegates all real logic to the Python wizard, per AGENTS.md
# "bash is glue, python is logic". Idempotent: re-run after any failure and it resumes.
#
# Meant to be curled from a PUBLIC location (a bare private-repo can't serve its own
# bootstrap): `curl -fsSL <public-url>/flash.sh | bash`. Source of truth lives here,
# under review; publishing it to the public URL is a deploy step (see README).
set -euo pipefail

GH_ORG="backbone-ai"
REPO="backbone"
# The work root a laptop shares with a devbox, so one surface's recorded path is readable by
# the other's. scripts/laptop_layout.py is the SSOT for these; they are spelled literally here
# because this file runs BEFORE any checkout exists to read them from, and
# scripts/check_macos_provision_drift.py fails when the spellings diverge.
DATA_ROOT="/data"
WORK_ROOT="$DATA_ROOT/$GH_ORG"
DEST="$WORK_ROOT/$REPO"
# Where the first clone lands. It cannot be $DEST: macOS seals the root volume, so /data does
# not exist until a manifest is written and stitched — and the program that does that ships
# IN this repository. So stage the clone somewhere that always works, run the placement logic
# out of it, and let that move the tree to $DEST once /data is live.
STAGING="$HOME/.cache/backbone-bootstrap/$REPO"
# Determinate's macOS *package* — their recommended, most robust install. The plain
# nix-installer script's encrypted-/nix-APFS-volume dance fails on some Macs ("Volume …
# failed to mount") and can't recover a partial prior attempt; the pkg is hardened for both.
DETERMINATE_NIX_PKG="https://install.determinate.systems/determinate-pkg/stable/Universal"

log() { printf '\033[1;36m[flash]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[flash]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[flash] %s\033[0m\n' "$*" >&2; exit 1; }

STATUS_ONLY=0
for a in "$@"; do case "$a" in --status | --check) STATUS_ONLY=1 ;; esac; done

[ "$(uname -s)" = "Darwin" ] || die "flash.sh provisions macOS; this is $(uname -s)."

# --- detection (never mutates) ---------------------------------------------------------

# Pull an already-installed nix onto PATH for THIS shell: a curl|bash shell has sourced no
# profile, and the installer only edits *future* shells — so without this a machine that
# already has nix would look bare and we'd wrongly try to reinstall. Covers the multi-user/
# Determinate daemon layout and the single-user layout. Relax `-u` while sourcing (the
# profile scripts predate our `set -u` and may touch unset vars).
source_existing_nix() {
  local p
  set +u
  for p in /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
    "$HOME/.nix-profile/etc/profile.d/nix.sh"; do
    # shellcheck disable=SC1090
    [ -e "$p" ] && . "$p" 2>/dev/null || true
  done
  set -u
}

have_nix() { command -v nix >/dev/null 2>&1; }

# determinate | upstream | none — so we never reinstall Determinate *over* an existing
# upstream nix (that conflicts); we adopt whatever is there.
nix_flavor() {
  have_nix || { echo none; return; }
  if [ -e /nix/receipt.json ] || nix --version 2>/dev/null | grep -qi determinate; then
    echo determinate
  else
    echo upstream
  fi
}

# Run a tool straight from nixpkgs without installing it (flakes are on by default under
# Determinate Nix; pass the features flag anyway so this works on any nix).
nx() { nix --extra-experimental-features 'nix-command flakes' run "nixpkgs#$1" -- "${@:2}"; }

gh_authed()   { have_nix && nx gh auth status --hostname github.com >/dev/null 2>&1; }

# The checkout to work out of: the canonical one when /data has been provisioned, else the
# staged clone (a machine that has not rebooted yet keeps its checkout where it landed).
checkout_path() {
  if [ -d "$DEST/.git" ]; then echo "$DEST"
  elif [ -d "$STAGING/.git" ]; then echo "$STAGING"
  fi
}
repo_cloned() { [ -n "$(checkout_path)" ]; }

source_existing_nix

if [ "$STATUS_ONLY" -eq 1 ]; then
  printf '%-20s %s\n' "nix:" "$(nix_flavor)$(have_nix && printf ' (%s)' "$(nix --version 2>/dev/null | head -1)")"
  printf '%-20s %s\n' "github auth:" "$(gh_authed && echo authenticated || echo 'not authenticated')"
  printf '%-20s %s\n' "backbone checkout:" "$(repo_cloned && checkout_path || echo absent)"
  printf '%-20s %s\n' "$DATA_ROOT work root:" "$([ -d "$WORK_ROOT" ] && echo "$WORK_ROOT" || echo 'not provisioned (created by the nix-darwin switch)')"
  exit 0
fi

# 1. Nix — reuse ANY existing install; install only when truly absent. Install via the
#    Determinate macOS package (robust: the plain nix-installer's /nix APFS volume is flaky).
case "$(nix_flavor)" in
none)
  log "installing Determinate Nix (macOS package; asks for your password once)…"
  pkg="$(mktemp -d)/determinate-nix.pkg"
  curl -fsSL "$DETERMINATE_NIX_PKG" -o "$pkg" \
    || die "couldn't download the Determinate Nix package from $DETERMINATE_NIX_PKG"
  # -H: root runs with HOME=/var/root, not this account's — sudo does not reset HOME on
  # its own, and unlike nix (which only warns and falls back to the passwd entry) a
  # less careful tool would write root-owned files straight into this $HOME.
  sudo -H installer -pkg "$pkg" -target / \
    || die "Determinate Nix package install failed — if it names a leftover 'Nix Store' volume, run 'diskutil apfs list | grep -i nix', delete that volume, reboot, then re-run."
  source_existing_nix
  ;;
upstream)
  ok "found an existing (upstream) Nix — reusing it, not reinstalling Determinate over it."
  ;;
determinate)
  ok "Nix already present — skipping install."
  ;;
esac
have_nix || die "nix isn't on PATH after install — open a new terminal and re-run."

# 2. GitHub auth — device/web flow (paste a browser code). Reuse any existing session.
#    Nothing durable lands here; the provisioner later moves auth to the 1Password SSH
#    agent + an op-held gh token — this is only the first-clone bootstrap.
if gh_authed; then
  ok "GitHub already authenticated — skipping login."
else
  log "authenticating to GitHub — a browser code will appear; paste it and approve…"
  nx gh auth login --hostname github.com --git-protocol https --web \
    || die "GitHub auth did not complete — re-run this command to retry."
fi

# 3. Clone backbone. Only backbone is needed to reach the wizard; the wizard reconciles the
#    rest (backbone-deploy) over the proper SSH/1Password path once that auth is up.
if repo_cloned; then
  ok "$(checkout_path) already cloned — the provisioner will fetch it."
else
  log "cloning $GH_ORG/$REPO -> $STAGING…"
  mkdir -p "$(dirname "$STAGING")"
  nx gh repo clone "$GH_ORG/$REPO" "$STAGING" \
    || die "clone failed — check your GitHub access to $GH_ORG/$REPO, then re-run."
fi

# 4. Place the checkout under $WORK_ROOT, provisioning /data on the way. Root is required to
#    write /etc and the data volume's root, so realize a python3 out of the store FIRST and
#    sudo that absolute path — `sudo nix run` would need nix on root's PATH, which a fresh
#    Determinate install has not necessarily arranged. Exit 2 means "left staged, awaiting a
#    reboot", which is a state and not a failure, so it is reported and the flow continues.
CHECKOUT="$(checkout_path)"
if [ "$CHECKOUT" != "$DEST" ]; then
  log "provisioning $DATA_ROOT and placing the checkout…"
  PY="$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths nixpkgs#python3)/bin/python3" \
    || die "could not realize a python3 from nixpkgs — re-run, or check your nix install."
  set +e
  # -H (same rationale as the installer call above): the owner to place the checkout
  # under is passed explicitly via --owner, never inferred from root's $HOME.
  PLACED="$(sudo -H "$PY" "$CHECKOUT/scripts/macos_data_volume.py" place-checkout \
    --staged "$CHECKOUT" --data-root "$DATA_ROOT" --work-root "$WORK_ROOT" \
    --owner "$(id -un)" --repo-name "$REPO")"
  place_rc=$?
  set -e
  case "$place_rc" in
  0) CHECKOUT="$PLACED"; ok "checkout in place at $CHECKOUT" ;;
  2)
    CHECKOUT="$PLACED"
    ok "checkout staged at $CHECKOUT — $DATA_ROOT applies at the next boot (or: sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t)."
    log "after that, move it to $DEST — or keep it here and register it (BACKBONE_HOME)."
    ;;
  *) die "could not provision $DATA_ROOT — see the messages above, then re-run." ;;
  esac
fi

# 5. Hand off to the in-repo provisioner's FULL guided run (not --checkout, which is a
#    clone-only mode). It installs the whole toolchain — Xcode CLT, nix-darwin,
#    home-manager, 1Password op + git-signing, colima — each step itself detection-first
#    (its own status->set->heal ladder), and does its own repo checkout over SSH. Run it
#    with a nix python3, since a bare Mac has no python3 until CLT (which the wizard
#    installs); the wizard is stdlib-only by design, so nix's python3 runs it as-is, and
#    from then on the native `make provision-macos` works. Args flow straight through.
#
# BACKBONE_HOME registers whichever tree the checkout actually landed in, so a run that
# degraded to the staged location provisions THAT tree rather than a canonical path which
# does not exist yet.
log "handing off to the native provisioner (installs the full toolchain)…"
cd "$CHECKOUT"
export BACKBONE_HOME="$CHECKOUT"
exec nix --extra-experimental-features 'nix-command flakes' run nixpkgs#python3 -- \
  "$CHECKOUT/scripts/provision_macos.py" "$@"
