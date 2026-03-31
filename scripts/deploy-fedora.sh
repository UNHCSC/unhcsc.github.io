#!/usr/bin/env bash

# https://raw.githubusercontent.com/UNHCSC/unhcsc.github.io/main/scripts/deploy-fedora.sh
# Installs, updates, or removes the built site files for the UNHCSC website.

set -euo pipefail

APP_NAME="unhcsc-site"
GITHUB_REPOSITORY="UNHCSC/unhcsc.github.io"
GITHUB_API_BASE="https://api.github.com/repos/${GITHUB_REPOSITORY}"
DEFAULT_INSTALL_DIR="/var/www/unhcsc-site"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/${APP_NAME}"
STATE_FILE="${STATE_DIR}/deploy.env"
MANIFEST_FILE="${STATE_DIR}/manifest.txt"
MARKER_FILE=".${APP_NAME}-managed"

ACTION=""
REQUESTED_TAG=""
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
CURRENT_RELEASE_TAG=""
NON_INTERACTIVE=0

TEMP_DIR=""

cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: deploy-fedora.sh [action] [options]

Actions:
  -h, --help              Show this help message and exit
  -r, --releases          List available GitHub releases
  -i, --install [tag]     Install a release tag, or the latest release if omitted
  -u, --update            Update the deployed site to the latest release
  -p, --purge             Remove previously installed site files

Options:
  --tag <tag>             Release tag to install
  --install-dir <path>    Directory where the built site should be installed
  -y, --yes               Non-interactive mode; use saved/default values
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

info() {
    echo "==> $*" >&2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

prompt_value() {
    local prompt_message="$1"
    local default_value="$2"
    local answer=""

    if (( NON_INTERACTIVE )); then
        echo "${default_value}"
        return
    fi

    while true; do
        read -r -p "${prompt_message} [${default_value}]: " answer
        answer="${answer:-${default_value}}"
        if [[ -n "${answer}" ]]; then
            echo "${answer}"
            return
        fi
    done
}

ensure_state_dir() {
    mkdir -p "${STATE_DIR}"
}

load_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
    fi

    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    CURRENT_RELEASE_TAG="${CURRENT_RELEASE_TAG:-}"
}

save_state() {
    ensure_state_dir
    cat > "${STATE_FILE}" <<EOF
INSTALL_DIR=${INSTALL_DIR}
CURRENT_RELEASE_TAG=${CURRENT_RELEASE_TAG}
EOF
}

