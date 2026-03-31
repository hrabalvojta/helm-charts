#!/usr/bin/env bash

if [[ -n "${CHART_TOOL_RELEASE_SH_LOADED:-}" ]]; then
	return 0
fi
readonly CHART_TOOL_RELEASE_SH_LOADED=1

chart_exists_in_registry() {
	local chart_name_value="$1"
	local chart_version_value="$2"
	local registry_check_dir="$3"
	local registry="${REGISTRY:-ghcr.io}"
	local oci_namespace="${OCI_NAMESPACE:-${GITHUB_REPOSITORY}}"

	helm pull "oci://${registry}/${oci_namespace}/${chart_name_value}" \
		--version "${chart_version_value}" \
		--destination "${registry_check_dir}" \
		>/dev/null 2>&1
}

fetch_registry_manifest_digest() {
	local chart_name_value="$1"
	local chart_version_value="$2"
	local registry="${REGISTRY:-ghcr.io}"
	local oci_namespace="${OCI_NAMESPACE:-${GITHUB_REPOSITORY}}"
	local registry_url="https://${registry}"
	local manifest_url="${registry_url}/v2/${oci_namespace}/${chart_name_value}/manifests/${chart_version_value}"
	local response_headers
	local http_status
	local digest
	local registry_user="${GITHUB_ACTOR:-${CHART_TOOL_RELEASE_AUTHOR_NAME}}"

	[ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN must be set to resolve OCI digests from ${registry}"
	require_command awk curl

	response_headers="$(mktemp)"
	http_status="$(
		curl \
			-sS \
			-I \
			-u "${registry_user}:${GITHUB_TOKEN}" \
			-H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.artifact.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
			-o "${response_headers}" \
			-w "%{http_code}" \
			"${manifest_url}"
	)"

	case "${http_status}" in
	2*)
		digest="$(
			awk '
				BEGIN { IGNORECASE = 1 }
				/^docker-content-digest:/ {
					gsub(/\r/, "", $2)
					print $2
					exit
				}
			' "${response_headers}"
		)"
		rm -f "${response_headers}"
		[ -n "${digest}" ] || die "Registry digest header missing for ${chart_name_value}:${chart_version_value}"
		printf '%s\n' "${digest}"
		;;
	*)
		cat "${response_headers}" >&2
		rm -f "${response_headers}"
		die "Unable to resolve OCI digest for ${chart_name_value}:${chart_version_value} (${http_status})"
		;;
	esac
}

normalize_oci_digest() {
	local raw_value="${1:-}"
	local digest=""

	if [ -z "${raw_value}" ]; then
		return 0
	fi

	digest="$(printf '%s\n' "${raw_value}" | grep -Eo 'sha256:[0-9a-f]{64}' | head -n1 || true)"
	printf '%s\n' "${digest}"
}

