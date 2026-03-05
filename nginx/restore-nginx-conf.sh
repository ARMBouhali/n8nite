#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Restore a timestamped nginx config backup for this n8n stack.

Usage:
  ./nginx/restore-nginx-conf.sh [options]

Options:
  -e, --env-file PATH  Path to env file (default: <repo>/.env)
  -c, --conf-name NAME Nginx conf name without .conf
                       (default: N8N_HOST with dots replaced by dashes)
  -b, --backup PATH    Restore a specific backup file
  --latest             Restore the newest backup without interactive selection
  -y, --yes            Skip confirmation prompt
  --help               Show this help

Environment variables:
  SITES_AVAILABLE_DIR  Override nginx sites-available dir (default: /etc/nginx/sites-available)
  SITES_ENABLED_DIR    Override nginx sites-enabled dir (default: /etc/nginx/sites-enabled)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() {
	printf '[INFO] %s\n' "$*"
}

fail() {
	printf '[ERROR] %s\n' "$*" >&2
	exit 1
}

run_root() {
	if [[ "${EUID}" -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

load_env_file() {
	local file="$1"
	[[ -f "$file" ]] || fail "Env file not found: $file"
	set -a
	# shellcheck disable=SC1090
	source "$file"
	set +a
}

confirm_yes_no() {
	local label="$1"
	local answer=""
	read -r -p "$label [y/N]: " answer
	[[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

next_backup_path() {
	local target="$1"
	local timestamp backup_path counter

	timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
	backup_path="${target}.bak.${timestamp}"
	counter=0

	while run_root test -e "$backup_path" || run_root test -L "$backup_path"; do
		counter=$((counter + 1))
		backup_path="${target}.bak.${timestamp}.${counter}"
	done

	printf '%s' "$backup_path"
}

backup_existing_conf() {
	local target="$1"
	local backup_path=""

	if run_root test -e "$target" || run_root test -L "$target"; then
		backup_path="$(next_backup_path "$target")"
		run_root cp -a "$target" "$backup_path"
	fi

	printf '%s' "$backup_path"
}

find_backups_for_conf() {
	local target="$1"
	local search_dir base_name

	search_dir="$(dirname "$target")"
	base_name="$(basename "$target")"
	[[ -d "$search_dir" ]] || return 0

	find "$search_dir" -maxdepth 1 \( -type f -o -type l \) -name "${base_name}.bak.*" | sort -r
}

prompt_for_backup_selection() {
	local label="$1"
	shift
	local backups=("$@")
	local choice="" index=0

	((${#backups[@]} > 0)) || fail "No backups available for ${label}"

	printf 'Available backups for %s:\n' "$label" >&2
	while ((index < ${#backups[@]})); do
		printf '  %d) %s\n' "$((index + 1))" "${backups[$index]}" >&2
		index=$((index + 1))
	done

	read -r -p "Select backup to restore [1-${#backups[@]}] (Enter=1): " choice
	choice="${choice:-1}"
	[[ "$choice" =~ ^[0-9]+$ ]] || fail "Invalid backup selection: $choice"
	index=$((choice - 1))
	((index >= 0 && index < ${#backups[@]})) || fail "Backup selection out of range: $choice"
	printf '%s' "${backups[$index]}"
}

default_conf_name() {
	local domain="$1"
	local conf_name="${domain//./-}"
	printf '%s' "${conf_name:-n8n}"
}

ENV_FILE="$REPO_ROOT/.env"
CONF_NAME=""
BACKUP_PATH=""
RESTORE_LATEST=0
ASSUME_YES=0
SITES_AVAILABLE_DIR="${SITES_AVAILABLE_DIR:-/etc/nginx/sites-available}"
SITES_ENABLED_DIR="${SITES_ENABLED_DIR:-/etc/nginx/sites-enabled}"

while (($# > 0)); do
	case "$1" in
		--env-file|-e)
			ENV_FILE="${2:-}"
			shift 2
			;;
		--conf-name|-c)
			CONF_NAME="${2:-}"
			shift 2
			;;
		--backup|-b)
			BACKUP_PATH="${2:-}"
			shift 2
			;;
		--latest)
			RESTORE_LATEST=1
			shift
			;;
		--yes|-y)
			ASSUME_YES=1
			shift
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			fail "Unknown argument: $1"
			;;
	esac
done

if [[ -n "$BACKUP_PATH" && "$RESTORE_LATEST" -eq 1 ]]; then
	fail "Use either --backup or --latest for nginx restore"
fi

if [[ -z "$CONF_NAME" ]]; then
	load_env_file "$ENV_FILE"
	CONF_NAME="$(default_conf_name "${N8N_HOST:-}")"
fi

[[ -n "$CONF_NAME" ]] || fail "Conf name cannot be empty"

FINAL_CONF="${SITES_AVAILABLE_DIR}/${CONF_NAME}.conf"
ENABLED_LINK="${SITES_ENABLED_DIR}/${CONF_NAME}.conf"

selection=""
backups=()
current_backup=""

if [[ -n "$BACKUP_PATH" ]]; then
	[[ -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ]] || fail "Nginx backup not found: $BACKUP_PATH"
	selection="$BACKUP_PATH"
else
	mapfile -t backups < <(find_backups_for_conf "$FINAL_CONF")
	((${#backups[@]} > 0)) || fail "No nginx backups found for ${FINAL_CONF}"
	if [[ "$RESTORE_LATEST" -eq 1 ]]; then
		selection="${backups[0]}"
		log "Using latest nginx backup: $selection"
	else
		selection="$(prompt_for_backup_selection "$FINAL_CONF" "${backups[@]}")"
	fi
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
	if ! confirm_yes_no "Restore nginx backup $selection to $FINAL_CONF?"; then
		log "Keeping current nginx config, restore skipped."
		exit 0
	fi
fi

run_root mkdir -p "$SITES_AVAILABLE_DIR" "$SITES_ENABLED_DIR"
current_backup="$(backup_existing_conf "$FINAL_CONF")"
run_root cp -a "$selection" "$FINAL_CONF"
run_root ln -sfn "$FINAL_CONF" "$ENABLED_LINK"

if [[ -n "$current_backup" ]]; then
	log "Backed up current nginx config to ${current_backup}"
fi

log "Validating nginx config..."
run_root nginx -t

log "Enabling and restarting nginx..."
run_root systemctl enable nginx
run_root systemctl restart nginx

log "Success. Restored ${FINAL_CONF} from ${selection}"
