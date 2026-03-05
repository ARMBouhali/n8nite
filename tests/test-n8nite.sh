#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
Run n8n wrapper test suite.

Usage:
  ./tests/test-n8nite.sh [options]

Options:
  -r, --requirements-only   Run only system requirement checks
  -f, --functional-only     Run only functional CLI tests
  -h, --help            Show this help

What it checks:
  1) system prerequisites:
     - docker installed
     - docker compose available
     - current user in docker group
     - docker daemon reachable
     - nginx installed
     - envsubst installed
     - certbot installed when .env protocol is https
  2) n8nite behavior:
     - help/unknown command handling
     - env init/check flow
     - env validation matrix (protocol/host/placeholder)
     - env key generation flow
     - env key generation force guard
     - deps check command wiring
     - deps profile execution matrix
     - install script sanity
     - install rc persistence in isolated HOME
     - nginx generate flow
     - nginx deploy path in sandboxed temp dirs
     - interactive mode exit flow
     - queue service declarations in compose file
     - docker compose delegation (mocked)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
N8N_SCRIPT="$REPO_ROOT/n8nite"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
NGINX_DEPLOY_SCRIPT="$REPO_ROOT/nginx/install-nginx-and-deploy.sh"
ENV_LOCAL_TEMPLATE="$REPO_ROOT/.env.local.example"
ENV_FILE_DEFAULT="$REPO_ROOT/.env"

RUN_REQUIREMENTS=1
RUN_FUNCTIONAL=1

TOTAL=0
PASSED=0
FAILED=0

pass() {
	local message="$1"
	TOTAL=$((TOTAL + 1))
	PASSED=$((PASSED + 1))
	printf '[PASS] %s\n' "$message"
}

fail() {
	local message="$1"
	local suggestion="${2:-}"
	TOTAL=$((TOTAL + 1))
	FAILED=$((FAILED + 1))
	printf '[FAIL] %s\n' "$message"
	if [[ -n "$suggestion" ]]; then
		printf '       fix: %s\n' "$suggestion"
	fi
}

run_and_capture() {
	local out_var="$1"
	shift
	local captured_output rc

	set +e
	captured_output="$("$@" 2>&1)"
	rc=$?
	set -e

	printf -v "$out_var" '%s' "$captured_output"
	return "$rc"
}

check_contains() {
	local haystack="$1"
	local needle="$2"
	[[ "$haystack" == *"$needle"* ]]
}

resolve_protocol_for_requirement_check() {
	local protocol="unknown"
	if [[ -f "$ENV_FILE_DEFAULT" ]]; then
		protocol="$(
			awk -F= '
				$1=="N8N_PROTOCOL" {
					v=$2
					gsub(/[[:space:]]/, "", v)
					print tolower(v)
					exit
				}
			' "$ENV_FILE_DEFAULT"
		)"
	fi
	printf '%s' "${protocol:-unknown}"
}

create_deps_mock_bin() {
	local dir="$1"
	local include_certbot="$2"
	local docker_mode="${3:-ok}"

	mkdir -p "$dir"

	cat >"$dir/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mode="${docker_mode}"
if [[ "\${1:-}" == "compose" && "\${2:-}" == "version" ]]; then
	exit 0
fi
if [[ "\${1:-}" == "info" ]]; then
	if [[ "\$mode" == "fail-daemon" ]]; then
		exit 1
	fi
	exit 0
fi
exit 0
EOF

	cat >"$dir/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-nG" ]]; then
	printf 'docker\n'
	exit 0
fi
exit 0
EOF

	cat >"$dir/nginx" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

	cat >"$dir/envsubst" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

	cat >"$dir/sudo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

	cat >"$dir/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

	if [[ "$include_certbot" -eq 1 ]]; then
		cat >"$dir/certbot" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	fi

	chmod +x "$dir/docker" "$dir/id" "$dir/nginx" "$dir/envsubst" "$dir/sudo" "$dir/systemctl"
	if [[ "$include_certbot" -eq 1 ]]; then
		chmod +x "$dir/certbot"
	fi

	ln -sf "$(command -v bash)" "$dir/bash"
	ln -sf "$(command -v dirname)" "$dir/dirname"
	ln -sf "$(command -v awk)" "$dir/awk"
	ln -sf "$(command -v grep)" "$dir/grep"
	ln -sf "$(command -v tr)" "$dir/tr"
}

create_install_mock_bin() {
	local dir="$1"
	mkdir -p "$dir"

	cat >"$dir/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "clone" ]]; then
	dest="${@: -1}"
	mkdir -p "$dest/.git"
	cp "${MOCK_INSTALL_SOURCE:?}" "$dest/n8nite"
	exit 0
fi
if [[ "${1:-}" == "-C" ]]; then
	# fetch/checkout/pull update path is accepted as a no-op in this mock.
	exit 0
fi
exit 0
EOF

	chmod +x "$dir/git"
}

