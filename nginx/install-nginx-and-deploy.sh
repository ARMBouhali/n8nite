#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Install nginx (and certbot if needed), generate n8n config from env, review, and deploy.

Usage:
  ./nginx/install-nginx-and-deploy.sh [options]

Options:
  -e, --env-file PATH  Path to env file (default: <repo>/.env)
  -c, --conf-name NAME Nginx conf name without .conf (if omitted, you will be prompted)
  -u, --upstream ADDR  Upstream for n8n proxy (default: 127.0.0.1:5678)
  -m, --email EMAIL    Certbot email (required for new HTTPS cert issuance)
  --help               Show this help

Environment variables:
  N8N_HOST             Domain used in server_name (required; loaded from --env-file)
  N8N_PROTOCOL         http or https (loaded from --env-file, default: https)
  CERTBOT_EMAIL        Optional fallback for --email
  SITES_AVAILABLE_DIR  Override nginx sites-available dir (default: /etc/nginx/sites-available)
  SITES_ENABLED_DIR    Override nginx sites-enabled dir (default: /etc/nginx/sites-enabled)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_CHECK_SCRIPT="$REPO_ROOT/check-env.sh"

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

backup_existing_conf() {
	local target="$1"
	local timestamp backup_path counter

	if run_root test -e "$target" || run_root test -L "$target"; then
		timestamp="$(date +%Y%m%d%H%M%S)"
		backup_path="${target}.bak.${timestamp}"
		counter=0
		while run_root test -e "$backup_path" || run_root test -L "$backup_path"; do
			counter=$((counter + 1))
			backup_path="${target}.bak.${timestamp}.${counter}"
		done
		run_root cp -a "$target" "$backup_path"
		log "Backed up existing config to ${backup_path}"
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

install_dependencies() {
	local protocol="$1"
	if command -v apt-get >/dev/null 2>&1; then
		log "Installing nginx/gettext using apt..."
		run_root apt-get update
		run_root apt-get install -y nginx gettext-base
		if [[ "$protocol" != "http" ]]; then
			log "Installing certbot using apt..."
			run_root apt-get install -y certbot python3-certbot-nginx
		fi
	elif command -v dnf >/dev/null 2>&1; then
		log "Installing nginx/gettext using dnf..."
		run_root dnf install -y nginx gettext
		if [[ "$protocol" != "http" ]]; then
			log "Installing certbot using dnf..."
			run_root dnf install -y certbot python3-certbot-nginx
		fi
	else
		fail "Unsupported package manager. Install nginx, certbot, and envsubst (gettext) manually."
	fi
}

render_config() {
	local mode="$1"
	local domain="$2"
	local upstream="$3"
	local ssl_cert="$4"
	local ssl_key="$5"
	local certbot_options="$6"
	local certbot_dhparam="$7"
	local out_file="$8"
	local template_file variables
	if [[ "$mode" == "http" ]]; then
		template_file="$SCRIPT_DIR/templates/n8n-http.conf.tmpl"
		variables='${SERVER_NAME} ${UPSTREAM}'
	else
		template_file="$SCRIPT_DIR/templates/n8n-https.conf.tmpl"
		variables='${SERVER_NAME} ${UPSTREAM} ${SSL_CERT} ${SSL_KEY} ${CERTBOT_SSL_OPTIONS} ${CERTBOT_DHPARAM}'
	fi

	[[ -f "$template_file" ]] || fail "Template not found: $template_file"
	command -v envsubst >/dev/null 2>&1 || fail "envsubst not found. Install gettext/gettext-base."

	SERVER_NAME="$domain" \
	UPSTREAM="$upstream" \
	SSL_CERT="$ssl_cert" \
	SSL_KEY="$ssl_key" \
	CERTBOT_SSL_OPTIONS="$certbot_options" \
	CERTBOT_DHPARAM="$certbot_dhparam" \
		envsubst "$variables" <"$template_file" >"$out_file"
}

ENV_FILE="$REPO_ROOT/.env"
CONF_NAME=""
UPSTREAM="127.0.0.1:5678"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
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
		--upstream|-u)
			UPSTREAM="${2:-}"
			shift 2
			;;
		--email|-m)
			CERTBOT_EMAIL="${2:-}"
			shift 2
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

