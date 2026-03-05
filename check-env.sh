#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Validate n8n .env configuration for this repository.

Usage:
  ./check-env.sh [options]

Options:
  -e, --env-file PATH   Path to env file (default: <repo>/.env)
  -n, --no-compose      Skip docker compose interpolation/config validation
  -q, --quiet           Print only warnings/errors
  -h, --help        Show this help

What it validates:
  1) required variables are present and non-empty
  2) N8N_PROTOCOL and URL scheme consistency
  3) WEBHOOK_URL host matches N8N_HOST
  4) required encryption key is present for queue worker mode
  5) common placeholder values are not left unchanged
  6) docker compose config resolves (unless --no-compose is used)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
ENV_FILE="$REPO_ROOT/.env"
CHECK_COMPOSE=1
QUIET=0

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

warn() {
	local reset="" warn_color=""
	if supports_color; then
		reset=$'\033[0m'
		warn_color=$'\033[38;5;220m'
	fi
	printf '%b[WARN]%b %s\n' "$warn_color" "$reset" "$*" >&2
}

fail() {
	local reset="" err=""
	if supports_color; then
		reset=$'\033[0m'
		err=$'\033[38;5;203m'
	fi
	printf '%b[ERROR]%b %s\n' "$err" "$reset" "$*" >&2
	exit 1
}

load_env_file() {
	local file="$1"
	[[ -f "$file" ]] || fail "Env file not found: $file"
	set -a
	# shellcheck disable=SC1090
	source "$file"
	set +a
}

require_non_empty() {
	local var_name="$1"
	local value="${!var_name:-}"
	[[ -n "$value" ]] || fail "Missing required variable: $var_name"
}

url_scheme() {
	local url="$1"
	case "$url" in
		http://*) printf 'http' ;;
		https://*) printf 'https' ;;
		*) printf '' ;;
	esac
}

url_host() {
	local url="$1"
	local without_scheme host_port
	without_scheme="${url#*://}"
	host_port="${without_scheme%%/*}"
	printf '%s' "${host_port%%:*}"
}

validate_url_var() {
	local var_name="$1"
	local value="$2"
	local expected_protocol="$3"
	local expected_host="$4"
	local actual_protocol actual_host

	actual_protocol="$(url_scheme "$value")"
	[[ -n "$actual_protocol" ]] || fail "$var_name must start with http:// or https://"
	[[ "$actual_protocol" == "$expected_protocol" ]] || fail "$var_name protocol ($actual_protocol) must match N8N_PROTOCOL ($expected_protocol)"

	actual_host="$(url_host "$value")"
	[[ -n "$actual_host" ]] || fail "$var_name host is empty"
	[[ "$actual_host" == "$expected_host" ]] || fail "$var_name host ($actual_host) must match N8N_HOST ($expected_host)"
}

validate_required_variables() {
	local required=(
		N8N_HOST
		N8N_PROTOCOL
		WEBHOOK_URL
		N8N_ENCRYPTION_KEY
		POSTGRES_USER
		POSTGRES_PASSWORD
		POSTGRES_DB
		POSTGRES_NON_ROOT_USER
		POSTGRES_NON_ROOT_PASSWORD
	)

	for var_name in "${required[@]}"; do
		require_non_empty "$var_name"
	done
}

validate_placeholders() {
	local check_vars=(
		N8N_HOST
		WEBHOOK_URL
		N8N_ENCRYPTION_KEY
		POSTGRES_USER
		POSTGRES_PASSWORD
		POSTGRES_NON_ROOT_USER
		POSTGRES_NON_ROOT_PASSWORD
	)
	local var_name value

	for var_name in "${check_vars[@]}"; do
		value="${!var_name:-}"
		if [[ "$value" == *change_me* ]]; then
			fail "$var_name still contains placeholder text: $value"
		fi
	done

	[[ "${N8N_HOST}" != "automation.example.com" ]] || fail "N8N_HOST is still the example placeholder value"
	[[ "${WEBHOOK_URL}" != "https://automation.example.com/" ]] || fail "WEBHOOK_URL is still the example placeholder value"

	if [[ "${N8N_PROTOCOL}" == "https" && "${CERTBOT_EMAIL:-}" == "admin@example.com" ]]; then
		warn "CERTBOT_EMAIL is still the placeholder value; cert creation may fail if a new cert is needed"
	fi
}

validate_n8n_values() {
	local protocol
	protocol="$(printf '%s' "${N8N_PROTOCOL}" | tr '[:upper:]' '[:lower:]')"
	[[ "$protocol" == "http" || "$protocol" == "https" ]] || fail "N8N_PROTOCOL must be either http or https"

	if [[ "${N8N_HOST}" == *:* ]]; then
		fail "N8N_HOST should be host/domain only (no port): ${N8N_HOST}"
	fi

	validate_url_var "WEBHOOK_URL" "${WEBHOOK_URL}" "$protocol" "${N8N_HOST}"
	if [[ "${WEBHOOK_URL}" != */ ]]; then
		warn "WEBHOOK_URL usually ends with a trailing slash"
	fi

	if [[ -n "${WEBHOOK_TUNNEL_URL:-}" ]]; then
		validate_url_var "WEBHOOK_TUNNEL_URL" "${WEBHOOK_TUNNEL_URL}" "$protocol" "${N8N_HOST}"
	fi

	if [[ -n "${VUE_APP_URL_BASE_API:-}" ]]; then
		validate_url_var "VUE_APP_URL_BASE_API" "${VUE_APP_URL_BASE_API}" "$protocol" "${N8N_HOST}"
		if [[ "${VUE_APP_URL_BASE_API}" != */api && "${VUE_APP_URL_BASE_API}" != */api/ ]]; then
			warn "VUE_APP_URL_BASE_API usually ends with /api"
		fi
	fi

	if [[ "${#N8N_ENCRYPTION_KEY}" -lt 32 ]]; then
		warn "N8N_ENCRYPTION_KEY is short; at least 32 characters is recommended"
	fi

	if [[ "${POSTGRES_USER}" == "${POSTGRES_NON_ROOT_USER}" ]]; then
		warn "POSTGRES_USER and POSTGRES_NON_ROOT_USER are identical; a dedicated app user is recommended"
	fi
}

validate_compose_config() {
	[[ -f "$REPO_ROOT/docker-compose.yml" ]] || fail "docker-compose.yml not found in $REPO_ROOT"
	command -v docker >/dev/null 2>&1 || fail "docker command not found (or use --no-compose)"
	docker compose --env-file "$ENV_FILE" -f "$REPO_ROOT/docker-compose.yml" config >/dev/null
}

while (($# > 0)); do
	case "$1" in
		--env-file|-e)
			ENV_FILE="${2:-}"
			shift 2
			;;
		--no-compose|-n)
			CHECK_COMPOSE=0
			shift
			;;
		--quiet|-q)
			QUIET=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			fail "Unknown argument: $1"
			;;
	esac
done

log "Validating env file: $ENV_FILE"
load_env_file "$ENV_FILE"
validate_required_variables
validate_placeholders
validate_n8n_values

if [[ "$CHECK_COMPOSE" -eq 1 ]]; then
	log "Running docker compose config validation..."
	validate_compose_config
fi

log "Validation successful: $ENV_FILE"