create_nginx_deploy_mock_bin() {
	local dir="$1"
	mkdir -p "$dir"

	cat >"$dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_SUDO_LOG:-}" ]]; then
	printf '%s\n' "$*" >>"$MOCK_SUDO_LOG"
fi
exec "$@"
EOF

	cat >"$dir/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_APT_LOG:-}" ]]; then
	printf '%s\n' "$*" >>"$MOCK_APT_LOG"
fi
exit 0
EOF

	cat >"$dir/nginx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-t" ]]; then
	exit 0
fi
exit 0
EOF

	cat >"$dir/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_SYSTEMCTL_LOG:-}" ]]; then
	printf '%s\n' "$*" >>"$MOCK_SYSTEMCTL_LOG"
fi
exit 0
EOF

	cat >"$dir/envsubst" <<'EOF'
#!/usr/bin/env bash
cat
EOF

	chmod +x "$dir/sudo" "$dir/apt-get" "$dir/nginx" "$dir/systemctl" "$dir/envsubst"
}

check_requirements() {
	printf '\n== Requirement checks ==\n'

	if command -v docker >/dev/null 2>&1; then
		pass "docker is installed"
	else
		fail \
			"docker is not installed" \
			"sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin | docs: https://docs.docker.com/engine/install/"
	fi

	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		pass "docker compose is available"
	else
		fail \
			"docker compose is not available" \
			"sudo apt-get update && sudo apt-get install -y docker-compose-plugin | docs: https://docs.docker.com/compose/install/linux/"
	fi

	if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
		pass "user '$USER' is in docker group"
	else
		fail \
			"user '$USER' is not in docker group" \
			"sudo usermod -aG docker $USER && newgrp docker | docs: https://docs.docker.com/engine/install/linux-postinstall/"
	fi

	if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
		pass "docker daemon is reachable"
	else
		fail \
			"docker daemon is not reachable with current user" \
			"sudo systemctl enable --now docker ; ensure docker group membership is active"
	fi

	if command -v nginx >/dev/null 2>&1; then
		pass "nginx is installed"
	else
		fail \
			"nginx is not installed" \
			"sudo apt-get update && sudo apt-get install -y nginx | docs: https://nginx.org/en/linux_packages.html"
	fi

	if command -v envsubst >/dev/null 2>&1; then
		pass "envsubst is installed"
	else
		fail \
			"envsubst is not installed" \
			"sudo apt-get update && sudo apt-get install -y gettext-base"
	fi

	case "$(resolve_protocol_for_requirement_check)" in
		https)
			if command -v certbot >/dev/null 2>&1; then
				pass "certbot is installed for https profile"
			else
				fail \
					"certbot is not installed (N8N_PROTOCOL=https in .env)" \
					"sudo apt-get update && sudo apt-get install -y certbot python3-certbot-nginx | docs: https://certbot.eff.org/"
			fi
			;;
		http)
			pass "certbot check skipped (.env uses N8N_PROTOCOL=http)"
			;;
		*)
			pass "certbot check skipped (.env missing or N8N_PROTOCOL undefined)"
			;;
	esac
}

functional_help_and_errors() {
	local output=""

	if run_and_capture output "$N8N_SCRIPT" --help \
		&& check_contains "$output" "n8nite :: opinionated n8n stack on wheels" \
		&& check_contains "$output" "Unified entrypoint for this n8n stack." \
		&& check_contains "$output" "uninstall [args...]" \
		&& check_contains "$output" "env view [args...]" \
		&& check_contains "$output" "env edit [args...]"; then
		pass "n8nite --help prints banner and usage"
	else
		fail "n8nite --help failed or banner/usage text changed"
	fi

	if run_and_capture output "$N8N_SCRIPT" \
		&& check_contains "$output" "n8nite :: opinionated n8n stack on wheels" \
		&& check_contains "$output" "Unified entrypoint for this n8n stack."; then
		pass "n8nite without args prints banner and usage"
	else
		fail "n8nite without args failed or banner/usage text changed"
	fi

	if run_and_capture output "$N8N_SCRIPT" --version \
		&& check_contains "$output" "n8nite :: opinionated n8n stack on wheels" \
		&& check_contains "$output" "n8nite "; then
		pass "n8nite --version prints banner and version"
	else
		fail "n8nite --version failed or banner/version text changed"
	fi

	if run_and_capture output "$N8N_SCRIPT" unknown-command; then
		fail "n8nite unknown command should fail"
	else
		if check_contains "$output" "Unknown command"; then
			pass "n8nite unknown command returns clear error"
		else
			fail "n8nite unknown command error message is missing"
		fi
	fi
}

