#!/usr/bin/env bash

if [[ -n "${CHART_TOOL_TOOLS_SH_LOADED:-}" ]]; then
	return 0
fi
readonly CHART_TOOL_TOOLS_SH_LOADED=1

normalize_os() {
	case "$(uname -s)" in
	Linux)
		printf '%s\n' linux
		;;
	Darwin)
		printf '%s\n' darwin
		;;
	*)
		die "Unsupported operating system: $(uname -s)"
		;;
	esac
}

normalize_arch() {
	case "$(uname -m)" in
	x86_64 | amd64)
		printf '%s\n' amd64
		;;
	arm64 | aarch64)
		printf '%s\n' arm64
		;;
	*)
		die "Unsupported architecture: $(uname -m)"
		;;
	esac
}

download_url_to_file() {
	local url="$1"
	local destination_path="$2"

	require_command curl
	curl -fsSL "${url}" -o "${destination_path}"
}

github_release_asset_json_from_candidates() {
	local release_json="$1"
	shift
	local candidate_name
	local asset_json

	for candidate_name in "$@"; do
		[ -n "${candidate_name}" ] || continue
		if asset_json="$(github_release_asset_json_by_name "${release_json}" "${candidate_name}" 2>/dev/null)"; then
			printf '%s\n' "${asset_json}"
			return 0
		fi
	done

	return 1
}

github_release_checksum_asset_json() {
	local release_json="$1"

	require_command jq
	jq -ce '
		first(
			.assets[]
			| select(
				(
					.name
					| ascii_downcase
					| test("(checksums|sha256sums)")
				)
				and (
					.name
					| ascii_downcase
					| endswith(".txt")
				)
			)
		)
	' <<<"${release_json}"
}

release_asset_sha256_from_checksum_file() {
	local checksum_file="$1"
	local asset_name="$2"

	awk -v asset_name="${asset_name}" '
		index($0, asset_name) == 0 {
			next
		}
		{
			line = $0
			if (match(line, /[0-9a-fA-F]{64}/)) {
				print tolower(substr(line, RSTART, RLENGTH))
				exit
			}
		}
	' "${checksum_file}"
}

release_asset_expected_sha256() {
	local release_json="$1"
	local asset_json="$2"
	local asset_name
	local asset_digest
	local checksum_asset_json
	local checksum_asset_url
	local checksum_file
	local expected_digest

	require_command jq

	asset_name="$(jq -r '.name' <<<"${asset_json}")"
	asset_digest="$(jq -r '.digest // ""' <<<"${asset_json}")"

	if [[ "${asset_digest}" == sha256:* ]]; then
		printf '%s\n' "${asset_digest#sha256:}"
		return 0
	fi

	checksum_asset_json="$(github_release_checksum_asset_json "${release_json}" || true)"
	[ -n "${checksum_asset_json}" ] || die "No checksum asset was published for ${asset_name}"

	checksum_asset_url="$(jq -r '.browser_download_url' <<<"${checksum_asset_json}")"
	[ -n "${checksum_asset_url}" ] && [ "${checksum_asset_url}" != "null" ] || die "Checksum asset download URL missing for ${asset_name}"

	checksum_file="$(mktemp)"
	download_url_to_file "${checksum_asset_url}" "${checksum_file}"
	expected_digest="$(release_asset_sha256_from_checksum_file "${checksum_file}" "${asset_name}")"
	rm -f "${checksum_file}"

	[ -n "${expected_digest}" ] || die "Unable to find SHA256 for ${asset_name} in published checksum manifest"
	printf '%s\n' "${expected_digest}"
}

download_verified_release_asset() {
	local release_json="$1"
	local asset_json="$2"
	local destination_path="$3"
	local asset_url
	local expected_digest

	require_command jq

	asset_url="$(jq -r '.browser_download_url' <<<"${asset_json}")"
	[ -n "${asset_url}" ] && [ "${asset_url}" != "null" ] || die "Release asset download URL missing"

	expected_digest="$(release_asset_expected_sha256 "${release_json}" "${asset_json}")"
	download_url_to_file "${asset_url}" "${destination_path}"
	verify_sha256_digest "${destination_path}" "${expected_digest}"
}

tool_release_repository() {
	case "$1" in
	actionlint)
		printf '%s\n' rhysd/actionlint
		;;
	helm-docs)
		printf '%s\n' norwoodj/helm-docs
		;;
	shfmt)
		printf '%s\n' mvdan/sh
		;;
	gitleaks)
		printf '%s\n' gitleaks/gitleaks
		;;
	kube-score)
		printf '%s\n' zegl/kube-score
		;;
	*)
		die "Unsupported tool for installation: $1"
		;;
	esac
}