publish_oci_chart() {
	local chart_dir="$1"
	local package_dir="$2"
	local registry_check_dir="$3"
	local chart_name_value
	local chart_version_value
	local package_path
	local push_output
	local digest
	local published_digest=""
	local registry="${REGISTRY:-ghcr.io}"
	local oci_namespace="${OCI_NAMESPACE:-${GITHUB_REPOSITORY}}"
	local oci_reference
	local cosign_identity="${COSIGN_CERT_IDENTITY:-}"

	require_command cosign helm

	chart_name_value="$(chart_name "${chart_dir}")"
	chart_version_value="$(chart_version "${chart_dir}")"
	package_path="${package_dir}/${chart_name_value}-${chart_version_value}.tgz"

	[ -f "${package_path}" ] || die "Packaged chart not found: ${package_path}"

	if chart_exists_in_registry "${chart_name_value}" "${chart_version_value}" "${registry_check_dir}"; then
		info "Skipping OCI publish for ${chart_name_value}:${chart_version_value}; artifact already exists"
	else
		push_output="$(helm push "${package_path}" "oci://${registry}/${oci_namespace}" 2>&1)"
		printf '%s\n' "${push_output}" >&2

		published_digest="$(normalize_oci_digest "${push_output}")"
		[ -n "${published_digest}" ] || die "Unable to determine registry digest for ${chart_name_value}:${chart_version_value}"

		oci_reference="${registry}/${oci_namespace}/${chart_name_value}@${published_digest}"
		COSIGN_YES=true cosign sign "${oci_reference}" >/dev/null

		if [ -n "${cosign_identity}" ]; then
			cosign verify \
				--certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
				--certificate-identity "${cosign_identity}" \
				"${oci_reference}" >/dev/null
		else
			warn "COSIGN_CERT_IDENTITY is not set; falling back to workflow-path regex verification"
			cosign verify \
				--certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
				--certificate-identity-regexp "^https://github.com/${GITHUB_REPOSITORY}/.github/workflows/release.yaml@.+$" \
				"${oci_reference}" >/dev/null
		fi

		info "Published and signed ${oci_reference}"
	fi

	digest="$(fetch_registry_manifest_digest "${chart_name_value}" "${chart_version_value}")"
	if [ -z "${digest}" ]; then
		digest="${published_digest}"
	fi

	digest="$(normalize_oci_digest "${digest}")"
	[ -n "${digest}" ] || die "Unable to resolve OCI digest for ${chart_name_value}:${chart_version_value}"
	printf '%s\n' "${digest}"
}

release_template_file() {
	printf '%s/.github/release-template.md\n' "${CHART_TOOL_ROOT_DIR}"
}

chart_release_tag() {
	local chart_dir="$1"
	printf '%s-%s\n' "$(chart_name "${chart_dir}")" "$(chart_version "${chart_dir}")"
}

chart_release_title() {
	local chart_dir="$1"
	printf '%s %s\n' "$(chart_name "${chart_dir}")" "$(chart_version "${chart_dir}")"
}

chart_oci_repository() {
	local chart_dir="$1"
	local registry="${REGISTRY:-ghcr.io}"
	local oci_namespace="${OCI_NAMESPACE:-${GITHUB_REPOSITORY}}"

	printf 'oci://%s/%s/%s\n' "${registry}" "${oci_namespace}" "$(chart_name "${chart_dir}")"
}

chart_pages_repository_url() {
	local repo_name="${GITHUB_REPOSITORY#*/}"
	printf 'https://%s.github.io/%s\n' "${GITHUB_REPOSITORY_OWNER}" "${repo_name}"
}

package_sha256_file() {
	local package_path="$1"
	printf '%s.sha256\n' "${package_path}"
}

package_bundle_file() {
	local package_path="$1"
	printf '%s.sigstore.json\n' "${package_path}"
}

create_package_checksum_asset() {
	local package_path="$1"
	local checksum_file

	checksum_file="$(package_sha256_file "${package_path}")"
	printf '%s  %s\n' "$(sha256_digest "${package_path}")" "$(basename "${package_path}")" >"${checksum_file}"
}

create_package_bundle_asset() {
	local package_path="$1"
	local cosign_identity="${COSIGN_CERT_IDENTITY:-}"
	local bundle_file

	require_command cosign

	bundle_file="$(package_bundle_file "${package_path}")"

	COSIGN_YES=true cosign sign-blob \
		--bundle "${bundle_file}" \
		"${package_path}" >/dev/null

	if [ -n "${cosign_identity}" ]; then
		cosign verify-blob \
			--bundle "${bundle_file}" \
			--certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
			--certificate-identity "${cosign_identity}" \
			"${package_path}" >/dev/null
	else
		warn "COSIGN_CERT_IDENTITY is not set; falling back to workflow-path regex verification for blob bundle verification"
		cosign verify-blob \
			--bundle "${bundle_file}" \
			--certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
			--certificate-identity-regexp "^https://github.com/${GITHUB_REPOSITORY}/.github/workflows/release.yaml@.+$" \
			"${package_path}" >/dev/null
	fi
}

