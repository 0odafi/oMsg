# Ubuntu 24.04 Deployment (oMsg)

## 1. What you need on server

- Ubuntu 24.04 LTS
- Public DNS/domain pointing to server
- Open ports `22`, `80`, `443`
- User with sudo privileges
- GitHub repository with Actions enabled

## 2. Initial setup

Copy repository to server and run:

```bash
sudo bash deploy/ubuntu/setup_server.sh
```

## 2.1 Switch existing server to git deploy

If `/opt/omsg` already exists and was uploaded by SFTP, convert it in place:

```bash
cd /opt/omsg
sudo bash deploy/ubuntu/enable_git_deploy.sh
```

Default source repository:

```text
https://github.com/0odafi/oMsg.git
```

Optional overrides:

```bash
sudo REPO_URL=https://github.com/0odafi/oMsg.git BRANCH=main \
  bash /opt/omsg/deploy/ubuntu/enable_git_deploy.sh
```

If the git repository contains the project inside a nested folder such as
`/opt/omsg/oMsg`, the script detects it automatically and creates
compatibility symlinks (`app`, `deploy`, `alembic`, `web`) in `/opt/omsg`.
That keeps old service paths working.

What the script does:

- creates a fresh git clone
- keeps runtime directories: `venv/`, `media/`, `releases/`
- keeps local sqlite file `omsg.db` if it exists
- creates a backup directory like `/opt/omsg.backup-20260309153000`
- reinstalls backend dependencies into `/opt/omsg/venv`
- runs `alembic upgrade head`

After that, regular updates become:

```bash
sudo bash /opt/omsg/deploy/ubuntu/update_git_deploy.sh
```

If the very first conversion stopped after cloning but before `pip install`,
recover with:

```bash
cd /opt/omsg
git config --global --add safe.directory /opt/omsg
git -c safe.directory=/opt/omsg pull --ff-only origin main
chmod +x oMsg/deploy/ubuntu/update_git_deploy.sh
sudo APP_DIR=/opt/omsg bash /opt/omsg/oMsg/deploy/ubuntu/update_git_deploy.sh
```

## 3. Configure backend service

```bash
sudo cp deploy/ubuntu/api.env.example /etc/omsg/api.env
sudo nano /etc/omsg/api.env
```

Recommended production values in `/etc/omsg/api.env`:

```env
ENVIRONMENT=production
DATABASE_AUTO_MIGRATE=false
```

Copy service file:

```bash
sudo cp deploy/ubuntu/omsg-api.service /etc/systemd/system/omsg-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now omsg-api
sudo systemctl status omsg-api
```

Install backend dependencies into server venv:

```bash
sudo -u omsg /opt/omsg/venv/bin/pip install --upgrade pip
sudo -u omsg /opt/omsg/venv/bin/pip install -e /opt/omsg
sudo -u omsg bash -lc "cd /opt/omsg && /opt/omsg/venv/bin/alembic upgrade head"
sudo systemctl restart omsg-api
```

After git deploy is enabled, use this instead for updates:

```bash
sudo bash /opt/omsg/deploy/ubuntu/update_git_deploy.sh
```

## 4. Configure nginx

```bash
sudo cp deploy/ubuntu/nginx.omsg.conf /etc/nginx/sites-available/omsg
sudo ln -sf /etc/nginx/sites-available/omsg /etc/nginx/sites-enabled/omsg
sudo nginx -t
sudo systemctl reload nginx
```

Enable HTTPS:

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d volds.ru
```

## 5. Releases path

The auto-publish pipeline uploads files into:

- `/opt/omsg/releases/omsg/windows/<version>/...`
- `/opt/omsg/releases/omsg/android/<version>/...`
- `/opt/omsg/releases/manifest.json`

Public URL base in this nginx config is:

- `https://volds.ru/files`

## 6. SSH for GitHub Actions

Generate key pair on your PC:

```powershell
ssh-keygen -t ed25519 -C "omsg-release" -f $env:USERPROFILE\.ssh\omsg_release
```

Add public key to server user (`deploy` or your sudo user):

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cat omsg_release.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Set GitHub secret `DEPLOY_SSH_KEY` from `deploy/github-secrets.md`.

Also set repository variables:

- `DEPLOY_HOST`
- `DEPLOY_PORT`
- `DEPLOY_USER`
- `DEPLOY_PATH`
- `DEPLOY_BRANCH`
- `DEPLOY_APP_USER`
- `DEPLOY_APP_GROUP`
- `OMSG_API_BASE_URL`
- `RELEASES_BASE_URL`

After that:

- `.github/workflows/deploy-server.yml` can deploy backend updates on push to `main` or `master`
- `.github/workflows/release-build.yml` can upload Windows and Android releases into `/opt/omsg/releases/...` and refresh `manifest.json`
