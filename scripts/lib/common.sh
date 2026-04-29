#!/usr/bin/env bash

if [[ -n "${CHART_TOOL_COMMON_SH_LOADED:-}" ]]; then
	return 0
fi
readonly CHART_TOOL_COMMON_SH_LOADED=1

CHART_TOOL_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CHART_TOOL_ROOT_DIR
readonly CHART_TOOL_CHARTS_ROOT="${CHARTS_ROOT:-charts}"
readonly CHART_TOOL_RELEASE_AUTHOR_NAME="${CHART_TOOL_RELEASE_AUTHOR_NAME:-github-actions[bot]}"
readonly CHART_TOOL_RELEASE_AUTHOR_EMAIL="${CHART_TOOL_RELEASE_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

info() {
	printf 'INFO: %s\n' "$*" >&2
}

warn() {
	printf 'WARN: %s\n' "$*" >&2
}

require_command() {
	local command_name

	for command_name in "$@"; do
		command -v "${command_name}" >/dev/null 2>&1 || die "Required command not found: ${command_name}"
	done
}

sha256_digest() {
	local file_path="$1"

	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "${file_path}" | awk '{ print $1; exit }'
		return 0
	fi

	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "${file_path}" | awk '{ print $1; exit }'
		return 0
	fi

	die "Required command not found: sha256sum or shasum"
}

verify_sha256_digest() {
	local file_path="$1"
	local expected_digest="$2"
	local actual_digest

	actual_digest="$(sha256_digest "${file_path}")"
	[ "${actual_digest}" = "${expected_digest}" ] || die "SHA256 mismatch for ${file_path}: expected ${expected_digest}, got ${actual_digest}"
}

json_array_from_values() {
	local -a values=("$@")

	require_command jq

	if [ "${#values[@]}" -eq 0 ]; then
		jq -cn '[]'
		return 0
	fi

	printf '%s\n' "${values[@]}" | jq -R . | jq -cs .
}

json_array_to_lines() {
	local json_input="$1"

	require_command jq
	jq -r '.[]' <<<"${json_input}"
}

chart_dir_to_abs() {
	local chart_dir="$1"
	printf '%s/%s\n' "${CHART_TOOL_ROOT_DIR}" "${chart_dir}"
}

chart_dir_exists() {
	local chart_dir="$1"
	[ -d "$(chart_dir_to_abs "${chart_dir}")" ]
}

chart_file() {
	local chart_dir="$1"
	printf '%s/Chart.yaml\n' "$(chart_dir_to_abs "${chart_dir}")"
}

values_file() {
	local chart_dir="$1"
	printf '%s/values.yaml\n' "$(chart_dir_to_abs "${chart_dir}")"
}

chart_readme_file() {
	local chart_dir="$1"
	printf '%s/README.md\n' "$(chart_dir_to_abs "${chart_dir}")"
}

yaml_scalar_value() {
	local file="$1"
	local expression="$2"

	require_command yq
	yq -r "${expression} // \"\"" "${file}"
}

chart_yaml_value() {
	local file="$1"
	local key="$2"
	yaml_scalar_value "${file}" ".${key}"
}

values_yaml_image_value() {
	local file="$1"
	local field="$2"
	yaml_scalar_value "${file}" ".image.${field}"
}

chart_name() {
	chart_yaml_value "$(chart_file "$1")" name
}

chart_version() {
	chart_yaml_value "$(chart_file "$1")" version
}

chart_app_version() {
	chart_yaml_value "$(chart_file "$1")" appVersion
}

chart_description() {
	chart_yaml_value "$(chart_file "$1")" description
}

chart_kube_version() {
	chart_yaml_value "$(chart_file "$1")" kubeVersion
}

chart_default_image_tag() {
	values_yaml_image_value "$(values_file "$1")" tag
}

list_all_chart_dirs() {
	local charts_root_abs="${CHART_TOOL_ROOT_DIR}/${CHART_TOOL_CHARTS_ROOT}"
	local dir

	[ -d "${charts_root_abs}" ] || return 0

	find "${charts_root_abs}" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
		if [ -f "${dir}/Chart.yaml" ]; then
			printf '%s\n' "${dir#"${CHART_TOOL_ROOT_DIR}"/}"
		fi
	done | sort -u
}