prepare_release_assets() {
	local package_path="$1"
	local sign_blob="${2:-false}"

	[ -f "${package_path}" ] || die "Packaged chart not found: ${package_path}"
	create_package_checksum_asset "${package_path}"

	if [ "${sign_blob}" = true ]; then
		create_package_bundle_asset "${package_path}"
	fi
}

release_asset_paths_for_package() {
	local package_path="$1"
	local bundle_file

	printf '%s\n' "${package_path}"
	printf '%s\n' "$(package_sha256_file "${package_path}")"

	bundle_file="$(package_bundle_file "${package_path}")"

	[ -f "${bundle_file}" ] && printf '%s\n' "${bundle_file}"
}

package_sha256_value() {
	local package_path="$1"
	local checksum_file

	checksum_file="$(package_sha256_file "${package_path}")"
	[ -f "${checksum_file}" ] || die "Checksum asset not found: ${checksum_file}"
	awk '{ print $1; exit }' "${checksum_file}"
}

release_asset_download_url() {
	local chart_dir="$1"
	local asset_name="$2"
	printf 'https://github.com/%s/releases/download/%s/%s\n' "${GITHUB_REPOSITORY}" "$(chart_release_tag "${chart_dir}")" "${asset_name}"
}

release_assets_table_rows() {
	local chart_dir="$1"
	local package_path="$2"
	local oci_digest="${3:-}"
	local pages_repository_url
	local oci_repository
	local package_name
	local checksum_name
	local bundle_name
	local rows=""

	pages_repository_url="$(chart_pages_repository_url)"
	oci_repository="$(chart_oci_repository "${chart_dir}")"
	oci_digest="$(normalize_oci_digest "${oci_digest}")"
	package_name="$(basename "${package_path}")"
	checksum_name="$(basename "$(package_sha256_file "${package_path}")")"

	rows+="| [\`${package_name}\`]($(release_asset_download_url "${chart_dir}" "${package_name}")) | Packaged Helm chart attached to this GitHub Release. |"$'\n'
	rows+="| [\`${checksum_name}\`]($(release_asset_download_url "${chart_dir}" "${checksum_name}")) | SHA256 checksum for the packaged chart asset. |"$'\n'

	bundle_name="$(basename "$(package_bundle_file "${package_path}")")"
	if [ -f "$(package_bundle_file "${package_path}")" ]; then
		rows+="| [\`${bundle_name}\`]($(release_asset_download_url "${chart_dir}" "${bundle_name}")) | Sigstore bundle containing the blob signature, certificate, timestamp, and transparency proof. |"$'\n'
	fi

	if [ -n "${oci_digest}" ] && [ "${oci_digest}" != "n/a" ]; then
		rows+="| \`${oci_repository}@${oci_digest}\` | Immutable OCI chart reference for this release. |"$'\n'
	else
		rows+="| \`${oci_repository}\` | OCI chart reference. Digest is unavailable in this dry run. |"$'\n'
	fi

	rows+="| [\`${pages_repository_url}/index.yaml\`](${pages_repository_url}/index.yaml) | Static Helm repository index served from \`gh-pages\`. |"
	printf '%s\n' "${rows}"
}

find_previous_chart_release_tag() {
	local chart_dir="$1"
	local current_tag
	local tag_name

	current_tag="$(chart_release_tag "${chart_dir}")"

	while IFS= read -r tag_name; do
		[ -n "${tag_name}" ] || continue
		[ "${tag_name}" = "${current_tag}" ] && continue
		printf '%s\n' "${tag_name}"
		return 0
	done < <(
		git -C "${CHART_TOOL_ROOT_DIR}" tag --list "$(chart_name "${chart_dir}")-*" --sort=-version:refname
	)
}