validate_install_dir() {
    [[ "${INSTALL_DIR}" = /* ]] || die "Install directory must be an absolute path."
}

ensure_install_dir() {
    local parent_dir=""

    validate_install_dir

    if [[ -d "${INSTALL_DIR}" ]]; then
        [[ -w "${INSTALL_DIR}" ]] || die "Install directory '${INSTALL_DIR}' is not writable."
        return
    fi

    parent_dir="$(dirname "${INSTALL_DIR}")"
    [[ -d "${parent_dir}" ]] || mkdir -p "${parent_dir}"
    [[ -w "${parent_dir}" ]] || die "Cannot create '${INSTALL_DIR}' because '${parent_dir}' is not writable."
    mkdir -p "${INSTALL_DIR}"
}

ensure_release_tools() {
    command_exists curl || die "curl is required."
    command_exists jq || die "jq is required."
    command_exists tar || die "tar is required."
}

github_api_get() {
    local url="$1"
    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${url}"
}

list_releases() {
    ensure_release_tools
    github_api_get "${GITHUB_API_BASE}/releases" \
        | jq -r '.[] | "\(.tag_name) \(.published_at)"' \
        | nl -w2 -s'. '
}

get_release_json() {
    if [[ -n "${REQUESTED_TAG}" ]]; then
        github_api_get "${GITHUB_API_BASE}/releases/tags/${REQUESTED_TAG}"
    else
        github_api_get "${GITHUB_API_BASE}/releases/latest"
    fi
}

download_file() {
    local url="$1"
    local destination="$2"
    curl -fL "${url}" -o "${destination}"
}

extract_archive() {
    local archive_path="$1"
    local destination="$2"

    mkdir -p "${destination}"

    case "${archive_path}" in
        *.tar.gz|*.tgz) tar -xzf "${archive_path}" -C "${destination}" ;;
        *.tar) tar -xf "${archive_path}" -C "${destination}" ;;
        *.zip)
            command_exists unzip || die "unzip is required to extract '${archive_path}'."
            unzip -q "${archive_path}" -d "${destination}"
            ;;
        *)
            die "Unsupported archive format '${archive_path}'."
            ;;
    esac
}

find_single_child_dir() {
    local directory="$1"
    local count=""
    local child=""

    count="$(find "${directory}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    if [[ "${count}" == "1" ]]; then
        child="$(find "${directory}" -mindepth 1 -maxdepth 1 -type d | head -n1)"
        echo "${child}"
    fi
}

find_source_root() {
    local directory="$1"
    local nested=""
    local match=""

    if [[ -f "${directory}/Gemfile" ]]; then
        echo "${directory}"
        return
    fi

    nested="$(find_single_child_dir "${directory}")"
    if [[ -n "${nested}" && -f "${nested}/Gemfile" ]]; then
        echo "${nested}"
        return
    fi

    match="$(find "${directory}" -maxdepth 3 -type f -name Gemfile | head -n1 || true)"
    [[ -n "${match}" ]] || die "Could not find a Jekyll source tree in the release archive."
    dirname "${match}"
}

find_site_root() {
    local directory="$1"
    local nested=""
    local match=""

    if [[ -f "${directory}/index.html" ]]; then
        echo "${directory}"
        return
    fi

    if [[ -f "${directory}/_site/index.html" ]]; then
        echo "${directory}/_site"
        return
    fi

    nested="$(find_single_child_dir "${directory}")"
    if [[ -n "${nested}" && -f "${nested}/index.html" ]]; then
        echo "${nested}"
        return
    fi

    match="$(find "${directory}" -maxdepth 3 -type f -name index.html | head -n1 || true)"
    [[ -n "${match}" ]] || die "Could not find a built website in the release archive."
    dirname "${match}"
}

build_site_from_source() {
    local source_root="$1"

    command_exists bundle || die "Bundler is required to build from source. On Fedora install ruby, rubygem-bundler, gcc, gcc-c++, make, patch, zlib-devel, openssl-devel, and libffi-devel."

    info "Building Jekyll site from source"
    pushd "${source_root}" >/dev/null
    bundle config set --local path vendor/bundle
    bundle install
    bundle exec jekyll build
    popd >/dev/null

    echo "${source_root}/_site"
}

download_release_payload() {
    local release_json="$1"
    local tag_name=""
    local asset_name=""
    local asset_url=""
    local archive_path=""
    local archive_kind=""

    tag_name="$(jq -r '.tag_name' <<<"${release_json}")"
    [[ -n "${tag_name}" && "${tag_name}" != "null" ]] || die "Release metadata did not include a tag name."

    asset_name="$(jq -r '
        [
          .assets[]
          | select(.name | test("(site|website|pages|html|dist|artifact|_site).*(tar\\.gz|tgz|zip)$"; "i"))
        ][0].name // empty
    ' <<<"${release_json}")"
    asset_url="$(jq -r '
        [
          .assets[]
          | select(.name | test("(site|website|pages|html|dist|artifact|_site).*(tar\\.gz|tgz|zip)$"; "i"))
        ][0].browser_download_url // empty
    ' <<<"${release_json}")"

    if [[ -n "${asset_url}" ]]; then
        archive_path="${TEMP_DIR}/${asset_name}"
        archive_kind="built"
        info "Downloading built release asset '${asset_name}'"
        download_file "${asset_url}" "${archive_path}"
    else
        archive_path="${TEMP_DIR}/${tag_name}.tar.gz"
        archive_kind="source"
        info "No built site asset found; downloading release source tarball"
        download_file "$(jq -r '.tarball_url' <<<"${release_json}")" "${archive_path}"
    fi

    printf '%s\n%s\n%s\n' "${tag_name}" "${archive_kind}" "${archive_path}"
}

write_manifest() {
    local site_source="$1"

    ensure_state_dir
    (
        cd "${site_source}"
        find . -mindepth 1 ! -path "./${MARKER_FILE}" -printf '%P\n' | sort
    ) > "${MANIFEST_FILE}"
}

mark_install_dir() {
    cat > "${INSTALL_DIR}/${MARKER_FILE}" <<EOF
managed_by=${APP_NAME}
release=${CURRENT_RELEASE_TAG}
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

sync_site_tree() {
    local site_source="$1"
    local release_tag="$2"

    ensure_install_dir
    info "Syncing release '${release_tag}' into ${INSTALL_DIR}"
    rsync -a --delete "${site_source}/" "${INSTALL_DIR}/"
    CURRENT_RELEASE_TAG="${release_tag}"
    write_manifest "${site_source}"
    mark_install_dir
}

prompt_for_install_dir() {
    INSTALL_DIR="$(prompt_value "Install directory for the built site" "${INSTALL_DIR}")"
}

install_or_update_site() {
    local release_json=""
    local payload_tag=""
    local payload_kind=""
    local archive_path=""
    local extract_dir=""
    local source_root=""
    local site_root=""
    local payload_data=""

    ensure_release_tools
    command_exists rsync || die "rsync is required."
    prompt_for_install_dir
    ensure_install_dir

    TEMP_DIR="$(mktemp -d)"
    release_json="$(get_release_json)"
    payload_data="$(download_release_payload "${release_json}")"
    payload_tag="$(sed -n '1p' <<<"${payload_data}")"
    payload_kind="$(sed -n '2p' <<<"${payload_data}")"
    archive_path="$(sed -n '3p' <<<"${payload_data}")"

    extract_dir="${TEMP_DIR}/extract"
    extract_archive "${archive_path}" "${extract_dir}"

    if [[ "${payload_kind}" == "built" ]]; then
        site_root="$(find_site_root "${extract_dir}")"
    else
        source_root="$(find_source_root "${extract_dir}")"
        site_root="$(build_site_from_source "${source_root}")"
    fi

    sync_site_tree "${site_root}" "${payload_tag}"
    save_state

    info "Deployment completed for ${payload_tag}"
    info "Installed site path: ${INSTALL_DIR}"
}

purge_site() {
    local rel_path=""
    local abs_path=""

    [[ -f "${STATE_FILE}" ]] || die "No saved deployment state found."
    [[ -d "${INSTALL_DIR}" ]] || die "Install directory '${INSTALL_DIR}' does not exist."
    [[ -f "${INSTALL_DIR}/${MARKER_FILE}" ]] || die "Install directory '${INSTALL_DIR}' is not marked as managed by this script."
    [[ -f "${MANIFEST_FILE}" ]] || die "Manifest file '${MANIFEST_FILE}' is missing."
    [[ -w "${INSTALL_DIR}" ]] || die "Install directory '${INSTALL_DIR}' is not writable."

    info "Removing installed site files from ${INSTALL_DIR}"
    while IFS= read -r rel_path; do
        [[ -n "${rel_path}" ]] || continue
        abs_path="${INSTALL_DIR}/${rel_path}"
        if [[ -e "${abs_path}" || -L "${abs_path}" ]]; then
            rm -rf "${abs_path}"
        fi
    done < "${MANIFEST_FILE}"

    rm -f "${INSTALL_DIR:?}/${MARKER_FILE}"
    find "${INSTALL_DIR}" -depth -type d -empty -delete
    rm -f "${MANIFEST_FILE}" "${STATE_FILE}"
    rmdir "${STATE_DIR}" >/dev/null 2>&1 || true

    info "Purge completed"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -r|--releases)
                ACTION="releases"
                shift
                ;;
            -i|--install)
                ACTION="install"
                if [[ $# -gt 1 && "${2}" != -* ]]; then
                    REQUESTED_TAG="$2"
                    shift
                fi
                shift
                ;;
            -u|--update)
                ACTION="update"
                shift
                ;;
            -p|--purge)
                ACTION="purge"
                shift
                ;;
            --tag)
                [[ $# -gt 1 ]] || die "--tag requires a value."
                REQUESTED_TAG="$2"
                shift 2
                ;;
            --install-dir)
                [[ $# -gt 1 ]] || die "--install-dir requires a value."
                INSTALL_DIR="$2"
                shift 2
                ;;
            -y|--yes)
                NON_INTERACTIVE=1
                shift
                ;;
            *)
                die "Unknown option '$1'."
                ;;
        esac
    done
}

main() {
    load_state
    parse_args "$@"

    case "${ACTION}" in
        releases)
            list_releases
            ;;
        install|update)
            install_or_update_site
            ;;
        purge)
            purge_site
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