chart_dir_from_changed_path() {
	local changed_path="$1"
	local relative_path
	local chart_name_segment

	relative_path="${changed_path#"${CHART_TOOL_CHARTS_ROOT}"/}"
	chart_name_segment="${relative_path%%/*}"

	if [ -z "${chart_name_segment}" ] || [ "${chart_name_segment}" = "${relative_path}" ]; then
		return 1
	fi

	printf '%s/%s\n' "${CHART_TOOL_CHARTS_ROOT}" "${chart_name_segment}"
}

list_changed_chart_dirs() {
	local base_ref="$1"
	local head_ref="$2"
	local changed_path
	local chart_dir

	(
		cd "${CHART_TOOL_ROOT_DIR}" || exit

		git diff --name-only --diff-filter=ACMRTUXB "${base_ref}" "${head_ref}" -- "${CHART_TOOL_CHARTS_ROOT}/" | while IFS= read -r changed_path; do
			[ -n "${changed_path}" ] || continue

			chart_dir="$(chart_dir_from_changed_path "${changed_path}" || true)"
			[ -n "${chart_dir}" ] || continue
			[ -f "${chart_dir}/Chart.yaml" ] || continue
			printf '%s\n' "${chart_dir}"
		done | sort -u
	)
}

chart_readme_exists() {
	local chart_dir="$1"
	[ -f "$(chart_readme_file "${chart_dir}")" ]
}

chart_docs_template_exists() {
	local chart_dir="$1"
	[ -f "$(chart_dir_to_abs "${chart_dir}")/README.md.gotmpl" ]
}

chart_has_renovate_inline_annotation() {
	local file="$1"
	local key="$2"

	grep -Eq "^[[:space:]]*${key}:[^#]+#[[:space:]]*renovate:[[:space:]]*datasource=" "${file}"
}

semver_is_valid() {
	[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]
}