release_target_commit() {
	if [ -n "${GITHUB_SHA:-}" ]; then
		printf '%s\n' "${GITHUB_SHA}"
		return 0
	fi

	git -C "${CHART_TOOL_ROOT_DIR}" rev-parse HEAD
}

assert_release_tag_is_reusable() {
	local chart_dir="$1"
	local tag_name
	local target_commit
	local tagged_commit

	tag_name="$(chart_release_tag "${chart_dir}")"
	target_commit="$(release_target_commit)"

	if ! git -C "${CHART_TOOL_ROOT_DIR}" rev-parse --verify --quiet "refs/tags/${tag_name}" >/dev/null; then
		return 0
	fi

	tagged_commit="$(git -C "${CHART_TOOL_ROOT_DIR}" rev-list -n 1 "${tag_name}")"
	[ "${tagged_commit}" = "${target_commit}" ] || die "Release tag ${tag_name} already points to ${tagged_commit}; refusing to reuse chart version on ${target_commit}"
}

markdown_release_changelog() {
	local chart_dir="$1"
	local previous_tag="${2:-}"
	local target_commit
	local range_spec
	local output=""
	local commit_sha
	local commit_subject

	target_commit="$(release_target_commit)"

	if [ -n "${previous_tag}" ]; then
		range_spec="${previous_tag}..${target_commit}"
	else
		range_spec="${target_commit}"
	fi

	while IFS=$'\t' read -r commit_sha commit_subject; do
		[ -n "${commit_sha}" ] || continue
		output+="- ${commit_subject} ([\`${commit_sha:0:7}\`](https://github.com/${GITHUB_REPOSITORY}/commit/${commit_sha}))"$'\n'
	done < <(
		git -C "${CHART_TOOL_ROOT_DIR}" log \
			--reverse \
			--no-merges \
			--format='%H%x09%s' \
			"${range_spec}" \
			-- "${chart_dir}"
	)

	if [ -z "${output}" ]; then
		output='- No chart-path commits were found for this release range.'
	fi

	printf '%s\n' "${output%$'\n'}"
}

markdown_release_contributors() {
	local chart_dir="$1"
	local previous_tag="${2:-}"
	local target_commit
	local range_spec
	local output=""
	local count
	local contributor_name

	target_commit="$(release_target_commit)"

	if [ -n "${previous_tag}" ]; then
		range_spec="${previous_tag}..${target_commit}"
	else
		range_spec="${target_commit}"
	fi

	while IFS=$'\t' read -r count contributor_name; do
		[ -n "${contributor_name}" ] || continue
		output+="- ${contributor_name} (${count} commit"
		[ "${count}" = "1" ] || output+="s"
		output+=")"$'\n'
	done < <(
		git -C "${CHART_TOOL_ROOT_DIR}" shortlog -sn "${range_spec}" -- "${chart_dir}" |
			sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+(.+)$/\1\t\2/'
	)

	if [ -z "${output}" ]; then
		output='- No distinct contributors were found for this release range.'
	fi

	printf '%s\n' "${output%$'\n'}"
}

