#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/chart-tool.sh discover all [--format lines|json]
  scripts/chart-tool.sh discover changed --base <ref> --head <ref> [--format lines|json]
  scripts/chart-tool.sh repo lint
  scripts/chart-tool.sh version check --base <ref> --head <ref>
  scripts/chart-tool.sh charts audit [--charts-json <json> | <chart>...]
  scripts/chart-tool.sh charts docs-check [--charts-json <json> | <chart>...]
  scripts/chart-tool.sh charts test --chart <chart> [--scenario <name>]
  scripts/chart-tool.sh charts package --destination <dir> [--charts-json <json> | <chart>...]
  scripts/chart-tool.sh tools install <actionlint|helm-docs> --version <version> --install-dir <dir>
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
  require_command actionlint jq shellcheck

  (
    cd "${CHART_TOOL_ROOT_DIR}"
    actionlint .github/workflows/*.yaml
    shellcheck scripts/*.sh scripts/lib/*.sh
    [ -f .github/release-template.md ] || die "Missing .github/release-template.md"
    jq empty .github/renovate.json5 >/dev/null
  )
}

check_chart_version_bump() {
  local chart_dir="$1"
  local base_ref="$2"
  local current_version
  local previous_chart_path
  local previous_chart_file
  local previous_version

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
  semver_gt "${current_version}" "${previous_version}" || die "${chart_dir} version must increase relative to ${base_ref} (${previous_version} -> ${current_version})"
}

version_check() {
  local base_ref=""
  local head_ref=""
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
    check_chart_version_bump "${chart_dir}" "${base_ref}"
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

run_chart_render_scenario() {
  local chart_dir="$1"
  local scenario="$2"
  local release_name
  local -a extra_args=()

  release_name="$(sanitize_release_name "$(basename "${chart_dir}")" "${scenario}")"
  mapfile -t extra_args < <(scenario_template_args "${scenario}")

  (
    cd "${CHART_TOOL_ROOT_DIR}"
    helm template "${release_name}" "${chart_dir}" --include-crds "${extra_args[@]}" >/dev/null
  )
}

charts_test() {
  local chart_dir=""
  local scenario=""
  local active_scenario
  local -a scenarios=()

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
      *)
        die "Unexpected argument for charts test: $1"
        ;;
    esac
  done

  [ -n "${chart_dir}" ] || die "charts test requires --chart"
  audit_chart "${chart_dir}"
  require_command helm

  if [ -n "${scenario}" ]; then
    scenarios=("${scenario}")
  else
    mapfile -t scenarios < <(chart_default_scenarios)
  fi

  (
    cd "${CHART_TOOL_ROOT_DIR}"
    helm dependency build "${chart_dir}" >/dev/null
    helm lint "${chart_dir}" --strict >/dev/null
  )

  for active_scenario in "${scenarios[@]}"; do
    run_chart_render_scenario "${chart_dir}" "${active_scenario}"
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
    x86_64|amd64)
      printf '%s\n' amd64
      ;;
    arm64|aarch64)
      printf '%s\n' arm64
      ;;
    *)
      die "Unsupported architecture: $(uname -m)"
      ;;
  esac
}

download_and_install_binary() {
  local url="$1"
  local binary_name="$2"
  local install_dir="$3"
  local temp_dir

  require_command curl install tar

  temp_dir="$(mktemp -d)"

  mkdir -p "${install_dir}"
  curl -fsSL "${url}" -o "${temp_dir}/archive.tgz"
  tar -xzf "${temp_dir}/archive.tgz" -C "${temp_dir}"
  install -m 0755 "${temp_dir}/${binary_name}" "${install_dir}/${binary_name}"
  rm -rf "${temp_dir}"
}

tools_install() {
  local tool_name=""
  local version=""
  local install_dir=""
  local operating_system
  local architecture
  local clean_version
  local download_url

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

  case "${tool_name}" in
    actionlint)
      clean_version="${version#v}"
      download_url="https://github.com/rhysd/actionlint/releases/download/v${clean_version}/actionlint_${clean_version}_${operating_system}_${architecture}.tar.gz"
      download_and_install_binary "${download_url}" actionlint "${install_dir}"
      ;;
    helm-docs)
      clean_version="${version#v}"
      case "${architecture}" in
        amd64)
          architecture="x86_64"
          ;;
      esac
      download_url="https://github.com/norwoodj/helm-docs/releases/download/v${clean_version}/helm-docs_${clean_version}_${operating_system}_${architecture}.tar.gz"
      download_and_install_binary "${download_url}" helm-docs "${install_dir}"
      ;;
    *)
      die "Unsupported tool for installation: ${tool_name}"
      ;;
  esac

  "${install_dir}/${tool_name}" --version
}

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

publish_oci_chart() {
  local chart_dir="$1"
  local package_dir="$2"
  local registry_check_dir="$3"
  local chart_name_value
  local chart_version_value
  local package_path
  local push_output
  local digest
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
    return 0
  fi

  push_output="$(helm push "${package_path}" "oci://${registry}/${oci_namespace}" 2>&1)"
  printf '%s\n' "${push_output}"

  digest="$(printf '%s\n' "${push_output}" | awk '/^Digest:/ { print $2; exit }')"
  [ -n "${digest}" ] || die "Unable to determine registry digest for ${chart_name_value}:${chart_version_value}"

  oci_reference="${registry}/${oci_namespace}/${chart_name_value}@${digest}"
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
  local destination_path="$3"
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
  local asset_download_url
  local oci_repository
  local pages_repository_url
  local release_date_value
  local commit_sha_value

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
  asset_download_url="https://github.com/${GITHUB_REPOSITORY}/releases/download/${release_tag_value}/${asset_name}"
  oci_repository="$(chart_oci_repository "${chart_dir}")"
  pages_repository_url="$(chart_pages_repository_url)"
  release_date_value="$(date -u +%Y-%m-%d)"
  commit_sha_value="$(release_target_commit)"

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
    -v asset_download_url_value="${asset_download_url}" \
    -v oci_repository_value="${oci_repository}" \
    -v pages_repository_url_value="${pages_repository_url}" \
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
        gsub(/\{\{HELM_PACKAGE_DOWNLOAD_URL\}\}/, asset_download_url_value)
        gsub(/\{\{OCI_REPOSITORY\}\}/, oci_repository_value)
        gsub(/\{\{PAGES_REPOSITORY_URL\}\}/, pages_repository_url_value)

        print
      }
    ' "${template_path}" > "${destination_path}"
}

github_api_request() {
  local method="$1"
  local url="$2"
  local data_file="${3:-}"
  local content_type="${4:-application/json}"
  local response_file
  local http_status
  local -a curl_args=()

  [ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN must be set for GitHub release publishing"
  require_command curl

  response_file="$(mktemp)"

  curl_args=(
    curl
    -sS
    -X "${method}"
    -H "Accept: application/vnd.github+json"
    -H "Authorization: Bearer ${GITHUB_TOKEN}"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -o "${response_file}"
    -w "%{http_code}"
  )

  if [ -n "${content_type}" ]; then
    curl_args+=(-H "Content-Type: ${content_type}")
  fi

  if [ -n "${data_file}" ]; then
    curl_args+=(--data @"${data_file}")
  fi

  http_status="$("${curl_args[@]}" "${url}")"

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

github_release_by_tag() {
  local tag_name="$1"
  local api_url="${GITHUB_API_URL:-https://api.github.com}"
  local response_file
  local http_status

  [ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN must be set for GitHub release publishing"
  require_command curl

  response_file="$(mktemp)"
  http_status="$(
    curl \
      -sS \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
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
  local package_path="$2"
  local response_file
  local http_status
  local asset_name

  [ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN must be set for GitHub release publishing"
  require_command curl

  asset_name="$(basename "${package_path}")"
  response_file="$(mktemp)"
  http_status="$(
    curl \
      -sS \
      -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/gzip" \
      --data-binary @"${package_path}" \
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

publish_github_release() {
  local chart_dir="$1"
  local package_path="$2"
  local release_notes_path="$3"
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

  require_command git jq
  [ -f "${package_path}" ] || die "Packaged chart not found: ${package_path}"
  [ -f "${release_notes_path}" ] || die "Release notes not found: ${release_notes_path}"

  assert_release_tag_is_reusable "${chart_dir}"

  target_commit="$(release_target_commit)"
  tag_name="$(chart_release_tag "${chart_dir}")"
  release_name="$(chart_release_title "${chart_dir}")"
  release_version="$(chart_version "${chart_dir}")"
  asset_name="$(basename "${package_path}")"

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
    }' > "${payload_file}"

  if release_json="$(github_release_by_tag "${tag_name}")"; then
    release_id="$(jq -r '.id' <<<"${release_json}")"
    existing_asset_id="$(jq -r --arg asset_name "${asset_name}" '.assets[]? | select(.name == $asset_name) | .id' <<<"${release_json}" | head -n 1)"

    if [ -n "${existing_asset_id:-}" ] && [ "${existing_asset_id}" != "null" ]; then
      github_api_request DELETE "${api_url}/repos/${GITHUB_REPOSITORY}/releases/assets/${existing_asset_id}" "" ""
    fi

    release_json="$(github_api_request PATCH "${api_url}/repos/${GITHUB_REPOSITORY}/releases/${release_id}" "${payload_file}")"
  else
    release_json="$(github_api_request POST "${api_url}/repos/${GITHUB_REPOSITORY}/releases" "${payload_file}")"
  fi

  rm -f "${payload_file}"

  upload_url="$(jq -r '.upload_url' <<<"${release_json}")"
  release_url="$(jq -r '.html_url' <<<"${release_json}")"
  [ -n "${upload_url}" ] && [ "${upload_url}" != "null" ] || die "GitHub release upload URL missing for ${tag_name}"
  [ -n "${release_url}" ] && [ "${release_url}" != "null" ] || die "GitHub release URL missing for ${tag_name}"

  upload_release_asset "${upload_url%%\{*}" "${package_path}" >/dev/null
  info "Published GitHub release ${release_url} with asset ${asset_name}"
}

prepare_pages_worktree() {
  local worktree_dir="$1"
  local pages_branch="${PAGES_BRANCH:-gh-pages}"
  local has_existing_branch=false
  local previous_dir

  require_command git

  rm -rf "${worktree_dir}"
  previous_dir="$(pwd)"

  cd "${CHART_TOOL_ROOT_DIR}"
  git worktree prune >/dev/null 2>&1 || true

  if git ls-remote --exit-code --heads origin "${pages_branch}" >/dev/null 2>&1; then
    has_existing_branch=true
    git fetch --no-tags origin "${pages_branch}:${pages_branch}" >/dev/null 2>&1
    git worktree add --force -B "${pages_branch}" "${worktree_dir}" "${pages_branch}" >/dev/null
  else
    git worktree add --detach "${worktree_dir}" HEAD >/dev/null
  fi

  cd "${previous_dir}"

  if [ "${has_existing_branch}" = true ]; then
    return 0
  fi

  (
    cd "${worktree_dir}"
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
    cd "${worktree_dir}"
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
      if [ "${dry_run}" = false ]; then
        publish_oci_chart "${chart_dir}" "${package_dir}" "${registry_check_dir}"
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

    chart_name_value="$(chart_name "${chart_dir}")"
    chart_version_value="$(chart_version "${chart_dir}")"
    package_path="${package_dir}/${chart_name_value}-${chart_version_value}.tgz"
    release_notes_path="${release_notes_dir}/${chart_name_value}-${chart_version_value}.md"

    render_release_notes "${chart_dir}" "${package_path}" "${release_notes_path}"

    if [ "${dry_run}" = false ]; then
      publish_github_release "${chart_dir}" "${package_path}" "${release_notes_path}"
    fi
  done

  if [ "${dry_run}" = true ]; then
    info "Release dry run enabled; rendered GitHub release notes to ${release_notes_dir}"
  fi
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
    -h|--help|help)
      usage
      ;;
    *)
      die "Unsupported command: $1"
      ;;
  esac
}

main "$@"
