#!/usr/bin/env bash
# build.sh — build the TUI binary, tag, and publish to GitHub Releases
#
# Usage:
#   ./build.sh                 # prompt for next version based on latest tag
#   ./build.sh v2.0.3          # release explicit tag
#   ./build.sh --dry-run       # show what would happen without pushing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
REPO="jwvolschenk/hindsight-custom"
BINARY_NAME="hindsight-installer-linux-x86_64"
BUILD_VENV="/tmp/hindsight-build-venv"

DRY_RUN=false
TAG=""

R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m'
W='\033[1;37m' D='\033[0;90m' N='\033[0m'

ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
info() { printf "  ${D}│${N} %s\n" "$*"; }
warn() { printf "  ${Y}!${N} %s\n" "$*"; }
err()  { printf "  ${R}✗${N} %s\n" "$*" >&2; }
die()  { err "$@"; exit 1; }

usage() {
    cat <<EOF
Usage: ./build.sh [tag] [--dry-run]

Builds the TUI binary locally, creates a version tag, and uploads the
binary to GitHub Releases (no GitHub Actions needed).

Examples:
  ./build.sh
  ./build.sh v2.0.3
  ./build.sh --dry-run
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage; exit 0 ;;
            v*) TAG="$1"; shift ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

check_prereqs() {
    command -v git >/dev/null 2>&1 || die "git not found"
    command -v gh >/dev/null 2>&1 || die "gh CLI not found. Install: https://cli.github.com/"
    gh auth status >/dev/null 2>&1 || die "gh not authenticated. Run: gh auth login"
    python3 -c "import venv" 2>/dev/null || die "python3 venv module not available"

    if [[ "$(gh api "repos/${REPO}" --jq '.permissions.push' 2>/dev/null || echo false)" != "true" ]]; then
        local active_user
        active_user="$(gh api user --jq '.login' 2>/dev/null || echo unknown)"
        die "Active gh account '${active_user}' cannot push to ${REPO}"
    fi
}

ensure_clean_main() {
    cd "$REPO_DIR"
    local branch
    branch="$(git branch --show-current)"
    [ "$branch" = "main" ] || die "Release must be run from main, current branch is '${branch}'"

    if [ -n "$(git status --porcelain)" ]; then
        if $DRY_RUN; then
            warn "Working tree is not clean; continuing because this is a dry run."
            return
        fi
        git status --short
        die "Working tree is not clean. Commit or stash changes before releasing."
    fi

    git fetch origin main --tags --quiet

    local local_head remote_head
    local_head="$(git rev-parse main)"
    remote_head="$(git rev-parse origin/main)"
    [ "$local_head" = "$remote_head" ] || die "main is not in sync with origin/main"
}

latest_tag() {
    git tag --list 'v*' --sort=-v:refname | head -1
}

bump_version() {
    local current="$1" part="$2"
    local v major minor patch
    v="${current#v}"
    v="${v%%[-+]*}"
    IFS='.' read -r major minor patch <<< "$v"

    [[ "$major" =~ ^[0-9]+$ ]] || die "Cannot parse latest tag: $current"
    [[ "$minor" =~ ^[0-9]+$ ]] || die "Cannot parse latest tag: $current"
    [[ "$patch" =~ ^[0-9]+$ ]] || die "Cannot parse latest tag: $current"

    case "$part" in
        patch) printf "v%s.%s.%s" "$major" "$minor" "$((patch + 1))" ;;
        minor) printf "v%s.%s.0" "$major" "$((minor + 1))" ;;
        major) printf "v%s.0.0" "$((major + 1))" ;;
        *) die "Unknown version part: $part" ;;
    esac
}

prompt_version() {
    local latest="$1"

    if [ -z "$latest" ]; then
        printf "  ${W}No existing v* tags found.${N}\n"
        read -rp "  Enter version tag (for example v1.0.0): " TAG
        [ -n "$TAG" ] || die "Version tag required"
        return
    fi

    local patch minor major
    patch="$(bump_version "$latest" patch)"
    minor="$(bump_version "$latest" minor)"
    major="$(bump_version "$latest" major)"

    echo ""
    printf "  ${W}Current version:${N} %s\n" "$latest"
    echo ""
    printf "  ${W}Select next version:${N}\n"
    printf "    ${C}1)${N} %s  ${D}(patch)${N}\n" "$patch"
    printf "    ${C}2)${N} %s  ${D}(minor)${N}\n" "$minor"
    printf "    ${C}3)${N} %s  ${D}(major)${N}\n" "$major"
    printf "    ${C}4)${N} custom\n"
    echo ""
    read -rp "  Choice [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) TAG="$patch" ;;
        2) TAG="$minor" ;;
        3) TAG="$major" ;;
        4)
            read -rp "  Enter version tag (for example v2.1.0-rc1): " TAG
            [ -n "$TAG" ] || die "Version tag required"
            ;;
        *) TAG="$patch" ;;
    esac
}