render_release_notes() {
	local chart_dir="$1"
	local package_path="$2"
	local oci_digest="${3:-}"
	local destination_path="$4"
	local template_path
	local chart_name_value
	local chart_version_value
	local chart_app_version_value
	local chart_description_value
	local chart_kube_version_value
	local release_tag_value
	local release_title_value
	local previous_tag
	local compare_url_value="n/a"
	local changelog_value
	local contributors_value
	local asset_name
	local oci_repository
	local pages_repository_url
	local release_date_value
	local commit_sha_value
	local package_sha256_digest
	local assets_table_rows

	template_path="$(release_template_file)"
	[ -f "${template_path}" ] || die "Release template not found: ${template_path}"
	[ -f "${package_path}" ] || die "Packaged chart not found: ${package_path}"

	chart_name_value="$(chart_name "${chart_dir}")"
	chart_version_value="$(chart_version "${chart_dir}")"
	chart_app_version_value="$(chart_app_version "${chart_dir}")"
	chart_description_value="$(chart_description "${chart_dir}")"
	chart_kube_version_value="$(chart_kube_version "${chart_dir}")"
	release_tag_value="$(chart_release_tag "${chart_dir}")"
	release_title_value="$(chart_release_title "${chart_dir}")"
	previous_tag="$(find_previous_chart_release_tag "${chart_dir}" || true)"
	changelog_value="$(markdown_release_changelog "${chart_dir}" "${previous_tag}")"
	contributors_value="$(markdown_release_contributors "${chart_dir}" "${previous_tag}")"
	asset_name="$(basename "${package_path}")"
	oci_repository="$(chart_oci_repository "${chart_dir}")"
	pages_repository_url="$(chart_pages_repository_url)"
	release_date_value="$(date -u +%Y-%m-%d)"
	commit_sha_value="$(release_target_commit)"
	package_sha256_digest="$(package_sha256_value "${package_path}")"
	assets_table_rows="$(release_assets_table_rows "${chart_dir}" "${package_path}" "${oci_digest}")"

	oci_digest="$(normalize_oci_digest "${oci_digest}")"
	if [ -z "${oci_digest}" ]; then
		oci_digest="n/a"
	fi

	if [ -n "${previous_tag}" ]; then
		compare_url_value="https://github.com/${GITHUB_REPOSITORY}/compare/${previous_tag}...${release_tag_value}"
	fi

	awk \
		-v chart_name_value="${chart_name_value}" \
		-v chart_version_value="${chart_version_value}" \
		-v chart_app_version_value="${chart_app_version_value}" \
		-v chart_description_value="${chart_description_value}" \
		-v chart_kube_version_value="${chart_kube_version_value}" \
		-v release_tag_value="${release_tag_value}" \
		-v release_title_value="${release_title_value}" \
		-v release_date_value="${release_date_value}" \
		-v commit_sha_value="${commit_sha_value}" \
		-v previous_tag_value="${previous_tag:-n/a}" \
		-v compare_url_value="${compare_url_value}" \
		-v asset_name_value="${asset_name}" \
		-v oci_repository_value="${oci_repository}" \
		-v oci_digest_value="${oci_digest}" \
		-v package_sha256_value="${package_sha256_digest}" \
		-v pages_repository_url_value="${pages_repository_url}" \
		-v assets_table_rows_value="${assets_table_rows}" \
		-v changelog_value="${changelog_value}" \
		-v contributors_value="${contributors_value}" '
		{
			if ($0 == "{{CHANGELOG}}") {
				print changelog_value
				next
			}

			if ($0 == "{{CONTRIBUTORS}}") {
				print contributors_value
				next
			}

			if ($0 == "{{ASSET_TABLE_ROWS}}") {
				print assets_table_rows_value
				next
			}

			gsub(/\{\{CHART_NAME\}\}/, chart_name_value)
			gsub(/\{\{CHART_VERSION\}\}/, chart_version_value)
			gsub(/\{\{APP_VERSION\}\}/, chart_app_version_value)
			gsub(/\{\{CHART_DESCRIPTION\}\}/, chart_description_value)
			gsub(/\{\{KUBE_VERSION\}\}/, chart_kube_version_value)
			gsub(/\{\{RELEASE_TAG\}\}/, release_tag_value)
			gsub(/\{\{RELEASE_TITLE\}\}/, release_title_value)
			gsub(/\{\{RELEASE_DATE\}\}/, release_date_value)
			gsub(/\{\{COMMIT_SHA\}\}/, commit_sha_value)
			gsub(/\{\{PREVIOUS_TAG\}\}/, previous_tag_value)
			gsub(/\{\{COMPARE_URL\}\}/, compare_url_value)
			gsub(/\{\{HELM_PACKAGE_NAME\}\}/, asset_name_value)
			gsub(/\{\{OCI_REPOSITORY\}\}/, oci_repository_value)
			gsub(/\{\{OCI_DIGEST\}\}/, oci_digest_value)
			gsub(/\{\{PACKAGE_SHA256\}\}/, package_sha256_value)
			gsub(/\{\{PAGES_REPOSITORY_URL\}\}/, pages_repository_url_value)

			print
		}
	' "${template_path}" >"${destination_path}"
}

