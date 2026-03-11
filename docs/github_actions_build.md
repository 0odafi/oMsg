# GitHub Actions build, publish, and deploy

This repository now includes three workflows:

- `.github/workflows/ci.yml`
- `.github/workflows/release-build.yml`
- `.github/workflows/deploy-server.yml`

## What CI does

`ci.yml` runs on push, pull request, and manual dispatch.

It performs:

1. backend dependency installation
2. backend tests with `pytest -q`
3. Flutter `pub get`
4. Flutter tests
5. a web smoke build
6. a Windows desktop build on non-PR runs

## What Release Build does

`release-build.yml` runs when:

- you push a tag like `v0.0.2+2`
- or you start the workflow manually and pass a version like `0.0.2+2`

It performs:

1. validates the version format
2. reruns backend tests
3. builds Android APK
4. builds Windows desktop release and zips it
5. creates a GitHub Release and attaches the artifacts
6. optionally uploads those artifacts to your Ubuntu server
7. optionally updates `/opt/omsg/releases/manifest.json` on the server

## What Deploy Server does

`deploy-server.yml` runs on push to `main` or `master`, and on manual dispatch.

It performs:

1. backend dependency installation
2. backend tests with `pytest -q`
3. SSH into the Ubuntu server
4. runs `/opt/omsg/deploy/ubuntu/update_git_deploy.sh`
5. installs backend updates, runs Alembic migrations, and restarts `omsg-api`

## Version format

Use this exact format:

```text
1.2.3+4
```

Tag form:

```text
v1.2.3+4
```

## Required repository configuration

For build-only release flow, nothing is required.

For production-ready release publish and server deploy, configure:

### Secrets

- `DEPLOY_SSH_KEY`
- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_PASSWORD`
- `ANDROID_KEY_ALIAS`

Android signing secrets are optional. If you do not set them, Android release builds fall back to debug signing.

### Repository variables

- `DEPLOY_HOST`
- `DEPLOY_PORT`
- `DEPLOY_USER`
- `DEPLOY_PATH`
- `DEPLOY_BRANCH`
- `DEPLOY_APP_USER`
- `DEPLOY_APP_GROUP`
- `OMSG_API_BASE_URL`
- `RELEASES_BASE_URL`

Recommended values:

```text
DEPLOY_PORT=22
DEPLOY_PATH=/opt/omsg
DEPLOY_APP_USER=omsg
DEPLOY_APP_GROUP=omsg
OMSG_API_BASE_URL=https://your-domain.example
RELEASES_BASE_URL=https://your-domain.example/files
```

## Minimal release flow

1. Commit all changes.
2. Create a tag:

```bash
git tag -a v0.0.2+2 -m "Release v0.0.2+2"
git push origin v0.0.2+2
```

3. Wait for `Release Build` to finish.
4. Download APK and Windows ZIP from the GitHub Release page.
5. If server publish variables are configured, verify:
   - `https://your-domain.example/files/omsg/android/<version>/app-release.apk`
   - `https://your-domain.example/files/omsg/windows/<version>/omsg_windows_<safe_version>.zip`
   - `https://your-domain.example/api/releases/latest/android`
   - `https://your-domain.example/api/releases/latest/windows`

## Notes

- `deploy-server.yml` assumes the server is already prepared with `deploy/ubuntu/setup_server.sh` and git deploy is enabled.
- `release-build.yml` assumes the server already contains the repository checkout at `DEPLOY_PATH`, because manifest updates use `scripts/update_manifest.py` from that checkout.
- If the workspace was copied without `.git`, GitHub Actions will still work after the repository is pushed to GitHub, but first push and remote setup must be done in a real git checkout.
