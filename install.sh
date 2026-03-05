#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${N8N_SH_REPO:-https://github.com/ARMBouhali/n8nite.git}"
REPO_REF="${N8N_SH_REF:-main}"
INSTALL_DIR="${N8N_SH_DIR:-$HOME/.local/share/n8nite}"
BIN_DIR="${N8N_SH_BIN_DIR:-$HOME/.local/bin}"
BIN_NAME="${N8N_SH_BIN_NAME:-n8nite}"
PERSIST_RC="${N8N_SH_PERSIST_RC:-1}"

usage() {
	cat <<'EOF'
Install n8nite from git.

Usage:
  ./install.sh
  ./install.sh --help

Environment overrides:
  N8N_SH_REPO      Git repository URL
  N8N_SH_REF       Branch or tag (default: main)
  N8N_SH_DIR       Install directory (default: ~/.local/share/n8nite)
  N8N_SH_BIN_DIR   Symlink directory (default: ~/.local/bin)
  N8N_SH_BIN_NAME  Installed command name (default: n8nite)
  N8N_SH_PERSIST_RC  Write PATH export to ~/.bashrc and ~/.zshrc (default: 1)
EOF
}

log() {
	printf '[INFO] %s\n' "$*"
}

fail() {
	printf '[ERROR] %s\n' "$*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

install_repo() {
	local install_parent
	install_parent="$(dirname "$INSTALL_DIR")"
	mkdir -p "$install_parent"

	if [[ -d "$INSTALL_DIR/.git" ]]; then
		log "Updating existing installation in $INSTALL_DIR"
		git -C "$INSTALL_DIR" fetch --tags origin "$REPO_REF"
		git -C "$INSTALL_DIR" checkout -q "$REPO_REF"
		git -C "$INSTALL_DIR" pull --ff-only origin "$REPO_REF"
	else
		if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR/.git" ]]; then
			fail "Install target exists but is not a git checkout: $INSTALL_DIR"
		fi
		log "Cloning $REPO_URL ($REPO_REF) to $INSTALL_DIR"
		git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR"
	fi
}

install_binary() {
	local source_bin target_bin
	source_bin="$INSTALL_DIR/n8nite"
	target_bin="$BIN_DIR/$BIN_NAME"

	[[ -f "$source_bin" ]] || fail "Missing executable: $source_bin"
	chmod 755 "$source_bin"

	mkdir -p "$BIN_DIR"
	ln -sfn "$source_bin" "$target_bin"
	log "Linked $target_bin -> $source_bin"
}

upsert_path_block() {
	local rc_file="$1"
	local begin_marker="# >>> n8nite PATH >>>"
	local end_marker="# <<< n8nite PATH <<<"
	local path_line="export PATH=\"$BIN_DIR:\$PATH\""
	local tmp_file=""
	local has_begin=0
	local has_end=0

	[[ -f "$rc_file" ]] || touch "$rc_file"

	if grep -Fq "$begin_marker" "$rc_file"; then
		has_begin=1
	fi
	if grep -Fq "$end_marker" "$rc_file"; then
		has_end=1
	fi

	if [[ "$has_begin" -eq 1 && "$has_end" -eq 1 ]]; then
		tmp_file="$(mktemp)"
		awk -v begin="$begin_marker" -v end="$end_marker" -v line="$path_line" '
			$0 == begin {
				print
				print line
				in_block = 1
				next
			}
			$0 == end {
				in_block = 0
				print
				next
			}
			!in_block { print }
		' "$rc_file" >"$tmp_file"
		mv "$tmp_file" "$rc_file"
		log "Updated PATH block in $rc_file"
		return 0
	fi

	if grep -Fq "$path_line" "$rc_file"; then
		log "PATH line already present in $rc_file"
		return 0
	fi

	{
		printf '\n%s\n' "$begin_marker"
		printf '%s\n' "$path_line"
		printf '%s\n' "$end_marker"
	} >>"$rc_file"
	log "Added PATH block to $rc_file"
}

persist_shell_path() {
	if [[ "$PERSIST_RC" != "1" ]]; then
		log "Skipping shell rc persistence (N8N_SH_PERSIST_RC=$PERSIST_RC)"
		return 0
	fi

	upsert_path_block "$HOME/.bashrc"
	upsert_path_block "$HOME/.zshrc"
}

print_path_hint() {
	case ":$PATH:" in
		*":$BIN_DIR:"*)
			log "PATH already contains $BIN_DIR"
			;;
		*)
			log "Current shell PATH does not include $BIN_DIR yet."
			printf '\nRun one of these, or open a new shell:\n'
			printf '  source ~/.bashrc\n'
			printf '  source ~/.zshrc\n\n'
			;;
	esac
}

main() {
	if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
		usage
		return 0
	fi

	need_cmd git
	need_cmd bash
	need_cmd ln
	need_cmd mkdir
	need_cmd dirname
	need_cmd awk
	need_cmd mktemp
	need_cmd mv
	need_cmd touch

	install_repo
	install_binary
	persist_shell_path
	print_path_hint

	printf 'Installed. Run:\n'
	printf '  %s --help\n' "$BIN_NAME"
}

main "$@"
