#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Generate n8n nginx config files from envsubst templates.

Usage:
  ./nginx/generate-nginx-conf.sh --mode|-m http|https|both --server-name|-s DOMAIN [options]

Options:
  -m, --mode MODE      http, https, or both (default: https)
  -s, --server-name NAME
                       Domain name used in server_name
                     (fallback: SERVER_NAME, then N8N_HOST)
  -u, --upstream ADDR  n8n upstream host:port (default: 127.0.0.1:5678)
  -c, --ssl-cert PATH  SSL certificate path
                     (fallback for https/both: /etc/letsencrypt/live/<server_name>/fullchain.pem)
  -k, --ssl-key PATH   SSL private key path
                     (fallback for https/both: /etc/letsencrypt/live/<server_name>/privkey.pem)
  --certbot-options, --cb-options
                       Certbot SSL options include path
                       (default: /etc/letsencrypt/options-ssl-nginx.conf)
  --certbot-dhparam, --cb-dhparam
                       Certbot DH param file path
                       (default: /etc/letsencrypt/ssl-dhparams.pem)
  -o, --out-dir DIR    Output directory (default: ./nginx/generated)
  -h, --help           Show this help

Environment fallback (used when matching CLI flag is omitted):
  MODE, SERVER_NAME, UPSTREAM, SSL_CERT, SSL_KEY,
  CERTBOT_SSL_OPTIONS, CERTBOT_DHPARAM, OUT_DIR

Examples:
  ./nginx/generate-nginx-conf.sh \
    --mode http \
    --server-name automation.example.com

  ./nginx/generate-nginx-conf.sh \
    --mode https \
    --server-name automation.example.com \
    --ssl-cert /etc/letsencrypt/live/automation.example.com/fullchain.pem \
    --ssl-key /etc/letsencrypt/live/automation.example.com/privkey.pem
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mode=""
mode="${MODE:-https}"
server_name="${SERVER_NAME:-${N8N_HOST:-}}"
upstream="${UPSTREAM:-127.0.0.1:5678}"
ssl_cert="${SSL_CERT:-}"
ssl_key="${SSL_KEY:-}"
certbot_ssl_options="${CERTBOT_SSL_OPTIONS:-/etc/letsencrypt/options-ssl-nginx.conf}"
certbot_dhparam="${CERTBOT_DHPARAM:-/etc/letsencrypt/ssl-dhparams.pem}"
out_dir="${OUT_DIR:-$script_dir/generated}"

	while (($# > 0)); do
		case "$1" in
		--mode|-m)
			mode="${2:-}"
			shift 2
			;;
		--server-name|-s)
			server_name="${2:-}"
			shift 2
			;;
		--upstream|-u)
			upstream="${2:-}"
			shift 2
			;;
		--ssl-cert|-c)
			ssl_cert="${2:-}"
			shift 2
			;;
		--ssl-key|-k)
			ssl_key="${2:-}"
			shift 2
			;;
		--certbot-options|--cb-options)
			certbot_ssl_options="${2:-}"
			shift 2
			;;
		--certbot-dhparam|--cb-dhparam)
			certbot_dhparam="${2:-}"
			shift 2
			;;
		--out-dir|-o)
			out_dir="${2:-}"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done

if [[ -z "$server_name" ]]; then
	echo "Missing server name. Set --server-name or export SERVER_NAME (or N8N_HOST)." >&2
	usage >&2
	exit 1
fi

if [[ "$mode" != "http" && "$mode" != "https" && "$mode" != "both" ]]; then
	echo "--mode must be one of: http, https, both" >&2
	exit 1
fi

if [[ "$mode" == "https" || "$mode" == "both" ]]; then
	if [[ -z "$ssl_cert" ]]; then
		ssl_cert="/etc/letsencrypt/live/${server_name}/fullchain.pem"
	fi
	if [[ -z "$ssl_key" ]]; then
		ssl_key="/etc/letsencrypt/live/${server_name}/privkey.pem"
	fi
	if [[ -z "$ssl_cert" || -z "$ssl_key" ]]; then
		echo "--ssl-cert and --ssl-key are required for mode '$mode'" >&2
		exit 1
	fi
fi

template_dir="$script_dir/templates"
http_template="$template_dir/n8n-http.conf.tmpl"
https_template="$template_dir/n8n-https.conf.tmpl"

if [[ ! -f "$http_template" || ! -f "$https_template" ]]; then
	echo "Template files not found under $template_dir" >&2
	exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
	echo "envsubst is required but not found. Install gettext/gettext-base first." >&2
	exit 1
fi

mkdir -p "$out_dir"

render_template() {
	local template_file="$1"
	local output_file="$2"
	local variables="$3"
	SERVER_NAME="$server_name" \
	UPSTREAM="$upstream" \
	SSL_CERT="$ssl_cert" \
	SSL_KEY="$ssl_key" \
	CERTBOT_SSL_OPTIONS="$certbot_ssl_options" \
	CERTBOT_DHPARAM="$certbot_dhparam" \
		envsubst "$variables" <"$template_file" >"$output_file"
}

generated_files=()

if [[ "$mode" == "http" || "$mode" == "both" ]]; then
	http_out="$out_dir/${server_name}.http.conf"
	render_template "$http_template" "$http_out" '${SERVER_NAME} ${UPSTREAM}'
	generated_files+=("$http_out")
fi

if [[ "$mode" == "https" || "$mode" == "both" ]]; then
	https_out="$out_dir/${server_name}.https.conf"
	render_template "$https_template" "$https_out" '${SERVER_NAME} ${UPSTREAM} ${SSL_CERT} ${SSL_KEY} ${CERTBOT_SSL_OPTIONS} ${CERTBOT_DHPARAM}'
	generated_files+=("$https_out")
fi

echo "Generated nginx config file(s):"
for file in "${generated_files[@]}"; do
	echo "  - $file"
done
echo
echo "Next steps:"
echo "  1) Copy the chosen file to /etc/nginx/sites-available/..."
echo "  2) Enable it in sites-enabled"
echo "  3) Validate and reload: nginx -t && systemctl reload nginx"