functional_env_flow() {
	local tmp_dir env_file output bad_env
	tmp_dir="$(mktemp -d)"
	env_file="$tmp_dir/test.env"
	bad_env="$tmp_dir/bad.env"

	if run_and_capture output "$N8N_SCRIPT" --env-file "$env_file" env init local && [[ -f "$env_file" ]]; then
		pass "env init local creates target env file"
	else
		fail "env init local failed"
	fi

	if grep -q '^N8N_HOST=localhost$' "$env_file"; then
		pass "env init local writes localhost defaults"
	else
		fail "env init local content mismatch"
	fi

	if run_and_capture output "$N8N_SCRIPT" --env-file "$env_file" env check --no-compose; then
		pass "env check --no-compose succeeds for local template"
	else
		fail "env check --no-compose should pass for local template"
	fi

	cat >"$bad_env" <<'EOF'
N8N_HOST=localhost
N8N_PROTOCOL=http
WEBHOOK_URL=http://localhost:5678/
POSTGRES_USER=admin
POSTGRES_PASSWORD=admin
POSTGRES_DB=n8n
POSTGRES_NON_ROOT_USER=n8n_user
EOF

	if run_and_capture output "$N8N_SCRIPT" --env-file "$bad_env" env check --no-compose; then
		fail "env check should fail on missing required variable"
	else
		if check_contains "$output" "Missing required variable"; then
			pass "env check reports missing required variable"
		else
			fail "env check failed but missing-variable message was not found"
		fi
	fi

	rm -rf "$tmp_dir"
}

functional_env_validation_matrix() {
	local tmp_dir output protocol_env host_env placeholder_env
	local key="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	tmp_dir="$(mktemp -d)"
	protocol_env="$tmp_dir/protocol.env"
	host_env="$tmp_dir/host.env"
	placeholder_env="$tmp_dir/placeholder.env"

	cat >"$protocol_env" <<EOF
N8N_HOST=automation.test
N8N_PROTOCOL=https
WEBHOOK_URL=http://automation.test/
N8N_ENCRYPTION_KEY=$key
POSTGRES_USER=admin
POSTGRES_PASSWORD=admin_pass
POSTGRES_DB=n8n
POSTGRES_NON_ROOT_USER=n8n_user
POSTGRES_NON_ROOT_PASSWORD=n8n_user_pass
EOF

	if run_and_capture output "$N8N_SCRIPT" --env-file "$protocol_env" env check --no-compose; then
		fail "env check should fail on protocol mismatch"
	else
		if check_contains "$output" "must match N8N_PROTOCOL"; then
			pass "env check reports protocol mismatch"
		else
			fail "env check protocol mismatch message was not found"
		fi
	fi

	cat >"$host_env" <<EOF
N8N_HOST=automation.test
N8N_PROTOCOL=http
WEBHOOK_URL=http://other.test/
N8N_ENCRYPTION_KEY=$key
POSTGRES_USER=admin
POSTGRES_PASSWORD=admin_pass
POSTGRES_DB=n8n
POSTGRES_NON_ROOT_USER=n8n_user
POSTGRES_NON_ROOT_PASSWORD=n8n_user_pass
EOF

	if run_and_capture output "$N8N_SCRIPT" --env-file "$host_env" env check --no-compose; then
		fail "env check should fail on host mismatch"
	else
		if check_contains "$output" "must match N8N_HOST"; then
			pass "env check reports host mismatch"
		else
			fail "env check host mismatch message was not found"
		fi
	fi

	cat >"$placeholder_env" <<EOF
N8N_HOST=automation.test
N8N_PROTOCOL=http
WEBHOOK_URL=http://automation.test/
N8N_ENCRYPTION_KEY=$key
POSTGRES_USER=change_me_admin
POSTGRES_PASSWORD=admin_pass
POSTGRES_DB=n8n
POSTGRES_NON_ROOT_USER=n8n_user
POSTGRES_NON_ROOT_PASSWORD=n8n_user_pass
EOF

	if run_and_capture output "$N8N_SCRIPT" --env-file "$placeholder_env" env check --no-compose; then
		fail "env check should fail on placeholder values"
	else
		if check_contains "$output" "still contains placeholder text"; then
			pass "env check reports placeholder values"
		else
			fail "env check placeholder message was not found"
		fi
	fi

	rm -rf "$tmp_dir"
}

