# GitHub repository secrets and variables

## Required for server deploy

### Secret

- `DEPLOY_SSH_KEY` - private SSH key used by GitHub Actions to connect to your Ubuntu server

Important:

- do not paste a fingerprint (`SHA256:...`) or a `.pub` key
- the secret must contain the private key (`-----BEGIN ... PRIVATE KEY-----` ... `-----END ... PRIVATE KEY-----`)
- the key should be without passphrase for CI
- raw multiline private key and base64-encoded private key are both supported by current workflows

PowerShell (create base64 from key file):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\\.ssh\\omsg_deploy_nopass"))
```

### Repository variables

- `DEPLOY_HOST` - server IP or DNS name
- `DEPLOY_PORT` - SSH port, usually `22`
- `DEPLOY_USER` - SSH user that can run `sudo`
- `DEPLOY_PATH` - project path on server, usually `/opt/omsg`
- `DEPLOY_BRANCH` - optional server branch override, usually `main` or `master`
- `DEPLOY_APP_USER` - backend service user, usually `omsg`
- `DEPLOY_APP_GROUP` - backend service group, usually `omsg`

## Required for release publish to server

- `RELEASES_BASE_URL` - repository variable with public files base URL, for example `https://your-domain.example/files`

`release-build.yml` uploads Windows and Android assets to:

- `${DEPLOY_PATH}/releases/omsg/windows/<version>/...`
- `${DEPLOY_PATH}/releases/omsg/android/<version>/...`

Then it refreshes:

- `${DEPLOY_PATH}/releases/manifest.json`

## Recommended for production client builds

- `OMSG_API_BASE_URL` - repository variable with production API base URL, for example `https://your-domain.example`

Both Android and Windows release builds now inject that value through `--dart-define`.

## Optional Android signing secrets

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_PASSWORD`
- `ANDROID_KEY_ALIAS`

If these are missing, Android release builds still work, but they are signed with the debug key and are not suitable as a proper production publish path.