tool_release_asset_candidates() {
	local tool_name="$1"
	local version="$2"
	local operating_system="$3"
	local architecture="$4"
	local clean_version="${version#v}"
	local asset_architecture="${architecture}"

	case "${tool_name}" in
	actionlint)
		printf '%s\n' "actionlint_${clean_version}_${operating_system}_${architecture}.tar.gz"
		;;
	helm-docs)
		case "${operating_system}" in
		linux)
			operating_system="Linux"
			;;
		darwin)
			operating_system="Darwin"
			;;
		esac
		case "${asset_architecture}" in
		amd64)
			asset_architecture="x86_64"
			;;
		esac
		printf '%s\n' "helm-docs_${clean_version}_${operating_system}_${asset_architecture}.tar.gz"
		;;
	shfmt)
		printf '%s\n' "shfmt_${version}_${operating_system}_${asset_architecture}"
		printf '%s\n' "shfmt_${clean_version}_${operating_system}_${asset_architecture}"
		;;
	gitleaks)
		case "${asset_architecture}" in
		amd64)
			asset_architecture="x64"
			;;
		arm64)
			asset_architecture="arm64"
			;;
		*)
			die "Unsupported architecture for gitleaks: ${asset_architecture}"
			;;
		esac
		printf '%s\n' "gitleaks_${clean_version}_${operating_system}_${asset_architecture}.tar.gz"
		;;
	kube-score)
		printf '%s\n' "kube-score_${clean_version}_${operating_system}_${asset_architecture}.tar.gz"
		printf '%s\n' "kube-score_${clean_version}_${operating_system}_${asset_architecture}"
		;;
	*)
		die "Unsupported tool for installation: ${tool_name}"
		;;
	esac
}

extract_verified_archive_binary() {
	local release_json="$1"
	local asset_json="$2"
	local archive_member="$3"
	local install_dir="$4"
	local install_name="$5"
	local temp_dir

	require_command install tar

	temp_dir="$(mktemp -d)"
	mkdir -p "${install_dir}"
	download_verified_release_asset "${release_json}" "${asset_json}" "${temp_dir}/archive.tgz"
	tar -xzf "${temp_dir}/archive.tgz" -C "${temp_dir}"
	install -m 0755 "${temp_dir}/${archive_member}" "${install_dir}/${install_name}"
	rm -rf "${temp_dir}"
}

install_verified_release_binary() {
	local release_json="$1"
	local asset_json="$2"
	local install_dir="$3"
	local install_name="$4"
	local temp_dir

	require_command install

	temp_dir="$(mktemp -d)"
	mkdir -p "${install_dir}"
	download_verified_release_asset "${release_json}" "${asset_json}" "${temp_dir}/${install_name}"
	install -m 0755 "${temp_dir}/${install_name}" "${install_dir}/${install_name}"
	rm -rf "${temp_dir}"
}

tools_install() {
	local tool_name=""
	local version=""
	local install_dir=""
	local operating_system
	local architecture
	local release_repository
	local release_json
	local asset_json
	local -a asset_candidates=()

	[ "$#" -ge 1 ] || die "tools install requires a tool name"
	tool_name="$1"
	shift

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--version)
			[ "$#" -ge 2 ] || die "--version requires a value"
			version="$2"
			shift 2
			;;
		--install-dir)
			[ "$#" -ge 2 ] || die "--install-dir requires a value"
			install_dir="$2"
			shift 2
			;;
		*)
			die "Unexpected argument for tools install: $1"
			;;
		esac
	done

	[ -n "${version}" ] || die "tools install requires --version"
	[ -n "${install_dir}" ] || die "tools install requires --install-dir"

	operating_system="$(normalize_os)"
	architecture="$(normalize_arch)"
	release_repository="$(tool_release_repository "${tool_name}")"
	release_json="$(github_release_metadata "${release_repository}" "${version}")"
	mapfile -t asset_candidates < <(tool_release_asset_candidates "${tool_name}" "${version}" "${operating_system}" "${architecture}")
	asset_json="$(github_release_asset_json_from_candidates "${release_json}" "${asset_candidates[@]}")" || die "Unable to locate release asset for ${tool_name} ${version}"

	case "${tool_name}" in
	actionlint | helm-docs)
		extract_verified_archive_binary "${release_json}" "${asset_json}" "${tool_name}" "${install_dir}" "${tool_name}"
		;;
	shfmt)
		install_verified_release_binary "${release_json}" "${asset_json}" "${install_dir}" shfmt
		;;
	gitleaks | kube-score)
		if [[ "$(jq -r '.name' <<<"${asset_json}")" == *.tar.gz ]]; then
			extract_verified_archive_binary "${release_json}" "${asset_json}" "${tool_name}" "${install_dir}" "${tool_name}"
		else
			install_verified_release_binary "${release_json}" "${asset_json}" "${install_dir}" "${tool_name}"
		fi
		;;
	*)
		die "Unsupported tool for installation: ${tool_name}"
		;;
	esac

	case "${tool_name}" in
	kube-score)
		"${install_dir}/${tool_name}" version
		;;
	*)
		"${install_dir}/${tool_name}" --version
		;;
	esac
}
