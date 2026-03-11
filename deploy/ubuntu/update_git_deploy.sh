#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash deploy/ubuntu/update_git_deploy.sh"
  exit 1
fi

APP_DIR="${APP_DIR:-/opt/omsg}"
APP_USER="${APP_USER:-omsg}"
APP_GROUP="${APP_GROUP:-omsg}"
BRANCH="${BRANCH:-}"

git_safe() {
  git -c safe.directory="${APP_DIR}" -C "${APP_DIR}" "$@"
}

resolve_branch() {
  if [[ -n "${BRANCH}" ]]; then
    printf '%s\n' "${BRANCH}"
    return 0
  fi

  local current_branch
  current_branch="$(git_safe branch --show-current)"
  if [[ -n "${current_branch}" ]]; then
    printf '%s\n' "${current_branch}"
    return 0
  fi

  printf '%s\n' "main"
}

detect_source_dir() {
  if [[ -f "${APP_DIR}/pyproject.toml" ]]; then
    printf '%s\n' "${APP_DIR}"
    return 0
  fi

  if [[ -f "${APP_DIR}/oMsg/pyproject.toml" ]]; then
    printf '%s\n' "${APP_DIR}/oMsg"
    return 0
  fi

  echo "Unable to locate pyproject.toml inside ${APP_DIR}" >&2
  return 1
}

ensure_compat_links() {
  local source_dir="$1"
  if [[ "${source_dir}" == "${APP_DIR}" ]]; then
    return 0
  fi

  local source_name
  source_name="$(basename "${source_dir}")"
  local link_name
  for link_name in app alembic deploy web pyproject.toml alembic.ini README.md; do
    ln -sfn "${source_name}/${link_name}" "${APP_DIR}/${link_name}"
  done
}

run_migrations() {
  local source_dir="$1"
  if [[ ! -x "${APP_DIR}/venv/bin/alembic" ]]; then
    return 0
  fi

  sudo -u "${APP_USER}" bash -lc "cd '${source_dir}' && '${APP_DIR}/venv/bin/alembic' upgrade head"
}

if [[ ! -d "${APP_DIR}/.git" ]]; then
  echo "${APP_DIR} is not a git repository. Run enable_git_deploy.sh first."
  exit 1
fi

BRANCH="$(resolve_branch)"
git_safe fetch origin
git_safe checkout "${BRANCH}"
git_safe pull --ff-only origin "${BRANCH}"

SOURCE_DIR="$(detect_source_dir)"
ensure_compat_links "${SOURCE_DIR}"

if [[ -x "${APP_DIR}/venv/bin/pip" ]]; then
  sudo -u "${APP_USER}" "${APP_DIR}/venv/bin/pip" install --upgrade pip
  sudo -u "${APP_USER}" "${APP_DIR}/venv/bin/pip" install -e "${SOURCE_DIR}"
fi

run_migrations "${SOURCE_DIR}"

chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"

systemctl restart omsg-api

echo
echo "Update complete."
echo "Python project root: ${SOURCE_DIR}"
echo "Current revision:"
git_safe rev-parse --short HEAD