publish_github_release() {
	local chart_dir="$1"
	local release_notes_path="$2"
	shift 2
	local api_url="${GITHUB_API_URL:-https://api.github.com}"
	local target_commit
	local tag_name
	local release_name
	local release_version
	local prerelease=false
	local payload_file
	local release_json
	local release_id
	local upload_url
	local release_url
	local asset_name
	local existing_asset_id
	local asset_path
	local -a asset_paths=("$@")

	require_command git jq
	[ -f "${release_notes_path}" ] || die "Release notes not found: ${release_notes_path}"
	[ "${#asset_paths[@]}" -gt 0 ] || die "At least one release asset is required for GitHub release publishing"

	assert_release_tag_is_reusable "${chart_dir}"

	target_commit="$(release_target_commit)"
	tag_name="$(chart_release_tag "${chart_dir}")"
	release_name="$(chart_release_title "${chart_dir}")"
	release_version="$(chart_version "${chart_dir}")"

	if [[ "${release_version}" == *-* ]]; then
		prerelease=true
	fi

	payload_file="$(mktemp)"
	jq -n \
		--arg tag_name "${tag_name}" \
		--arg target_commitish "${target_commit}" \
		--arg name "${release_name}" \
		--rawfile body "${release_notes_path}" \
		--argjson prerelease "${prerelease}" \
		'{
			tag_name: $tag_name,
			target_commitish: $target_commitish,
			name: $name,
			body: $body,
			draft: false,
			prerelease: $prerelease,
			generate_release_notes: false
		}' >"${payload_file}"

	if release_json="$(github_release_by_tag "${tag_name}")"; then
		release_id="$(jq -r '.id' <<<"${release_json}")"
		for asset_path in "${asset_paths[@]}"; do
			asset_name="$(basename "${asset_path}")"
			existing_asset_id="$(jq -r --arg asset_name "${asset_name}" 'first(.assets[]? | select(.name == $asset_name) | .id) // empty' <<<"${release_json}")"

			if [ -n "${existing_asset_id:-}" ] && [ "${existing_asset_id}" != "null" ]; then
				github_api_request DELETE "${api_url}/repos/${GITHUB_REPOSITORY}/releases/assets/${existing_asset_id}" "" ""
			fi
		done

		release_json="$(github_api_request PATCH "${api_url}/repos/${GITHUB_REPOSITORY}/releases/${release_id}" "${payload_file}")"
	else
		release_json="$(github_api_request POST "${api_url}/repos/${GITHUB_REPOSITORY}/releases" "${payload_file}")"
	fi

	rm -f "${payload_file}"

	upload_url="$(jq -r '.upload_url' <<<"${release_json}")"
	release_url="$(jq -r '.html_url' <<<"${release_json}")"
	[ -n "${upload_url}" ] && [ "${upload_url}" != "null" ] || die "GitHub release upload URL missing for ${tag_name}"
	[ -n "${release_url}" ] && [ "${release_url}" != "null" ] || die "GitHub release URL missing for ${tag_name}"

	for asset_path in "${asset_paths[@]}"; do
		[ -f "${asset_path}" ] || die "Release asset not found: ${asset_path}"
		upload_release_asset "${upload_url%%\{*}" "${asset_path}" >/dev/null
	done

	info "Published GitHub release ${release_url} with ${#asset_paths[@]} asset(s)"
}

