#!/usr/bin/env bash
# agent-skills-manager — keep one local Agent Skills directory discoverable by many AI tools.
# It manages directories, symlinks, and optional Git checkouts only. It never parses SKILL.md.

set -euo pipefail

VERSION="0.2.0"
SCOPE="project"
ACTION="menu"
ASSUME_YES=false
PROJECT_ROOT_ARG=""

usage() {
  cat <<'EOF'
Usage: agent-skills-manager.sh [--project|--global] [--root DIRECTORY] [--action ACTION] [--yes]

Actions: menu (default), migrate, diagnose, link, update, status

--project  Manage <project>/.agents/skills (default; project is the current Git root or pwd)
--global   Manage ~/.agents/skills
--root     Use DIRECTORY as the project root (only valid with --project)
--yes      Skip migration and update confirmations; never overwrites existing paths
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) SCOPE="project" ;;
    --global) SCOPE="global" ;;
    --root)
      [ "$#" -ge 2 ] || { echo "--root needs a directory" >&2; exit 2; }
      PROJECT_ROOT_ARG="$2"
      shift
      ;;
    --action)
      [ "$#" -ge 2 ] || { echo "--action needs a value" >&2; exit 2; }
      ACTION="$2"
      shift
      ;;
    --yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "$VERSION"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

info() { printf '  \033[36m•\033[0m %s\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

if [ "$SCOPE" = "global" ]; then
  [ -z "$PROJECT_ROOT_ARG" ] || { fail "--root cannot be used with --global"; exit 2; }
  BASE_DIR="$HOME"
  SHARED_ROOT="$HOME/.agents/skills"
else
  if [ -n "$PROJECT_ROOT_ARG" ]; then
    [ -d "$PROJECT_ROOT_ARG" ] || { fail "Project root is not a directory: $PROJECT_ROOT_ARG"; exit 2; }
    BASE_DIR="$(cd "$PROJECT_ROOT_ARG" && pwd -P)"
  else
    BASE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  fi
  SHARED_ROOT="$BASE_DIR/.agents/skills"
fi

# Only these hosts need an alias: the others below discover .agents/skills directly.
adapter_tools() {
  if [ "$SCOPE" = "global" ]; then
    printf '%s\n' claude-code codex qoder cline kiro
  else
    printf '%s\n' claude-code qoder cline kiro
  fi
}

target_for() {
  case "$1:$SCOPE" in
    claude-code:global) printf '%s' "$HOME/.claude/skills" ;;
    claude-code:project) printf '%s' "$BASE_DIR/.claude/skills" ;;
    codex:global) printf '%s' "$HOME/.codex/skills" ;;
    qoder:global) printf '%s' "$HOME/.qoder/skills" ;;
    qoder:project) printf '%s' "$BASE_DIR/.qoder/skills" ;;
    cline:global) printf '%s' "$HOME/.cline/skills" ;;
    cline:project) printf '%s' "$BASE_DIR/.cline/skills" ;;
    kiro:global) printf '%s' "$HOME/.kiro/skills" ;;
    kiro:project) printf '%s' "$BASE_DIR/.kiro/skills" ;;
    *) return 1 ;;
  esac
}

# Every supported native path lives one directory below the scope root, so this
# relative target stays valid if a project or a home directory is moved together.
link_value() {
  printf '%s' '../.agents/skills'
}

ensure_shared_root() {
  if [ ! -d "$SHARED_ROOT" ]; then
    mkdir -p "$SHARED_ROOT"
    ok "Created shared directory: $SHARED_ROOT"
  fi
}

is_correct_link() {
  local target="$1"
  [ -L "$target" ] || return 1
  [ "$(cd -P "$(dirname "$target")" && cd -P "$(readlink "$target")" 2>/dev/null && pwd -P)" = "$SHARED_ROOT" ]
}

state_for() {
  local target="$1"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    printf 'missing'
  elif is_correct_link "$target"; then
    printf 'linked'
  elif [ -L "$target" ]; then
    printf 'other-link'
  elif [ -d "$target" ]; then
    printf 'directory'
  else
    printf 'file'
  fi
}

confirm() {
  local prompt="$1"
  if $ASSUME_YES; then
    return 0
  fi
  printf '%s [y/N] ' "$prompt"
  read -r answer || return 1
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

create_link() {
  local tool="$1" target state
  target="$(target_for "$tool")"
  state="$(state_for "$target")"

  case "$state" in
    linked) ok "$tool already uses the shared directory" ;;
    missing)
      ensure_shared_root
      mkdir -p "$(dirname "$target")"
      ln -s "$(link_value)" "$target"
      ok "$tool → $target"
      ;;
    directory)
      warn "$tool has an existing directory: $target"
      warn "Run migration first; this script will not overwrite it."
      ;;
    other-link)
      warn "$tool already links to: $target -> $(readlink "$target")"
      warn "The link is left untouched."
      ;;
    *) fail "$tool target is a regular file: $target" ;;
  esac
}

link_all() {
  info "Configuring $SCOPE aliases from: $SHARED_ROOT"
  while IFS= read -r tool; do
    create_link "$tool"
  done < <(adapter_tools)
}

