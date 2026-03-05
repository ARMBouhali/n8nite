#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Check system dependencies for this n8n stack.

Usage:
  ./check-deps.sh [options]

Options:
  -e, --env-file PATH   Env file used by auto profile (default: <repo>/.env)
  -p, --profile NAME    core|nginx-http|nginx-https|all|auto (default: auto)
  -q, --quiet           Print only warnings/errors and summary
  -h, --help            Show this help

Profiles:
  core        docker, docker compose, docker group, docker daemon
  nginx-http  core + nginx + sudo + systemctl
  nginx-https nginx-http + certbot
  all         same as nginx-https
  auto        infer from N8N_PROTOCOL in env file:
              http  -> nginx-http
              https -> nginx-https
              no env file -> core
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PROFILE="auto"
QUIET=0

TOTAL=0
PASSED=0
FAILED=0
WARNED=0

supports_color() {
	if [[ -n "${FORCE_COLOR:-}" && "${FORCE_COLOR}" != "0" ]]; then
		return 0
	fi
	if [[ -n "${CLICOLOR_FORCE:-}" && "${CLICOLOR_FORCE}" != "0" ]]; then
		return 0
	fi
	[[ "${TERM:-}" == "dumb" ]] && return 1
	[[ -t 1 || -t 2 ]]
}

log() {
	local reset="" info=""
	if supports_color; then
		reset=$'\033[0m'
		info=$'\033[38;5;118m'
	fi
	if [[ "$QUIET" -eq 0 ]]; then
		printf '%b[INFO]%b %s\n' "$info" "$reset" "$*"
	fi
}

pass() {
	local msg="$1"
	local reset="" ok=""
	if supports_color; then
		reset=$'\033[0m'
		ok=$'\033[38;5;78m'
	fi
	TOTAL=$((TOTAL + 1))
	PASSED=$((PASSED + 1))
	printf '%b[PASS]%b %s\n' "$ok" "$reset" "$msg"
}

warn() {
	local msg="$1"
	local reset="" warn_color=""
	if supports_color; then
		reset=$'\033[0m'
		warn_color=$'\033[38;5;220m'
	fi
	TOTAL=$((TOTAL + 1))
	WARNED=$((WARNED + 1))
	printf '%b[WARN]%b %s\n' "$warn_color" "$reset" "$msg" >&2
}

fail() {
	local msg="$1"
	local fix="${2:-}"
	local reset="" fail_color=""
	if supports_color; then
		reset=$'\033[0m'
		fail_color=$'\033[38;5;203m'
	fi
	TOTAL=$((TOTAL + 1))
	FAILED=$((FAILED + 1))
	printf '%b[FAIL]%b %s\n' "$fail_color" "$reset" "$msg" >&2
	if [[ -n "$fix" ]]; then
		printf '       fix: %s\n' "$fix" >&2
	fi
}

log_error() {
	local reset="" err=""
	if supports_color; then
		reset=$'\033[0m'
		err=$'\033[38;5;203m'
	fi
	printf '%b[ERROR]%b %s\n' "$err" "$reset" "$*" >&2
}

cmd_exists() {
	command -v "$1" >/dev/null 2>&1
}

check_command() {
	local cmd="$1"
	local label="$2"
	local fix="$3"
	if cmd_exists "$cmd"; then
		pass "$label"
	else
		fail "$label" "$fix"
	fi
}

detect_profile_from_env() {
	local protocol=""
	if [[ ! -f "$ENV_FILE" ]]; then
		warn "Env file not found for auto profile: $ENV_FILE (falling back to core)"
		printf 'core'
		return 0
	fi

	protocol="$(
		awk -F= '
			$1=="N8N_PROTOCOL" {
				v=$2
				gsub(/[[:space:]]/, "", v)
				print tolower(v)
				exit
			}
		' "$ENV_FILE"
	)"

	case "$protocol" in
		http) printf 'nginx-http' ;;
		https) printf 'nginx-https' ;;
		*)
			warn "N8N_PROTOCOL missing/invalid in $ENV_FILE (falling back to core)"
			printf 'core'
			;;
	esac
}

check_docker_group() {
	if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
		pass "user '$USER' is in docker group"
	else
		fail \
			"user '$USER' is not in docker group" \
			"sudo usermod -aG docker $USER && newgrp docker | docs: https://docs.docker.com/engine/install/linux-postinstall/"
	fi
}

check_docker_compose() {
	if cmd_exists docker && docker compose version >/dev/null 2>&1; then
		pass "docker compose is available"
	else
		fail \
			"docker compose is not available" \
			"sudo apt-get update && sudo apt-get install -y docker-compose-plugin | docs: https://docs.docker.com/compose/install/linux/"
	fi
}

check_docker_daemon() {
	if cmd_exists docker && docker info >/dev/null 2>&1; then
		pass "docker daemon is reachable"
	else
		fail \
			"docker daemon is not reachable with current user" \
			"sudo systemctl enable --now docker ; ensure docker group membership is active"
	fi
}

check_sudo() {
	if [[ "$EUID" -eq 0 ]]; then
		pass "running as root (sudo not required for deploy steps)"
		return 0
	fi

	if cmd_exists sudo; then
		pass "sudo command is available"
	else
		fail \
			"sudo command is missing" \
			"Install sudo for privileged nginx/certbot deploy steps"
	fi
}

check_core() {
	check_command \
		docker \
		"docker is installed" \
		"sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin | docs: https://docs.docker.com/engine/install/"
	check_docker_compose
	check_docker_group
	check_docker_daemon
}

check_nginx_http() {
	check_core
	check_command \
		nginx \
		"nginx is installed" \
		"sudo apt-get update && sudo apt-get install -y nginx | docs: https://nginx.org/en/linux_packages.html"
	check_sudo
	check_command \
		systemctl \
		"systemctl is available" \
		"Use a systemd-based host or adapt nginx deployment commands for your init system"
}

check_nginx_https() {
	check_nginx_http
	check_command \
		certbot \
		"certbot is installed (required for HTTPS certificate flow)" \
		"Install with snap (recommended): sudo snap install --classic certbot && sudo ln -sf /snap/bin/certbot /usr/bin/certbot"
}

while (($# > 0)); do
	case "$1" in
		--env-file|-e)
			ENV_FILE="${2:-}"
			shift 2
			;;
		--profile|-p)
			PROFILE="${2:-}"
			shift 2
			;;
		--quiet|-q)
			QUIET=1
			shift
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			log_error "Unknown argument: $1"
			usage >&2
			exit 1
			;;
	esac
done

case "$PROFILE" in
	auto)
		RESOLVED_PROFILE="$(detect_profile_from_env)"
		;;
	all)
		RESOLVED_PROFILE="nginx-https"
		;;
	core|nginx-http|nginx-https)
		RESOLVED_PROFILE="$PROFILE"
		;;
	*)
		log_error "Unknown profile: $PROFILE"
		usage >&2
		exit 1
		;;
esac

log "Using dependency profile: $RESOLVED_PROFILE"

case "$RESOLVED_PROFILE" in
	core)
		check_core
		;;
	nginx-http)
		check_nginx_http
		;;
	nginx-https)
		check_nginx_https
		;;
	*)
		log_error "Internal profile resolution error: $RESOLVED_PROFILE"
		exit 1
		;;
esac

printf '\n== Dependency Summary ==\n'
printf 'profile: %s\n' "$RESOLVED_PROFILE"
printf 'total:   %d\n' "$TOTAL"
printf 'passed:  %d\n' "$PASSED"
printf 'warned:  %d\n' "$WARNED"
printf 'failed:  %d\n' "$FAILED"

if [[ "$FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
