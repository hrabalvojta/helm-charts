#!/usr/bin/env bash

if [[ -n "${CHART_TOOL_GITHUB_SH_LOADED:-}" ]]; then
	return 0
fi
readonly CHART_TOOL_GITHUB_SH_LOADED=1

github_api_headers() {
	local -a headers=(
		-H "Accept: application/vnd.github+json"
		-H "X-GitHub-Api-Version: 2022-11-28"
	)

	if [ -n "${GITHUB_TOKEN:-}" ]; then
		headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	fi

	printf '%s\n' "${headers[@]}"
}

github_public_api_request() {
	local url="$1"
	local response_file
	local http_status
	local -a curl_args=(curl -sS)
	local header

	require_command curl

	response_file="$(mktemp)"
	while IFS= read -r header; do
		[ -n "${header}" ] || continue
		curl_args+=("${header}")
	done < <(github_api_headers)

	http_status="$(
		"${curl_args[@]}" \
			-o "${response_file}" \
			-w "%{http_code}" \
			"${url}"
	)"

	case "${http_status}" in
	2*)
		cat "${response_file}"
		;;
	*)
		warn "GitHub API request failed: GET ${url} (${http_status})"
		cat "${response_file}" >&2
		rm -f "${response_file}"
		return 1
		;;
	esac

	rm -f "${response_file}"
}

github_api_request() {
	local method="$1"
	local url="$2"
	local data_file="${3:-}"
	local content_type="${4:-application/json}"
	local response_file
	local http_status
	local -a curl_args=(curl -sS -X "${method}")
	local header

	[ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN must be set for GitHub release publishing"
	require_command curl

	response_file="$(mktemp)"
	while IFS= read -r header; do
		[ -n "${header}" ] || continue
		curl_args+=("${header}")
	done < <(github_api_headers)

	if [ -n "${content_type}" ]; then
		curl_args+=(-H "Content-Type: ${content_type}")
	fi

	if [ -n "${data_file}" ]; then
		curl_args+=(--data @"${data_file}")
	fi

	http_status="$(
		"${curl_args[@]}" \
			-o "${response_file}" \
			-w "%{http_code}" \
			"${url}"
	)"

	case "${http_status}" in
	2*)
		cat "${response_file}"
		;;
	*)
		warn "GitHub API request failed: ${method} ${url} (${http_status})"
		cat "${response_file}" >&2
		rm -f "${response_file}"
		return 1
		;;
	esac

	rm -f "${response_file}"
}

github_release_metadata() {
	local repository="$1"
	local tag_name="$2"
	local api_url="${GITHUB_API_URL:-https://api.github.com}"

	require_command jq
	github_public_api_request "${api_url}/repos/${repository}/releases/tags/${tag_name}"
}

github_release_asset_json_by_name() {
	local release_json="$1"
	local asset_name="$2"

	require_command jq
	jq -ce --arg asset_name "${asset_name}" 'first(.assets[] | select(.name == $asset_name))' <<<"${release_json}"
}

github_release_by_tag() {
	local tag_name="$1"
	local api_url="${GITHUB_API_URL:-https://api.github.com}"
	local response_file
	local http_status
	local -a curl_args=(curl -sS)
	local header

	[ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN must be set for GitHub release publishing"
	require_command curl

	response_file="$(mktemp)"
	while IFS= read -r header; do
		[ -n "${header}" ] || continue
		curl_args+=("${header}")
	done < <(github_api_headers)

	http_status="$(
		"${curl_args[@]}" \
			-o "${response_file}" \
			-w "%{http_code}" \
			"${api_url}/repos/${GITHUB_REPOSITORY}/releases/tags/${tag_name}"
	)"

	case "${http_status}" in
	200)
		cat "${response_file}"
		rm -f "${response_file}"
		return 0
		;;
	404)
		rm -f "${response_file}"
		return 1
		;;
	*)
		warn "Unable to query release ${tag_name} (${http_status})"
		cat "${response_file}" >&2
		rm -f "${response_file}"
		die "GitHub release lookup failed for ${tag_name}"
		;;
	esac
}

upload_release_asset() {
	local upload_url="$1"
	local asset_path="$2"
	local response_file
	local http_status
	local asset_name
	local content_type
	local -a curl_args=(curl -sS -X POST)
	local header

	[ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN must be set for GitHub release publishing"
	require_command curl

	asset_name="$(basename "${asset_path}")"
	case "${asset_name}" in
	*.tgz)
		content_type="application/gzip"
		;;
	*.sha256 | *.sig | *.cert)
		content_type="text/plain"
		;;
	*)
		content_type="application/octet-stream"
		;;
	esac

	response_file="$(mktemp)"
	while IFS= read -r header; do
		[ -n "${header}" ] || continue
		curl_args+=("${header}")
	done < <(github_api_headers)
	curl_args+=(
		-H "Content-Type: ${content_type}"
		--data-binary @"${asset_path}"
	)

	http_status="$(
		"${curl_args[@]}" \
			-o "${response_file}" \
			-w "%{http_code}" \
			"${upload_url}?name=${asset_name}"
	)"

	case "${http_status}" in
	2*)
		cat "${response_file}"
		;;
	*)
		warn "Asset upload failed for ${asset_name} (${http_status})"
		cat "${response_file}" >&2
		rm -f "${response_file}"
		return 1
		;;
	esac

	rm -f "${response_file}"
}