functional_env_keygen() {
	local output tmp_dir env_file old_key new_key
	tmp_dir="$(mktemp -d)"
	env_file="$tmp_dir/local.env"
	cp "$ENV_LOCAL_TEMPLATE" "$env_file"
	old_key="$(grep '^N8N_ENCRYPTION_KEY=' "$env_file" | cut -d= -f2- || true)"

	if run_and_capture output "$N8N_SCRIPT" env keygen --plain; then
		if [[ "$output" =~ ^[0-9a-f]{64}$ ]]; then
			pass "env keygen --plain outputs a 256-bit hex key"
		else
			fail "env keygen --plain output format is invalid"
		fi
	else
		fail "env keygen --plain failed"
	fi

	if run_and_capture output "$N8N_SCRIPT" --env-file "$env_file" env keygen --write --plain; then
		fail "env keygen --write should fail when key exists without --force"
	else
		if check_contains "$output" "already exists"; then
			pass "env keygen --write fails clearly when --force is missing"
		else
			fail "env keygen --write failed but force-guard message was not found"
		fi
	fi

	if run_and_capture output "$N8N_SCRIPT" --env-file "$env_file" env keygen --write --force --plain; then
		new_key="$(grep '^N8N_ENCRYPTION_KEY=' "$env_file" | cut -d= -f2- || true)"
		if [[ "$new_key" =~ ^[0-9a-f]{64}$ && "$new_key" != "$old_key" ]]; then
			pass "env keygen --write --force updates env file key"
		else
			fail "env keygen --write --force did not set a valid new key"
		fi
	else
		fail "env keygen --write --force failed"
	fi

	rm -rf "$tmp_dir"
}

functional_env_view_edit() {
	local tmp_dir env_file output mock_bin vi_log nano_log
	tmp_dir="$(mktemp -d)"
	env_file="$tmp_dir/local.env"
	mock_bin="$tmp_dir/mock-bin"
	vi_log="$tmp_dir/vi.log"
	nano_log="$tmp_dir/nano.log"
	cp "$ENV_LOCAL_TEMPLATE" "$env_file"
	mkdir -p "$mock_bin"

	cat >"$mock_bin/less" <<'EOF'
#!/usr/bin/env bash
cat "$1"
EOF

	cat >"$mock_bin/nano" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_NANO_LOG:-}" ]]; then
	printf '%s\n' "$*" >>"$MOCK_NANO_LOG"
fi
if [[ "${1:-}" == "-v" ]]; then
	shift
	cat "$1"
	exit 0
fi
if [[ "${MOCK_NANO_FAIL:-0}" == "1" ]]; then
	exit 1
fi
printf '\n# edited-by-mock-nano\n' >>"$1"
exit 0
EOF

	cat >"$mock_bin/vi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_VI_LOG:?}"
exit 0
EOF

	chmod +x "$mock_bin/less" "$mock_bin/nano" "$mock_bin/vi"

	if run_and_capture output env PATH="$mock_bin:$PATH" MOCK_NANO_LOG="$nano_log" "$N8N_SCRIPT" --env-file "$env_file" env view; then
		if check_contains "$output" "N8N_HOST=localhost" && grep -Fq -- "-v $env_file" "$nano_log"; then
			pass "env view uses nano -v when available"
		else
			fail "env view did not use nano -v as expected"
		fi
	else
		fail "env view failed"
	fi

	if run_and_capture output env PATH="$mock_bin:$PATH" MOCK_NANO_LOG="$nano_log" "$N8N_SCRIPT" --env-file "$env_file" env edit; then
		if grep -Fq "# edited-by-mock-nano" "$env_file"; then
			pass "env edit uses nano when available"
		else
			fail "env edit did not modify env file through nano path"
		fi
	else
		fail "env edit failed on nano path"
	fi

	if run_and_capture output env PATH="$mock_bin:$PATH" MOCK_NANO_FAIL=1 MOCK_VI_LOG="$vi_log" "$N8N_SCRIPT" --env-file "$env_file" env edit; then
		if grep -Fq "syntax on" "$vi_log" && grep -Fq "set filetype=sh" "$vi_log"; then
			pass "env edit falls back to vi with syntax commands when nano fails"
		else
			fail "env edit vi fallback did not pass syntax commands"
		fi
	else
		fail "env edit failed on vi fallback path"
	fi

	rm -rf "$tmp_dir"
}

