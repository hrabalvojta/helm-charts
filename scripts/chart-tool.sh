#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"
# shellcheck source=scripts/lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"
# shellcheck source=scripts/lib/release.sh
source "${SCRIPT_DIR}/lib/release.sh"

usage() {
	cat <<'EOF'
Usage:
  scripts/chart-tool.sh discover all [--format lines|json]
  scripts/chart-tool.sh discover changed --base <ref> --head <ref> [--format lines|json]
  scripts/chart-tool.sh repo lint
  scripts/chart-tool.sh version check --base <ref> --head <ref> [--allow-unpublished-reuse]
  scripts/chart-tool.sh charts audit [--charts-json <json> | <chart>...]
  scripts/chart-tool.sh charts docs-check [--charts-json <json> | <chart>...]
  scripts/chart-tool.sh charts test --chart <chart> [--scenario <name>] [--server-dry-run]
  scripts/chart-tool.sh charts package --destination <dir> [--charts-json <json> | <chart>...]
  scripts/chart-tool.sh tools install <actionlint|gitleaks|helm-docs|kube-score|shfmt|yq> --version <version> --install-dir <dir>
  scripts/chart-tool.sh release publish [--all | --charts-json <json> | --base <ref> --head <ref>]
EOF
}

print_chart_selection() {
	local format="$1"
	shift
	local -a chart_dirs=("$@")

	case "${format}" in
	lines)
		if [ "${#chart_dirs[@]}" -gt 0 ]; then
			printf '%s\n' "${chart_dirs[@]}"
		fi
		;;
	json)
		json_array_from_values "${chart_dirs[@]}"
		;;
	*)
		die "Unsupported output format: ${format}"
		;;
	esac
}

load_chart_selection() {
	local charts_json="${1:-}"
	shift || true
	local -a chart_dirs=("$@")

	if [ -n "${charts_json}" ] && [ "${#chart_dirs[@]}" -gt 0 ]; then
		die "Use either --charts-json or positional chart arguments, not both"
	fi

	if [ -n "${charts_json}" ]; then
		mapfile -t chart_dirs < <(json_array_to_lines "${charts_json}")
	elif [ "${#chart_dirs[@]}" -eq 0 ]; then
		mapfile -t chart_dirs < <(list_all_chart_dirs)
	fi

	printf '%s\n' "${chart_dirs[@]}"
}

discover_all() {
	local format="lines"
	local -a chart_dirs=()

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--format)
			[ "$#" -ge 2 ] || die "--format requires a value"
			format="$2"
			shift 2
			;;
		*)
			die "Unexpected argument for discover all: $1"
			;;
		esac
	done

	mapfile -t chart_dirs < <(list_all_chart_dirs)
	print_chart_selection "${format}" "${chart_dirs[@]}"
}

discover_changed() {
	local format="lines"
	local base_ref=""
	local head_ref=""
	local -a chart_dirs=()

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--base)
			[ "$#" -ge 2 ] || die "--base requires a ref"
			base_ref="$2"
			shift 2
			;;
		--head)
			[ "$#" -ge 2 ] || die "--head requires a ref"
			head_ref="$2"
			shift 2
			;;
		--format)
			[ "$#" -ge 2 ] || die "--format requires a value"
			format="$2"
			shift 2
			;;
		*)
			die "Unexpected argument for discover changed: $1"
			;;
		esac
	done

	[ -n "${base_ref}" ] || die "discover changed requires --base"
	[ -n "${head_ref}" ] || die "discover changed requires --head"

	mapfile -t chart_dirs < <(list_changed_chart_dirs "${base_ref}" "${head_ref}")
	print_chart_selection "${format}" "${chart_dirs[@]}"
}