prepare_pages_worktree() {
	local worktree_dir="$1"
	local pages_branch="${PAGES_BRANCH:-gh-pages}"
	local has_existing_branch=false
	local previous_dir

	require_command git

	rm -rf "${worktree_dir}"
	previous_dir="$(pwd)"

	cd "${CHART_TOOL_ROOT_DIR}" || exit
	git worktree prune >/dev/null 2>&1 || true

	if git ls-remote --exit-code --heads origin "${pages_branch}" >/dev/null 2>&1; then
		has_existing_branch=true
		git fetch --no-tags origin "${pages_branch}:${pages_branch}" >/dev/null 2>&1
		git worktree add --force -B "${pages_branch}" "${worktree_dir}" "${pages_branch}" >/dev/null
	else
		git worktree add --detach "${worktree_dir}" HEAD >/dev/null
	fi

	cd "${previous_dir}" || exit

	if [ "${has_existing_branch}" = true ]; then
		return 0
	fi

	(
		cd "${worktree_dir}" || exit
		git switch --orphan "${pages_branch}" >/dev/null
		find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
	)
}

build_pages_site() {
	local site_dir="$1"
	local package_dir="$2"
	local worktree_dir="$3"
	local repo_name="${GITHUB_REPOSITORY#*/}"
	local repo_url="https://${GITHUB_REPOSITORY_OWNER}.github.io/${repo_name}"

	require_command cp find helm

	rm -rf "${site_dir}"
	mkdir -p "${site_dir}/charts"

	if [ -d "${worktree_dir}/charts" ]; then
		find "${worktree_dir}/charts" -maxdepth 1 -type f -name '*.tgz' -exec cp -f {} "${site_dir}/charts/" \;
	fi

	find "${package_dir}" -maxdepth 1 -type f -name '*.tgz' -exec cp -f {} "${site_dir}/charts/" \;

	if [ -f "${CHART_TOOL_ROOT_DIR}/artifacthub-repo.yml" ]; then
		cp -f "${CHART_TOOL_ROOT_DIR}/artifacthub-repo.yml" "${site_dir}/artifacthub-repo.yml"
	fi

	if [ -f "${worktree_dir}/index.yaml" ]; then
		cp -f "${worktree_dir}/index.yaml" "${site_dir}/index.yaml"
		helm repo index "${site_dir}/charts" --url "${repo_url}/charts" --merge "${site_dir}/index.yaml" >/dev/null
	else
		helm repo index "${site_dir}/charts" --url "${repo_url}/charts" >/dev/null
	fi

	mv "${site_dir}/charts/index.yaml" "${site_dir}/index.yaml"
	touch "${site_dir}/.nojekyll"
}

publish_pages_site() {
	local site_dir="$1"
	local worktree_dir="$2"
	local pages_branch="${PAGES_BRANCH:-gh-pages}"

	(
		cd "${worktree_dir}" || exit
		find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
		cp -a "${site_dir}/." .

		git config user.name "${CHART_TOOL_RELEASE_AUTHOR_NAME}"
		git config user.email "${CHART_TOOL_RELEASE_AUTHOR_EMAIL}"
		git add --all

		if git diff --cached --quiet; then
			info "No changes detected for ${pages_branch}"
			return 0
		fi

		git commit -m "chore(release): publish helm repository" >/dev/null
		git push origin "${pages_branch}" >/dev/null
	)
}