functional_deps_command() {
	local output="" tmp_dir mock_ok mock_no_cert http_env https_env bad_env
	tmp_dir="$(mktemp -d)"
	mock_ok="$tmp_dir/mock-ok"
	mock_no_cert="$tmp_dir/mock-no-cert"
	http_env="$tmp_dir/http.env"
	https_env="$tmp_dir/https.env"
	bad_env="$tmp_dir/bad.env"

	create_deps_mock_bin "$mock_ok" 1 "ok"
	create_deps_mock_bin "$mock_no_cert" 0 "ok"

	cat >"$http_env" <<'EOF'
N8N_PROTOCOL=http
EOF

	cat >"$https_env" <<'EOF'
N8N_PROTOCOL=https
EOF

	cat >"$bad_env" <<'EOF'
N8N_PROTOCOL=invalid
EOF

	if run_and_capture output "$N8N_SCRIPT" deps check --help && check_contains "$output" "Check system dependencies"; then
		pass "n8nite deps check --help works"
	else
		fail "n8nite deps check --help failed or usage text changed"
	fi

	if run_and_capture output env PATH="$mock_ok" USER=tester "$N8N_SCRIPT" --env-file "$http_env" deps check; then
		if check_contains "$output" "profile: nginx-http"; then
			pass "deps check auto profile resolves to nginx-http for N8N_PROTOCOL=http"
		else
			fail "deps check auto profile did not resolve to nginx-http"
		fi
	else
		fail "deps check auto profile failed for N8N_PROTOCOL=http"
	fi

	if run_and_capture output env PATH="$mock_ok" USER=tester "$N8N_SCRIPT" --env-file "$https_env" deps check; then
		if check_contains "$output" "profile: nginx-https"; then
			pass "deps check auto profile resolves to nginx-https for N8N_PROTOCOL=https"
		else
			fail "deps check auto profile did not resolve to nginx-https"
		fi
	else
		fail "deps check auto profile failed for N8N_PROTOCOL=https"
	fi

	if run_and_capture output env PATH="$mock_ok" USER=tester "$N8N_SCRIPT" --env-file "$bad_env" deps check; then
		if check_contains "$output" "profile: core"; then
			pass "deps check auto profile falls back to core for invalid protocol"
		else
			fail "deps check auto profile did not fall back to core"
		fi
	else
		fail "deps check auto fallback failed for invalid protocol"
	fi

	if run_and_capture output env PATH="$mock_no_cert" USER=tester "$N8N_SCRIPT" --env-file "$https_env" deps check --profile nginx-https; then
		fail "deps check nginx-https should fail when certbot is missing"
	else
		if check_contains "$output" "certbot is installed"; then
			pass "deps check reports missing certbot in nginx-https profile"
		else
			fail "deps check failed without expected certbot error message"
		fi
	fi

	rm -rf "$tmp_dir"
}

functional_install_script() {
	local output="" tmp_dir mock_bin home_dir rc_bash rc_zsh path_line
	local marker_start='# >>> n8nite PATH >>>'
	local marker_end='# <<< n8nite PATH <<<'

	if [[ -x "$INSTALL_SCRIPT" ]]; then
		pass "install.sh exists and is executable"
	else
		fail "install.sh is missing or not executable"
		return
	fi

	if run_and_capture output bash -n "$INSTALL_SCRIPT"; then
		pass "install.sh syntax is valid"
	else
		fail "install.sh has syntax errors"
	fi

	if run_and_capture output "$INSTALL_SCRIPT" --help && check_contains "$output" "Install n8nite from git."; then
		pass "install.sh --help works"
	else
		fail "install.sh --help failed or usage text changed"
	fi

	if run_and_capture output "$INSTALL_SCRIPT" --help && check_contains "$output" "N8N_SH_PERSIST_RC"; then
		pass "install.sh documents rc persistence option"
	else
		fail "install.sh help is missing N8N_SH_PERSIST_RC"
	fi

	if run_and_capture output "$INSTALL_SCRIPT" --help && check_contains "$output" "~/.local/share/n8nite"; then
		pass "install.sh help documents default clone path"
	else
		fail "install.sh help is missing default clone path text"
	fi

	tmp_dir="$(mktemp -d)"
	mock_bin="$tmp_dir/mock-bin"
	home_dir="$tmp_dir/home"
	rc_bash="$home_dir/.bashrc"
	rc_zsh="$home_dir/.zshrc"
	path_line="export PATH=\"$home_dir/.local/bin:\$PATH\""
	mkdir -p "$home_dir"
	create_install_mock_bin "$mock_bin"

	if run_and_capture output \
		env \
		PATH="$mock_bin:$PATH" \
		HOME="$home_dir" \
		MOCK_INSTALL_SOURCE="$N8N_SCRIPT" \
		"$INSTALL_SCRIPT"; then
		pass "install.sh runs in isolated HOME without touching real user shell files"
	else
		fail "install.sh failed in isolated HOME"
		rm -rf "$tmp_dir"
		return
	fi

	if [[ -L "$home_dir/.local/bin/n8nite" ]]; then
		pass "install.sh creates command symlink in isolated bin dir"
	else
		fail "install.sh did not create isolated command symlink"
	fi

	if [[ -f "$rc_bash" && -f "$rc_zsh" ]]; then
		pass "install.sh created isolated bashrc/zshrc files"
	else
		fail "install.sh did not create isolated bashrc/zshrc files"
	fi

	if grep -Fq "$marker_start" "$rc_bash" && grep -Fq "$marker_end" "$rc_bash" && grep -Fq "$path_line" "$rc_bash"; then
		pass "install.sh persisted PATH block in isolated .bashrc"
	else
		fail "install.sh PATH block missing in isolated .bashrc"
	fi

	if grep -Fq "$marker_start" "$rc_zsh" && grep -Fq "$marker_end" "$rc_zsh" && grep -Fq "$path_line" "$rc_zsh"; then
		pass "install.sh persisted PATH block in isolated .zshrc"
	else
		fail "install.sh PATH block missing in isolated .zshrc"
	fi

	if run_and_capture output \
		env \
		PATH="$mock_bin:$PATH" \
		HOME="$home_dir" \
		MOCK_INSTALL_SOURCE="$N8N_SCRIPT" \
		"$INSTALL_SCRIPT"; then
		if [[ "$(grep -Fc "$marker_start" "$rc_bash")" -eq 1 && "$(grep -Fc "$marker_start" "$rc_zsh")" -eq 1 ]]; then
			pass "install.sh PATH persistence is idempotent"
		else
			fail "install.sh duplicated PATH blocks across reruns"
		fi
	else
		fail "install.sh rerun failed in isolated HOME"
	fi

	rm -rf "$tmp_dir"
}

