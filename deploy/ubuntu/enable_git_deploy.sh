#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash deploy/ubuntu/enable_git_deploy.sh"
  exit 1
fi

APP_DIR="${APP_DIR:-/opt/omsg}"
APP_USER="${APP_USER:-omsg}"
APP_GROUP="${APP_GROUP:-omsg}"
BRANCH="${BRANCH:-}"
REPO_URL="${REPO_URL:-https://github.com/0odafi/oMsg.git}"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="${APP_DIR}.backup-${TIMESTAMP}"
TMP_DIR="${APP_DIR}.clone-${TIMESTAMP}"

resolve_branch() {
  if [[ -n "${BRANCH}" ]]; then
    printf '%s\n' "${BRANCH}"
    return 0
  fi

  local detected_branch
  detected_branch="$(
    git ls-remote --symref "${REPO_URL}" HEAD 2>/dev/null \
      | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}'
  )"

  if [[ -n "${detected_branch}" ]]; then
    printf '%s\n' "${detected_branch}"
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

if [[ ! -d "${APP_DIR}" ]]; then
  echo "Directory ${APP_DIR} does not exist."
  exit 1
fi

if [[ -d "${APP_DIR}/.git" ]]; then
  echo "${APP_DIR} is already a git repository."
  exit 0
fi

echo "Converting ${APP_DIR} to git deploy checkout"
BRANCH="$(resolve_branch)"
echo "Repository: ${REPO_URL}"
echo "Branch: ${BRANCH}"

git clone --branch "${BRANCH}" --depth 1 "${REPO_URL}" "${TMP_DIR}"

mv "${APP_DIR}" "${BACKUP_DIR}"
mv "${TMP_DIR}" "${APP_DIR}"

for dir_name in venv media releases; do
  if [[ -d "${BACKUP_DIR}/${dir_name}" ]]; then
    rm -rf "${APP_DIR:?}/${dir_name}"
    mv "${BACKUP_DIR}/${dir_name}" "${APP_DIR}/${dir_name}"
  fi
done

for file_name in omsg.db; do
  if [[ -f "${BACKUP_DIR}/${file_name}" ]]; then
    mv "${BACKUP_DIR}/${file_name}" "${APP_DIR}/${file_name}"
  fi
done

SOURCE_DIR="$(detect_source_dir)"
ensure_compat_links "${SOURCE_DIR}"

chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"

if [[ -x "${APP_DIR}/venv/bin/pip" ]]; then
  sudo -u "${APP_USER}" "${APP_DIR}/venv/bin/pip" install --upgrade pip
  sudo -u "${APP_USER}" "${APP_DIR}/venv/bin/pip" install -e "${SOURCE_DIR}"
fi

run_migrations "${SOURCE_DIR}"

echo
echo "Git deploy is enabled."
echo "Backup of previous directory: ${BACKUP_DIR}"
echo "Current checkout: ${APP_DIR}"
echo "Python project root: ${SOURCE_DIR}"
echo
echo "Next commands:"
echo "  systemctl restart omsg-api"
echo "  systemctl status omsg-api --no-pager -l"