migrate_target() {
  local tool="$1" target state entry name
  target="$(target_for "$tool")"
  state="$(state_for "$target")"

  case "$state" in
    missing|linked) create_link "$tool"; return 0 ;;
    other-link|file)
      warn "$tool cannot be migrated automatically ($state): $target"
      return 0
      ;;
  esac

  ensure_shared_root
  info "Inspecting $tool: $target"

  while IFS= read -r entry; do
    name="$(basename "$entry")"
    if [ -e "$SHARED_ROOT/$name" ] || [ -L "$SHARED_ROOT/$name" ]; then
      warn "Name collision, left in place: $name"
      continue
    fi
    if ! confirm "Move '$name' into $SHARED_ROOT?"; then
      warn "Skipped: $name"
      continue
    fi
    mv "$entry" "$SHARED_ROOT/$name"
    ok "Moved: $name"
  done < <(find "$target" -mindepth 1 -maxdepth 1 -print)

  if [ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    warn "$target still has content, so no link was created. Resolve the remaining entries first."
    return 0
  fi

  rmdir "$target"
  ok "Removed empty directory: $target"
  create_link "$tool"
}

migrate_all() {
  info "Migrating existing $SCOPE skill directories into: $SHARED_ROOT"
  while IFS= read -r tool; do
    migrate_target "$tool"
  done < <(adapter_tools)
}

command_status() {
  local command="$1"
  if command -v "$command" >/dev/null 2>&1; then
    printf 'available'
  else
    printf 'not found'
  fi
}

diagnose() {
  printf '\nAgent Skills Manager %s (%s scope)\n' "$VERSION" "$SCOPE"
  printf 'Shared source: %s\n\n' "$SHARED_ROOT"

  if [ -d "$SHARED_ROOT" ]; then
    ok "Shared directory exists"
  else
    warn "Shared directory has not been created yet"
  fi

  printf '\nNative alias status\n'
  while IFS= read -r tool; do
    local target state
    target="$(target_for "$tool")"
    state="$(state_for "$target")"
    printf '  %-13s %-12s %s\n' "$tool" "$state" "$target"
  done < <(adapter_tools)

  printf '\nTools that already discover .agents/skills\n'
  printf '  Gemini CLI, GitHub Copilot, Windsurf, Amp, OpenCode, Roo Code, OpenClaw\n'
  printf '  (No additional link is created for these hosts.)\n'

  printf '\nCommand detection (informational only)\n'
  printf '  %-16s %s\n' 'claude' "$(command_status claude)"
  printf '  %-16s %s\n' 'codex' "$(command_status codex)"
  printf '  %-16s %s\n' 'gemini' "$(command_status gemini)"
  printf '  %-16s %s\n' 'qoder' "$(command_status qoder)"
  printf '  %-16s %s\n' 'cline' "$(command_status cline)"
  printf '  %-16s %s\n' 'kiro-cli' "$(command_status kiro-cli)"
  printf '  %-16s %s\n' 'opencode' "$(command_status opencode)"
  printf '  %-16s %s\n' 'openclaw' "$(command_status openclaw)"
}

is_git_root() {
  local directory="$1" root
  root="$(git -C "$directory" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$(cd "$root" && pwd -P)" = "$(cd "$directory" && pwd -P)" ]
}

update_repo() {
  local repo="$1" label="$2"
  if ! is_git_root "$repo"; then
    return 1
  fi
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then
    warn "$label has local changes; skipped: $repo"
    return 0
  fi
  if ! confirm "Run git pull --ff-only for $label?"; then
    warn "Skipped: $label"
    return 0
  fi
  if git -C "$repo" pull --ff-only; then
    ok "Updated: $label"
  else
    fail "Update failed and was left untouched: $label"
  fi
  return 0
}

update_sources() {
  local found=false entry
  if [ -d "$SHARED_ROOT" ] && update_repo "$SHARED_ROOT" "shared skill source"; then
    found=true
  fi

  if [ -d "$SHARED_ROOT" ]; then
    while IFS= read -r entry; do
      # git -C a child of a multi-Skill repository resolves to the parent root.
      # Only update actual checkout roots, so one source is never pulled repeatedly.
      if is_git_root "$entry" && update_repo "$entry" "$(basename "$entry")"; then
        found=true
      fi
    done < <(find "$SHARED_ROOT" -mindepth 1 -maxdepth 1 -type d -print)
  fi

  if ! $found; then
    info "No Git checkout was found in $SHARED_ROOT. Nothing needs syncing."
  fi
}

menu() {
  while true; do
    cat <<EOF

Agent Skills Manager ($SCOPE)

  1) Migrate existing Skills to .agents/skills
  2) Check tool and directory compatibility
  3) Configure or repair native Skill links
  4) Sync Git-backed shared Skill sources
  5) Show status
  q) Exit
EOF
    printf '\n  ? Choose [1-5/q]: '
    read -r choice || exit 0
    case "$choice" in
      1) migrate_all ;;
      2) diagnose ;;
      3) link_all ;;
      4) update_sources ;;
      5) diagnose ;;
      q|Q) exit 0 ;;
      *) warn "Unknown option: $choice" ;;
    esac
  done
}

case "$ACTION" in
  menu) menu ;;
  migrate) migrate_all ;;
  diagnose|status) diagnose ;;
  link) link_all ;;
  update) update_sources ;;
  *) fail "Unknown action: $ACTION"; usage >&2; exit 2 ;;
esac