repo_lint() {
	require_command actionlint gitleaks jq shellcheck shfmt yamllint yq

	(
		cd "${CHART_TOOL_ROOT_DIR}"
		actionlint .github/workflows/*.yaml
		shellcheck scripts/*.sh scripts/lib/*.sh
		shfmt -d scripts/chart-tool.sh scripts/lib/*.sh
		yamllint .
		gitleaks dir . --no-banner --redact
		[ -f .github/release-template.md ] || die "Missing .github/release-template.md"
		[ -f .yamllint.yml ] || die "Missing .yamllint.yml"
		jq empty .github/renovate.json >/dev/null
	)
}

check_chart_version_bump() {
	local chart_dir="$1"
	local base_ref="$2"
	local allow_unpublished_reuse="${3:-false}"
	local current_version
	local chart_name_value
	local previous_chart_path
	local previous_chart_file
	local previous_version

	chart_name_value="$(chart_name "${chart_dir}")"
	current_version="$(chart_version "${chart_dir}")"
	[ -n "${current_version}" ] || die "Missing version in ${chart_dir}/Chart.yaml"
	semver_is_valid "${current_version}" || die "Chart version is not valid SemVer in ${chart_dir}/Chart.yaml: ${current_version}"

	previous_chart_path="${chart_dir}/Chart.yaml"
	if ! (
		cd "${CHART_TOOL_ROOT_DIR}"
		git cat-file -e "${base_ref}:${previous_chart_path}"
	) 2>/dev/null; then
		info "${chart_dir} is new relative to ${base_ref}; version bump check skipped"
		return 0
	fi

	previous_chart_file="$(mktemp)"
	(
		cd "${CHART_TOOL_ROOT_DIR}"
		git show "${base_ref}:${previous_chart_path}" >"${previous_chart_file}"
	)
	previous_version="$(chart_yaml_value "${previous_chart_file}" version || true)"
	rm -f "${previous_chart_file}"

	[ -n "${previous_version}" ] || die "Cannot read the previous chart version from ${base_ref}:${previous_chart_path}"
	semver_is_valid "${previous_version}" || die "Previous chart version is not valid SemVer in ${base_ref}:${previous_chart_path}: ${previous_version}"

	if semver_gt "${current_version}" "${previous_version}"; then
		return 0
	fi

	if [ "${allow_unpublished_reuse}" = true ] && [ "${current_version}" = "${previous_version}" ]; then
		if chart_version_is_published "${chart_name_value}" "${current_version}"; then
			die "${chart_dir} version ${current_version} is already published; bump the chart version before releasing new chart contents"
		fi

		info "${chart_dir} version ${current_version} matches ${base_ref}, but it is not published yet; allowing release retry"
		return 0
	fi

	die "${chart_dir} version must increase relative to ${base_ref} (${previous_version} -> ${current_version})"
}

version_check() {
	local base_ref=""
	local head_ref=""
	local allow_unpublished_reuse=false
	local chart_dir
	local -a changed_chart_dirs=()

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--base)
			[ "$#" -ge 2 ] || die "--base requires a ref"
			base_ref="$2"
			shift 2
			;;
		--head)
			[ "$#" -ge 2 ] || die "--head requires a ref"
			head_ref="$2"
			shift 2
			;;
		--allow-unpublished-reuse)
			allow_unpublished_reuse=true
			shift
			;;
		*)
			die "Unexpected argument for version check: $1"
			;;
		esac
	done

	[ -n "${base_ref}" ] || die "version check requires --base"
	[ -n "${head_ref}" ] || die "version check requires --head"

	mapfile -t changed_chart_dirs < <(list_changed_chart_dirs "${base_ref}" "${head_ref}")
	if [ "${#changed_chart_dirs[@]}" -eq 0 ]; then
		info "No changed charts detected between ${base_ref} and ${head_ref}"
		return 0
	fi

	for chart_dir in "${changed_chart_dirs[@]}"; do
		check_chart_version_bump "${chart_dir}" "${base_ref}" "${allow_unpublished_reuse}"
	done
}

audit_chart() {
	local chart_dir="$1"
	local chart_name_value
	local chart_version_value
	local chart_app_version_value
	local image_tag_value
	local chart_yaml_path

	assert_chart_dir "${chart_dir}"

	chart_name_value="$(chart_name "${chart_dir}")"
	chart_version_value="$(chart_version "${chart_dir}")"
	chart_app_version_value="$(chart_app_version "${chart_dir}")"
	image_tag_value="$(chart_default_image_tag "${chart_dir}" || true)"
	chart_yaml_path="${chart_dir}/Chart.yaml"

	[ -n "${chart_name_value}" ] || die "Missing name in ${chart_yaml_path}"
	[ -n "${chart_version_value}" ] || die "Missing version in ${chart_yaml_path}"
	[ -n "${chart_app_version_value}" ] || die "Missing appVersion in ${chart_yaml_path}"

	semver_is_valid "${chart_version_value}" || die "Chart version is not valid SemVer in ${chart_yaml_path}: ${chart_version_value}"
	chart_readme_exists "${chart_dir}" || die "Missing README.md in ${chart_dir}"

	if chart_has_renovate_inline_annotation "$(chart_file "${chart_dir}")" appVersion && chart_has_renovate_inline_annotation "$(values_file "${chart_dir}")" tag; then
		if [ -n "${image_tag_value}" ] && [ "${image_tag_value}" != "${chart_app_version_value}" ]; then
			die "${chart_dir} uses Renovate-managed image versions, but values.yaml image.tag (${image_tag_value}) does not match Chart.yaml appVersion (${chart_app_version_value})"
		fi
	fi
}

charts_audit() {
	local charts_json=""
	local chart_dir
	local -a chart_dirs=()

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--charts-json)
			[ "$#" -ge 2 ] || die "--charts-json requires JSON input"
			charts_json="$2"
			shift 2
			;;
		*)
			chart_dirs+=("$1")
			shift
			;;
		esac
	done

	mapfile -t chart_dirs < <(load_chart_selection "${charts_json}" "${chart_dirs[@]}")

	for chart_dir in "${chart_dirs[@]}"; do
		audit_chart "${chart_dir}"
	done
}

docs_check_chart() {
	local chart_dir="$1"

	assert_chart_dir "${chart_dir}"
	require_command git helm-docs

	if ! chart_docs_template_exists "${chart_dir}" && ! chart_readme_exists "${chart_dir}"; then
		die "README.md or README.md.gotmpl is required for ${chart_dir}"
	fi

	(
		cd "${CHART_TOOL_ROOT_DIR}"
		helm-docs --chart-search-root "${chart_dir}"
		git diff --exit-code -- "${chart_dir}/README.md" >/dev/null || die "helm-docs output is stale for ${chart_dir}; regenerate README.md"
	)
}

charts_docs_check() {
	local charts_json=""
	local chart_dir
	local -a chart_dirs=()

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--charts-json)
			[ "$#" -ge 2 ] || die "--charts-json requires JSON input"
			charts_json="$2"
			shift 2
			;;
		*)
			chart_dirs+=("$1")
			shift
			;;
		esac
	done

	mapfile -t chart_dirs < <(load_chart_selection "${charts_json}" "${chart_dirs[@]}")

	for chart_dir in "${chart_dirs[@]}"; do
		docs_check_chart "${chart_dir}"
	done
}

render_chart_manifest() {
	local chart_dir="$1"
	local scenario="$2"
	local include_tests="${3:-true}"
	local release_name
	local -a extra_args=()
	local -a helm_args=()

	release_name="$(sanitize_release_name "$(basename "${chart_dir}")" "${scenario}")"
	mapfile -t extra_args < <(scenario_template_args "${scenario}")
	helm_args=(template "${release_name}" "${chart_dir}" --include-crds)

	if [ "${include_tests}" = false ]; then
		helm_args+=(--skip-tests)
	fi

	(
		cd "${CHART_TOOL_ROOT_DIR}"
		helm "${helm_args[@]}" "${extra_args[@]}"
	)
}

run_chart_render_scenario() {
	local chart_dir="$1"
	local scenario="$2"

	render_chart_manifest "${chart_dir}" "${scenario}" true >/dev/null
}

run_chart_quality_scenario() {
	local chart_dir="$1"
	local scenario="$2"
	local manifest_file

	manifest_file="$(mktemp)"
	render_chart_manifest "${chart_dir}" "${scenario}" false >"${manifest_file}"

	if [ ! -s "${manifest_file}" ]; then
		rm -f "${manifest_file}"
		die "Rendered manifest is empty for ${chart_dir} scenario ${scenario}"
	fi

	kube-score score --ignore-test container-image-pull-policy "${manifest_file}"
	rm -f "${manifest_file}"
}

run_chart_negative_scenario() {
	local chart_dir="$1"
	local scenario="$2"

	if render_chart_manifest "${chart_dir}" "${scenario}" true >/dev/null 2>&1; then
		die "Expected ${chart_dir} scenario ${scenario} to fail rendering"
	fi
}

run_chart_server_dry_run_scenario() {
	local chart_dir="$1"
	local scenario="$2"
	local manifest_file

	manifest_file="$(mktemp)"
	render_chart_manifest "${chart_dir}" "${scenario}" false >"${manifest_file}"
	kubectl apply --dry-run=server -f "${manifest_file}"
	rm -f "${manifest_file}"
}

charts_test() {
	local chart_dir=""
	local scenario=""
	local server_dry_run=false
	local active_scenario
	local -a scenarios=()
	local -a negative_scenarios=()

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--chart)
			[ "$#" -ge 2 ] || die "--chart requires a chart directory"
			chart_dir="$2"
			shift 2
			;;
		--scenario)
			[ "$#" -ge 2 ] || die "--scenario requires a scenario name"
			scenario="$2"
			shift 2
			;;
		--server-dry-run)
			server_dry_run=true
			shift
			;;
		*)
			die "Unexpected argument for charts test: $1"
			;;
		esac
	done

	[ -n "${chart_dir}" ] || die "charts test requires --chart"
	audit_chart "${chart_dir}"

	if [ -n "${scenario}" ] && scenario_is_negative "${scenario}"; then
		negative_scenarios=("${scenario}")
	elif [ -n "${scenario}" ]; then
		scenarios=("${scenario}")
	else
		mapfile -t scenarios < <(chart_default_scenarios)
		mapfile -t negative_scenarios < <(chart_negative_scenarios)
	fi

	require_command helm
	if [ "${#scenarios[@]}" -gt 0 ]; then
		require_command kube-score
	fi
	if [ "${server_dry_run}" = true ]; then
		require_command kubectl
	fi

	(
		cd "${CHART_TOOL_ROOT_DIR}"
		helm dependency build "${chart_dir}" >/dev/null
		helm lint "${chart_dir}" --strict >/dev/null
	)

	for active_scenario in "${scenarios[@]}"; do
		run_chart_render_scenario "${chart_dir}" "${active_scenario}"
		run_chart_quality_scenario "${chart_dir}" "${active_scenario}"
		if [ "${server_dry_run}" = true ]; then
			run_chart_server_dry_run_scenario "${chart_dir}" "${active_scenario}"
		fi
	done

	for active_scenario in "${negative_scenarios[@]}"; do
		run_chart_negative_scenario "${chart_dir}" "${active_scenario}"
	done
}

package_chart() {
	local chart_dir="$1"
	local destination_dir="$2"

	assert_chart_dir "${chart_dir}"
	require_command helm

	mkdir -p "${destination_dir}"

	(
		cd "${CHART_TOOL_ROOT_DIR}"
		helm dependency build "${chart_dir}" >/dev/null
		helm package "${chart_dir}" --destination "${destination_dir}" >/dev/null
	)
}

charts_package() {
	local charts_json=""
	local destination_dir=""
	local chart_dir
	local -a chart_dirs=()

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--charts-json)
			[ "$#" -ge 2 ] || die "--charts-json requires JSON input"
			charts_json="$2"
			shift 2
			;;
		--destination)
			[ "$#" -ge 2 ] || die "--destination requires a directory"
			destination_dir="$2"
			shift 2
			;;
		*)
			chart_dirs+=("$1")
			shift
			;;
		esac
	done

	[ -n "${destination_dir}" ] || die "charts package requires --destination"
	mapfile -t chart_dirs < <(load_chart_selection "${charts_json}" "${chart_dirs[@]}")

	for chart_dir in "${chart_dirs[@]}"; do
		package_chart "${chart_dir}" "${destination_dir}"
	done
}

main() {
	[ "$#" -gt 0 ] || {
		usage >&2
		exit 1
	}

	case "$1" in
	discover)
		shift
		case "${1:-}" in
		all)
			shift
			discover_all "$@"
			;;
		changed)
			shift
			discover_changed "$@"
			;;
		*)
			die "Unsupported discover subcommand: ${1:-<missing>}"
			;;
		esac
		;;
	repo)
		shift
		case "${1:-}" in
		lint)
			shift
			repo_lint "$@"
			;;
		*)
			die "Unsupported repo subcommand: ${1:-<missing>}"
			;;
		esac
		;;
	version)
		shift
		case "${1:-}" in
		check)
			shift
			version_check "$@"
			;;
		*)
			die "Unsupported version subcommand: ${1:-<missing>}"
			;;
		esac
		;;
	charts)
		shift
		case "${1:-}" in
		audit)
			shift
			charts_audit "$@"
			;;
		docs-check)
			shift
			charts_docs_check "$@"
			;;
		test)
			shift
			charts_test "$@"
			;;
		package)
			shift
			charts_package "$@"
			;;
		*)
			die "Unsupported charts subcommand: ${1:-<missing>}"
			;;
		esac
		;;
	tools)
		shift
		case "${1:-}" in
		install)
			shift
			tools_install "$@"
			;;
		*)
			die "Unsupported tools subcommand: ${1:-<missing>}"
			;;
		esac
		;;
	release)
		shift
		case "${1:-}" in
		publish)
			shift
			release_publish "$@"
			;;
		*)
			die "Unsupported release subcommand: ${1:-<missing>}"
			;;
		esac
		;;
	-h | --help | help)
		usage
		;;
	*)
		die "Unsupported command: $1"
		;;
	esac
}

main "$@"