compare_prerelease_identifiers() {
	local left="$1"
	local right="$2"
	local -a left_parts=()
	local -a right_parts=()
	local index
	local max_parts
	local left_part
	local right_part

	IFS='.' read -r -a left_parts <<<"${left}"
	IFS='.' read -r -a right_parts <<<"${right}"

	max_parts="${#left_parts[@]}"
	if [ "${#right_parts[@]}" -gt "${max_parts}" ]; then
		max_parts="${#right_parts[@]}"
	fi

	for ((index = 0; index < max_parts; index += 1)); do
		left_part="${left_parts[index]:-}"
		right_part="${right_parts[index]:-}"

		if [ -z "${left_part}" ] && [ -n "${right_part}" ]; then
			printf '%s\n' -1
			return 0
		fi

		if [ -n "${left_part}" ] && [ -z "${right_part}" ]; then
			printf '%s\n' 1
			return 0
		fi

		if [[ "${left_part}" =~ ^[0-9]+$ ]] && [[ "${right_part}" =~ ^[0-9]+$ ]]; then
			if ((10#${left_part} > 10#${right_part})); then
				printf '%s\n' 1
				return 0
			fi
			if ((10#${left_part} < 10#${right_part})); then
				printf '%s\n' -1
				return 0
			fi
			continue
		fi

		if [[ "${left_part}" =~ ^[0-9]+$ ]] && [[ ! "${right_part}" =~ ^[0-9]+$ ]]; then
			printf '%s\n' -1
			return 0
		fi

		if [[ ! "${left_part}" =~ ^[0-9]+$ ]] && [[ "${right_part}" =~ ^[0-9]+$ ]]; then
			printf '%s\n' 1
			return 0
		fi

		if [[ "${left_part}" > "${right_part}" ]]; then
			printf '%s\n' 1
			return 0
		fi

		if [[ "${left_part}" < "${right_part}" ]]; then
			printf '%s\n' -1
			return 0
		fi
	done

	printf '%s\n' 0
}

semver_compare() {
	local left="$1"
	local right="$2"
	local left_without_build="${left%%+*}"
	local right_without_build="${right%%+*}"
	local left_core="${left_without_build%%-*}"
	local right_core="${right_without_build%%-*}"
	local left_prerelease=""
	local right_prerelease=""
	local left_major
	local left_minor
	local left_patch
	local right_major
	local right_minor
	local right_patch

	if [[ "${left_without_build}" == *-* ]]; then
		left_prerelease="${left_without_build#*-}"
	fi

	if [[ "${right_without_build}" == *-* ]]; then
		right_prerelease="${right_without_build#*-}"
	fi

	IFS='.' read -r left_major left_minor left_patch <<<"${left_core}"
	IFS='.' read -r right_major right_minor right_patch <<<"${right_core}"

	if ((10#${left_major} > 10#${right_major})); then
		printf '%s\n' 1
		return 0
	fi
	if ((10#${left_major} < 10#${right_major})); then
		printf '%s\n' -1
		return 0
	fi

	if ((10#${left_minor} > 10#${right_minor})); then
		printf '%s\n' 1
		return 0
	fi
	if ((10#${left_minor} < 10#${right_minor})); then
		printf '%s\n' -1
		return 0
	fi

	if ((10#${left_patch} > 10#${right_patch})); then
		printf '%s\n' 1
		return 0
	fi
	if ((10#${left_patch} < 10#${right_patch})); then
		printf '%s\n' -1
		return 0
	fi

	if [ -z "${left_prerelease}" ] && [ -z "${right_prerelease}" ]; then
		printf '%s\n' 0
		return 0
	fi

	if [ -z "${left_prerelease}" ]; then
		printf '%s\n' 1
		return 0
	fi

	if [ -z "${right_prerelease}" ]; then
		printf '%s\n' -1
		return 0
	fi

	compare_prerelease_identifiers "${left_prerelease}" "${right_prerelease}"
}

semver_gt() {
	[ "$(semver_compare "$1" "$2")" -gt 0 ]
}

sanitize_release_name() {
	local raw_name="$1"
	local prefix="${2:-validate}"
	local sanitized_name

	sanitized_name="$(printf '%s' "${raw_name}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '-')"
	sanitized_name="$(printf '%s' "${sanitized_name}" | sed -e 's/^[.-]*//' -e 's/[.-]*$//')"

	if [ -z "${sanitized_name}" ]; then
		sanitized_name="chart"
	fi

	sanitized_name="${prefix}-${sanitized_name}"
	sanitized_name="$(printf '%s' "${sanitized_name}" | cut -c1-53)"
	sanitized_name="$(printf '%s' "${sanitized_name}" | sed -e 's/^[.-]*//' -e 's/[.-]*$//')"

	if [ -z "${sanitized_name}" ]; then
		sanitized_name="${prefix}-chart"
	fi

	printf '%s\n' "${sanitized_name}"
}

chart_default_scenarios() {
	printf '%s\n' default ingress httproute autoscaling
}

scenario_template_args() {
	local scenario="$1"

	case "${scenario}" in
	default)
		return 0
		;;
	ingress)
		printf '%s\n' '--set' 'ingress.enabled=true'
		;;
	httproute)
		printf '%s\n' '--set' 'httpRoute.enabled=true'
		;;
	autoscaling)
		printf '%s\n' '--set' 'autoscaling.enabled=true' '--set' 'autoscaling.minReplicas=2' '--set' 'podDisruptionBudget.enabled=true' '--set' 'resources.requests.cpu=100m' '--set' 'resources.requests.memory=128Mi'
		;;
	*)
		die "Unsupported validation scenario: ${scenario}"
		;;
	esac
}

assert_chart_dir() {
	local chart_dir="$1"

	chart_dir_exists "${chart_dir}" || die "Chart directory does not exist: ${chart_dir}"
	[ -f "$(chart_file "${chart_dir}")" ] || die "Missing Chart.yaml in ${chart_dir}"
	[ -f "$(values_file "${chart_dir}")" ] || die "Missing values.yaml in ${chart_dir}"
}