functional_symlink_repo_resolution() {
	local tmp_dir repo_dir bin_dir env_file output
	tmp_dir="$(mktemp -d)"
	repo_dir="$tmp_dir/repo"
	bin_dir="$tmp_dir/bin"
	env_file="$tmp_dir/local.env"

	mkdir -p "$repo_dir" "$bin_dir"
	cp "$N8N_SCRIPT" "$repo_dir/n8nite"
	cp "$ENV_LOCAL_TEMPLATE" "$repo_dir/.env.local.example"
	chmod +x "$repo_dir/n8nite"
	ln -s "$repo_dir/n8nite" "$bin_dir/n8nite"

	if run_and_capture output "$bin_dir/n8nite" --env-file "$env_file" env init local; then
		if [[ -f "$env_file" ]]; then
			pass "n8nite resolves repo root correctly when invoked via symlink"
		else
			fail "n8nite symlink invocation succeeded but target env file was not created"
		fi
	else
		fail "n8nite failed to resolve repo root when invoked via symlink"
	fi

	rm -rf "$tmp_dir"
}

functional_uninstall_command() {
	local tmp_dir install_dir bin_dir output
	tmp_dir="$(mktemp -d)"
	install_dir="$tmp_dir/install"
	bin_dir="$tmp_dir/bin"
	mkdir -p "$install_dir" "$bin_dir"

	cp "$N8N_SCRIPT" "$install_dir/n8nite"
	chmod +x "$install_dir/n8nite"
	ln -s "$install_dir/n8nite" "$bin_dir/n8nite"

	if run_and_capture output env N8N_SH_BIN_DIR="$bin_dir" "$bin_dir/n8nite" uninstall --yes; then
		if [[ ! -e "$bin_dir/n8nite" && ! -L "$bin_dir/n8nite" ]]; then
			pass "n8nite uninstall removes installed symlink"
		else
			fail "n8nite uninstall did not remove installed symlink"
		fi
	else
		fail "n8nite uninstall failed in installed-symlink scenario"
		rm -rf "$tmp_dir"
		return
	fi

	if run_and_capture output env N8N_SH_BIN_DIR="$bin_dir" "$install_dir/n8nite" uninstall --yes \
		&& check_contains "$output" "No installed command symlink"; then
		pass "n8nite uninstall is idempotent when symlink is already absent"
	else
		fail "n8nite uninstall idempotency check failed"
	fi

	rm -rf "$tmp_dir"
}

functional_nginx_generate() {
	local tmp_dir env_file out_dir mock_bin output
	tmp_dir="$(mktemp -d)"
	env_file="$tmp_dir/local.env"
	out_dir="$tmp_dir/out"
	mock_bin="$tmp_dir/mock-bin"

	cp "$ENV_LOCAL_TEMPLATE" "$env_file"
	mkdir -p "$mock_bin"

	# Keep this test independent from host gettext installation.
	cat >"$mock_bin/envsubst" <<'EOF'
#!/usr/bin/env bash
cat
EOF
	chmod +x "$mock_bin/envsubst"

	set +e
	output="$(PATH="$mock_bin:$PATH" "$N8N_SCRIPT" --env-file "$env_file" nginx generate --mode http --server-name localhost --out-dir "$out_dir" 2>&1)"
	local rc=$?
	set -e

	if [[ "$rc" -ne 0 ]]; then
		fail "n8nite nginx generate failed"
		rm -rf "$tmp_dir"
		return
	fi

	if [[ -f "$out_dir/localhost.http.conf" ]]; then
		pass "n8nite nginx generate produces output file"
	else
		fail "n8nite nginx generate did not create expected file"
	fi

	rm -rf "$tmp_dir"
}