release_publish() {
	local publish_all=false
	local dry_run=false
	local charts_json=""
	local base_ref=""
	local head_ref=""
	local chart_dir
	local worktree_dir
	local package_dir
	local registry_check_dir
	local site_dir
	local release_notes_dir
	local -a chart_dirs=()
	local -A chart_oci_digests=()

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--all)
			publish_all=true
			shift
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--charts-json)
			[ "$#" -ge 2 ] || die "--charts-json requires JSON input"
			charts_json="$2"
			shift 2
			;;
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
		*)
			die "Unexpected argument for release publish: $1"
			;;
		esac
	done

	: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
	: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
	: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER must be set}"

	if [ -n "${charts_json}" ]; then
		mapfile -t chart_dirs < <(json_array_to_lines "${charts_json}")
	elif [ "${publish_all}" = true ]; then
		mapfile -t chart_dirs < <(list_all_chart_dirs)
	else
		[ -n "${base_ref}" ] || die "release publish requires --all, --charts-json, or --base/--head"
		[ -n "${head_ref}" ] || die "release publish requires --head when using --base"
		mapfile -t chart_dirs < <(list_changed_chart_dirs "${base_ref}" "${head_ref}")
	fi

	if [ "${#chart_dirs[@]}" -eq 0 ]; then
		info "No charts selected for release publishing; rebuilding Pages metadata only"
	fi

	package_dir="${RUNNER_TEMP}/chart-packages"
	registry_check_dir="${RUNNER_TEMP}/registry-check"
	site_dir="${RUNNER_TEMP}/gh-pages-site"
	worktree_dir="${RUNNER_TEMP}/gh-pages-worktree"
	release_notes_dir="${RUNNER_TEMP}/github-release-notes"

	mkdir -p "${package_dir}" "${registry_check_dir}" "${release_notes_dir}"
	trap 'git -C "${CHART_TOOL_ROOT_DIR}" worktree remove --force "'"${worktree_dir}"'" >/dev/null 2>&1 || true' EXIT

	if [ "${#chart_dirs[@]}" -gt 0 ]; then
		for chart_dir in "${chart_dirs[@]}"; do
			audit_chart "${chart_dir}"
			docs_check_chart "${chart_dir}"
			charts_test --chart "${chart_dir}"
			package_chart "${chart_dir}" "${package_dir}"
			if [ "${dry_run}" = true ]; then
				prepare_release_assets "${package_dir}/$(chart_name "${chart_dir}")-$(chart_version "${chart_dir}").tgz" false
			else
				prepare_release_assets "${package_dir}/$(chart_name "${chart_dir}")-$(chart_version "${chart_dir}").tgz" true
			fi
			if [ "${dry_run}" = false ]; then
				chart_oci_digests["${chart_dir}"]="$(publish_oci_chart "${chart_dir}" "${package_dir}" "${registry_check_dir}")"
			fi
		done
	fi

	if [ "${dry_run}" = true ]; then
		info "Release dry run enabled; skipping OCI publish and gh-pages push"
		mkdir -p "${worktree_dir}"
	else
		prepare_pages_worktree "${worktree_dir}"
	fi

	build_pages_site "${site_dir}" "${package_dir}" "${worktree_dir}"

	if [ "${dry_run}" = false ]; then
		publish_pages_site "${site_dir}" "${worktree_dir}"
	fi

	if [ "${#chart_dirs[@]}" -eq 0 ]; then
		return 0
	fi

	for chart_dir in "${chart_dirs[@]}"; do
		local chart_name_value
		local chart_version_value
		local package_path
		local release_notes_path
		local oci_digest
		local -a release_asset_paths=()

		chart_name_value="$(chart_name "${chart_dir}")"
		chart_version_value="$(chart_version "${chart_dir}")"
		package_path="${package_dir}/${chart_name_value}-${chart_version_value}.tgz"
		release_notes_path="${release_notes_dir}/${chart_name_value}-${chart_version_value}.md"
		oci_digest="${chart_oci_digests[${chart_dir}]:-}"
		mapfile -t release_asset_paths < <(release_asset_paths_for_package "${package_path}")

		render_release_notes "${chart_dir}" "${package_path}" "${oci_digest}" "${release_notes_path}"

		if [ "${dry_run}" = false ]; then
			publish_github_release "${chart_dir}" "${release_notes_path}" "${release_asset_paths[@]}"
		fi
	done

	if [ "${dry_run}" = true ]; then
		info "Release dry run enabled; rendered GitHub release notes to ${release_notes_dir}"
	fi
}