validate_tag() {
    [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || \
        die "Invalid version tag: ${TAG}. Expected format like v2.0.3"

    if git rev-parse "$TAG" >/dev/null 2>&1; then
        die "Tag already exists locally: $TAG"
    fi
    if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
        die "Tag already exists on origin: $TAG"
    fi
}

build_binary() {
    echo ""
    info "Building ${BINARY_NAME} ..."

    rm -rf "$BUILD_VENV"
    python3 -m venv "$BUILD_VENV"
    "$BUILD_VENV/bin/pip" install --quiet ".[installer]" pyinstaller

    "$BUILD_VENV/bin/python" -m PyInstaller \
        --onefile \
        --name "$BINARY_NAME" \
        --collect-all textual \
        --add-data "$REPO_DIR/install.sh:." \
        --distpath "$REPO_DIR/dist" \
        --workpath /tmp/hindsight-installer-build \
        --specpath /tmp/hindsight-installer-spec \
        --noconfirm \
        installer/tui.py

    rm -rf "$BUILD_VENV" /tmp/hindsight-installer-build /tmp/hindsight-installer-spec

    if [ ! -f "$REPO_DIR/dist/$BINARY_NAME" ]; then
        die "Binary not found after build: dist/$BINARY_NAME"
    fi

    local size
    size="$(du -h "$REPO_DIR/dist/$BINARY_NAME" | cut -f1)"
    ok "Binary built: dist/$BINARY_NAME ($size)"
}

confirm_release() {
    echo ""
    printf "  ${W}This will:${N}\n"
    printf "    ${D}1.${N} Create annotated git tag ${C}%s${N}\n" "$TAG"
    printf "    ${D}2.${N} Push ${C}%s${N} to origin\n" "$TAG"
    printf "    ${D}3.${N} Create GitHub release with ${C}%s${N}\n" "$BINARY_NAME"
    echo ""

    if $DRY_RUN; then
        warn "Dry run enabled; nothing will be pushed."
        return
    fi

    read -rp "  Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { printf "\n  ${D}Aborted.${N}\n\n"; exit 0; }
}

create_tag_and_release() {
    if $DRY_RUN; then
        info "Would run: git tag -a ${TAG} -m 'Release ${TAG}'"
        info "Would run: git push origin ${TAG}"
        info "Would run: gh release create ${TAG} dist/${BINARY_NAME}"
        return
    fi

    git tag -a "$TAG" -m "Release $TAG"
    git push origin "$TAG"
    ok "Tag pushed: $TAG"

    # Delete existing release if present (allows re-running)
    gh release delete "$TAG" --repo "$REPO" --yes 2>/dev/null || true

    gh release create "$TAG" \
        "$REPO_DIR/dist/$BINARY_NAME" \
        --repo "$REPO" \
        --title "Release $TAG" \
        --notes "Release $TAG — hindsight-installer-linux-x86_64"
    ok "Release created with binary attached"
}

show_release() {
    $DRY_RUN && return 0

    echo ""
    printf "  ${G}Release:${N} ${C}https://github.com/%s/releases/tag/%s${N}\n" "$REPO" "$TAG"
    printf "  ${G}Latest binary:${N} ${C}https://github.com/%s/releases/latest/download/%s${N}\n" "$REPO" "$BINARY_NAME"
    echo ""
}

main() {
    parse_args "$@"

    echo ""
    printf "  ${W}Hindsight Custom release builder${N}\n"
    printf "  ${D}Builds the TUI binary locally and uploads to GitHub Releases.${N}\n"
    echo ""

    check_prereqs
    ensure_clean_main

    if [ -z "$TAG" ]; then
        prompt_version "$(latest_tag)"
    fi
    validate_tag

    info "Version tag: $TAG"
    confirm_release
    build_binary
    create_tag_and_release
    show_release
}

main "$@"