functional_nginx_deploy_sandboxed() {
	local output="" tmp_dir mock_bin env_file sites_avail sites_enabled
	local apt_log sudo_log systemctl_log backup_count_before backup_count_after
	local conf_name="n8n-test"
	local key="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

	tmp_dir="$(mktemp -d)"
	mock_bin="$tmp_dir/mock-bin"
	env_file="$tmp_dir/http.env"
	sites_avail="$tmp_dir/sites-available"
	sites_enabled="$tmp_dir/sites-enabled"
	apt_log="$tmp_dir/apt.log"
	sudo_log="$tmp_dir/sudo.log"
	systemctl_log="$tmp_dir/systemctl.log"

	create_nginx_deploy_mock_bin "$mock_bin"

	cat >"$env_file" <<EOF
N8N_HOST=automation.test
N8N_PROTOCOL=http
WEBHOOK_URL=http://automation.test/
N8N_ENCRYPTION_KEY=$key
POSTGRES_USER=admin
POSTGRES_PASSWORD=admin_pass
POSTGRES_DB=n8n
POSTGRES_NON_ROOT_USER=n8n_user
POSTGRES_NON_ROOT_PASSWORD=n8n_user_pass
EOF

	if run_and_capture output \
		env \
		PATH="$mock_bin:$PATH" \
		MOCK_APT_LOG="$apt_log" \
		MOCK_SUDO_LOG="$sudo_log" \
		MOCK_SYSTEMCTL_LOG="$systemctl_log" \
		SITES_AVAILABLE_DIR="$sites_avail" \
		SITES_ENABLED_DIR="$sites_enabled" \
		bash -c "printf 'y\n' | \"$NGINX_DEPLOY_SCRIPT\" --env-file \"$env_file\" --conf-name \"$conf_name\" --upstream 127.0.0.1:5678"; then
		pass "nginx deploy runs successfully in sandboxed temp dirs"
	else
		fail "nginx deploy sandboxed run failed"
		rm -rf "$tmp_dir"
		return
	fi

	if [[ -f "$sites_avail/$conf_name.conf" ]]; then
		pass "nginx deploy wrote config only to sandboxed sites-available dir"
	else
		fail "nginx deploy did not create config in sandboxed sites-available dir"
	fi

	if [[ -L "$sites_enabled/$conf_name.conf" ]]; then
		pass "nginx deploy created symlink in sandboxed sites-enabled dir"
	else
		fail "nginx deploy did not create symlink in sandboxed sites-enabled dir"
	fi

	if grep -Fq 'install -y nginx gettext-base' "$apt_log"; then
		pass "nginx deploy used mocked package installation path"
	else
		fail "nginx deploy did not run mocked package installation commands"
	fi

	if grep -Fq "$sites_avail/$conf_name.conf" "$sudo_log"; then
		pass "nginx deploy privileged operations targeted sandbox paths"
	else
		fail "nginx deploy privileged operations did not target sandbox paths"
	fi

	backup_count_before="$(find "$sites_avail" -maxdepth 1 -type f -name "${conf_name}.conf.bak.*" | wc -l | tr -d '[:space:]')"
	if [[ "$backup_count_before" -eq 0 ]]; then
		pass "nginx deploy first run does not create backup when no previous conf exists"
	else
		fail "nginx deploy created unexpected backup on first run"
	fi

	if run_and_capture output \
		env \
		PATH="$mock_bin:$PATH" \
		MOCK_APT_LOG="$apt_log" \
		MOCK_SUDO_LOG="$sudo_log" \
		MOCK_SYSTEMCTL_LOG="$systemctl_log" \
		SITES_AVAILABLE_DIR="$sites_avail" \
		SITES_ENABLED_DIR="$sites_enabled" \
		bash -c "printf 'y\n' | \"$NGINX_DEPLOY_SCRIPT\" --env-file \"$env_file\" --conf-name \"$conf_name\" --upstream 127.0.0.1:5678"; then
		pass "nginx deploy second run succeeds in sandboxed temp dirs"
	else
		fail "nginx deploy second sandboxed run failed"
		rm -rf "$tmp_dir"
		return
	fi

	backup_count_after="$(find "$sites_avail" -maxdepth 1 -type f -name "${conf_name}.conf.bak.*" | wc -l | tr -d '[:space:]')"
	if [[ "$backup_count_after" -gt "$backup_count_before" ]]; then
		pass "nginx deploy creates timestamped backup before overwriting existing conf"
	else
		fail "nginx deploy did not create backup before overwrite on rerun"
	fi

	if grep -Fq "${sites_avail}/${conf_name}.conf.bak." "$sudo_log"; then
		pass "nginx deploy backup copy operation stays within sandbox paths"
	else
		fail "nginx deploy backup operation not observed in sandbox sudo log"
	fi

	rm -rf "$tmp_dir"
}