[[ -x "$ENV_CHECK_SCRIPT" ]] || fail "Env check script not found or not executable: $ENV_CHECK_SCRIPT"
log "Validating env file before deployment..."
"$ENV_CHECK_SCRIPT" --env-file "$ENV_FILE" --no-compose --quiet

load_env_file "$ENV_FILE"

DOMAIN="${N8N_HOST:-}"
PROTOCOL_RAW="${N8N_PROTOCOL:-https}"
PROTOCOL="$(printf '%s' "$PROTOCOL_RAW" | tr '[:upper:]' '[:lower:]')"
CERTBOT_SSL_OPTIONS="${CERTBOT_SSL_OPTIONS:-/etc/letsencrypt/options-ssl-nginx.conf}"
CERTBOT_DHPARAM="${CERTBOT_DHPARAM:-/etc/letsencrypt/ssl-dhparams.pem}"

[[ -n "$DOMAIN" ]] || fail "N8N_HOST is required in $ENV_FILE"
[[ "$PROTOCOL" == "http" || "$PROTOCOL" == "https" ]] || fail "N8N_PROTOCOL must be http or https in $ENV_FILE"

if [[ -z "$CONF_NAME" ]]; then
	default_conf_name="${DOMAIN//./-}"
	read -r -p "Nginx conf name (without .conf) [${default_conf_name}]: " CONF_NAME_INPUT
	CONF_NAME="${CONF_NAME_INPUT:-$default_conf_name}"
fi
[[ -n "$CONF_NAME" ]] || fail "Conf name cannot be empty"

MODE="$PROTOCOL"
SSL_CERT=""
SSL_KEY=""

install_dependencies "$MODE"

if [[ "$MODE" == "https" ]]; then
	SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
	SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

	if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
		[[ -n "$CERTBOT_EMAIL" ]] || read -r -p "Certbot email for Let's Encrypt: " CERTBOT_EMAIL
		[[ -n "$CERTBOT_EMAIL" ]] || fail "Email is required for certificate creation"

		log "Certificate not found for ${DOMAIN}. Requesting a new certificate..."
		if run_root systemctl is-active --quiet nginx; then
			log "Stopping nginx temporarily for standalone certbot challenge..."
			run_root systemctl stop nginx
		fi

		run_root certbot certonly \
			--standalone \
			--non-interactive \
			--agree-tos \
			--email "$CERTBOT_EMAIL" \
			-d "$DOMAIN" \
			--keep-until-expiring

		[[ -f "$SSL_CERT" && -f "$SSL_KEY" ]] || fail "Certificate creation reported success but cert files are missing"
	fi
fi

TMP_CONF="$(mktemp)"
trap 'rm -f "$TMP_CONF"' EXIT

render_config "$MODE" "$DOMAIN" "$UPSTREAM" "$SSL_CERT" "$SSL_KEY" "$CERTBOT_SSL_OPTIONS" "$CERTBOT_DHPARAM" "$TMP_CONF"

echo
echo "================ Generated nginx config (review) ================"
cat "$TMP_CONF"
echo "================================================================="
echo

read -r -p "Deploy this config as ${CONF_NAME}.conf? [y/N]: " DEPLOY_CONFIRM
[[ "$DEPLOY_CONFIRM" =~ ^[Yy]([Ee][Ss])?$ ]] || fail "Deployment aborted by user"

FINAL_CONF="${SITES_AVAILABLE_DIR}/${CONF_NAME}.conf"
ENABLED_LINK="${SITES_ENABLED_DIR}/${CONF_NAME}.conf"

log "Deploying config to ${FINAL_CONF}"
run_root mkdir -p "$SITES_AVAILABLE_DIR" "$SITES_ENABLED_DIR"
backup_existing_conf "$FINAL_CONF"
run_root cp "$TMP_CONF" "$FINAL_CONF"
run_root ln -sfn "$FINAL_CONF" "$ENABLED_LINK"

log "Validating nginx config..."
run_root nginx -t

log "Enabling and restarting nginx..."
run_root systemctl enable nginx
run_root systemctl restart nginx

log "Success. Deployed ${FINAL_CONF}"
