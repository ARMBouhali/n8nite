#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Install nginx if needed, then generate n8n config from env, review, and deploy.

Usage:
  ./nginx/install-nginx-and-deploy.sh [options]

Options:
  -e, --env-file PATH  Path to env file (default: <repo>/.env)
  -c, --conf-name NAME Nginx conf name without .conf
                       (default: N8N_HOST with dots replaced by dashes)
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

escape_sed_replacement() {
	printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

render_template_file() {
	local template_file="$1"
	local output_file="$2"
	shift 2
	local sed_args=()
	local key="" value="" escaped_value=""

	while (($# > 0)); do
		key="$1"
		value="$2"
		shift 2
		escaped_value="$(escape_sed_replacement "$value")"
		sed_args+=(-e "s|\${${key}}|${escaped_value}|g")
	done

	sed "${sed_args[@]}" "$template_file" >"$output_file"
}

log() {
	printf '[INFO] %s\n' "$*"
}

confirm_yes_no() {
	local label="$1"
	local answer=""
	read -r -p "$label [y/N]: " answer
	[[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
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
		timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
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

install_nginx_package() {
	if command -v apt-get >/dev/null 2>&1; then
		log "Installing nginx using apt..."
		run_root apt-get update
		run_root apt-get install -y nginx
	elif command -v dnf >/dev/null 2>&1; then
		log "Installing nginx using dnf..."
		run_root dnf install -y nginx
	else
		fail "Unsupported package manager. Install nginx manually before deploying."
	fi
}

ensure_nginx_available() {
	if command -v nginx >/dev/null 2>&1; then
		return 0
	fi

	if ! confirm_yes_no "nginx is not installed. Install it now?"; then
		fail "nginx is required for deployment"
	fi

	install_nginx_package
	command -v nginx >/dev/null 2>&1 || fail "nginx installation completed but nginx is still unavailable in PATH"
}

certbot_snap_install_hint() {
	printf '%s' "Install certbot with snap (recommended): sudo snap install --classic certbot && sudo ln -sf /snap/bin/certbot /usr/bin/certbot"
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
	local template_file
	if [[ "$mode" == "http" ]]; then
		template_file="$SCRIPT_DIR/templates/n8n-http.conf.tmpl"
	else
		template_file="$SCRIPT_DIR/templates/n8n-https.conf.tmpl"
	fi

	[[ -f "$template_file" ]] || fail "Template not found: $template_file"
	render_template_file \
		"$template_file" \
		"$out_file" \
		SERVER_NAME "$domain" \
		UPSTREAM "$upstream" \
		SSL_CERT "$ssl_cert" \
		SSL_KEY "$ssl_key" \
		CERTBOT_SSL_OPTIONS "$certbot_options" \
		CERTBOT_DHPARAM "$certbot_dhparam"
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
	CONF_NAME="${default_conf_name:-n8n}"
fi
[[ -n "$CONF_NAME" ]] || fail "Conf name cannot be empty"

MODE="$PROTOCOL"
SSL_CERT=""
SSL_KEY=""

ensure_nginx_available

if [[ "$MODE" == "https" ]]; then
	SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
	SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

	if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
		command -v certbot >/dev/null 2>&1 || fail "certbot is required to create a new certificate for ${DOMAIN}. $(certbot_snap_install_hint)"
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
log "Restore a prior backup with: ./n8nite nginx restore -c ${CONF_NAME}"
