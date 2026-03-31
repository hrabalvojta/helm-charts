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

  mkdir -p "${package_dir}" "${registry_check_dir}"
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