functional_interactive_exit() {
	local output=""
	if run_and_capture output bash -c "printf '0\n' | \"$N8N_SCRIPT\" interactive"; then
		if check_contains "$output" "n8nite :: opinionated n8n stack on wheels" \
			&& check_contains "$output" "=== n8nite Interactive Menu ===" \
			&& check_contains "$output" "Exiting interactive mode."; then
			pass "interactive mode exits cleanly without side effects on immediate exit"
		else
			fail "interactive banner/menu/exit text not found"
		fi
	else
		fail "interactive mode failed on immediate exit"
	fi
}

functional_queue_services_declared() {
	if grep -q '^  redis:$' "$REPO_ROOT/docker-compose.yml" && grep -q '^  n8n-worker:$' "$REPO_ROOT/docker-compose.yml"; then
		pass "docker-compose declares queue services redis and n8n-worker"
	else
		fail "docker-compose is missing redis or n8n-worker service declaration"
	fi
}

functional_compose_delegation() {
	local tmp_dir env_file mock_bin docker_log output
	tmp_dir="$(mktemp -d)"
	env_file="$tmp_dir/local.env"
	mock_bin="$tmp_dir/mock-bin"
	docker_log="$tmp_dir/docker.log"

	cp "$ENV_LOCAL_TEMPLATE" "$env_file"
	mkdir -p "$mock_bin"

	cat >"$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file="${MOCK_DOCKER_LOG:?}"
printf '%s\n' "$*" >>"$log_file"
exit 0
EOF
	chmod +x "$mock_bin/docker"

	set +e
	output="$(PATH="$mock_bin:$PATH" MOCK_DOCKER_LOG="$docker_log" "$N8N_SCRIPT" --env-file "$env_file" config 2>&1)"
	local rc_config=$?
	set -e

	if [[ "$rc_config" -ne 0 ]]; then
		fail "n8nite config failed under mock docker"
		rm -rf "$tmp_dir"
		return
	fi

	if grep -Fq "compose --env-file $env_file -f $REPO_ROOT/docker-compose.yml config" "$docker_log"; then
		pass "n8nite config delegates to docker compose with expected args"
	else
		fail "n8nite config did not call docker compose as expected"
	fi

	: >"$docker_log"

	set +e
	output="$(PATH="$mock_bin:$PATH" MOCK_DOCKER_LOG="$docker_log" "$N8N_SCRIPT" --env-file "$env_file" up 2>&1)"
	local rc_up=$?
	set -e

	if [[ "$rc_up" -ne 0 ]]; then
		fail "n8nite up failed under mock docker"
		rm -rf "$tmp_dir"
		return
	fi

	if grep -Fq "compose --env-file $env_file -f $REPO_ROOT/docker-compose.yml config" "$docker_log"; then
		pass "n8nite up runs env compose validation"
	else
		fail "n8nite up did not trigger compose validation through env check"
	fi

	if grep -Fq "compose --env-file $env_file -f $REPO_ROOT/docker-compose.yml up -d" "$docker_log"; then
		pass "n8nite up delegates to docker compose up -d"
	else
		fail "n8nite up did not call docker compose up -d"
	fi

	rm -rf "$tmp_dir"
}

check_functional() {
	printf '\n== Functional checks ==\n'
	[[ -x "$N8N_SCRIPT" ]] || {
		fail "n8nite is missing or not executable"
		return
	}
	[[ -f "$ENV_LOCAL_TEMPLATE" ]] || {
		fail ".env.local.example is missing"
		return
	}
	[[ -x "$NGINX_DEPLOY_SCRIPT" ]] || {
		fail "nginx/install-nginx-and-deploy.sh is missing or not executable"
		return
	}

	functional_help_and_errors
	functional_env_flow
	functional_env_validation_matrix
	functional_env_keygen
	functional_env_view_edit
	functional_deps_command
	functional_install_script
	functional_symlink_repo_resolution
	functional_uninstall_command
	functional_nginx_generate
	functional_nginx_deploy_sandboxed
	functional_interactive_exit
	functional_queue_services_declared
	functional_compose_delegation
}

while (($# > 0)); do
	case "$1" in
		--requirements-only|-r)
			RUN_REQUIREMENTS=1
			RUN_FUNCTIONAL=0
			shift
			;;
		--functional-only|-f)
			RUN_REQUIREMENTS=0
			RUN_FUNCTIONAL=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf '[ERROR] Unknown argument: %s\n' "$1" >&2
			usage >&2
			exit 1
			;;
	esac
done

if [[ "$RUN_REQUIREMENTS" -eq 1 ]]; then
	check_requirements
fi

if [[ "$RUN_FUNCTIONAL" -eq 1 ]]; then
	check_functional
fi

printf '\n== Summary ==\n'
printf 'total:  %d\n' "$TOTAL"
printf 'passed: %d\n' "$PASSED"
printf 'failed: %d\n' "$FAILED"

if [[ "$FAILED" -gt 0 ]]; then
	exit 1
fi

exit 0
