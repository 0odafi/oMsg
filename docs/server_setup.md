# oMsg server setup

## Recommended target

- Ubuntu 24.04 LTS
- Nginx in front of the API
- PostgreSQL for main data
- Redis for realtime fanout and presence
- systemd for the backend process
- a public domain with HTTPS

## Recommended production path

1. Copy or clone the repository to `/opt/omsg`.
2. Run base server setup:

```bash
sudo bash /opt/omsg/deploy/ubuntu/setup_server.sh
```

3. If the server folder was uploaded manually and is not a git checkout yet, convert it:

```bash
cd /opt/omsg
sudo bash deploy/ubuntu/enable_git_deploy.sh
```

4. Copy backend environment file and set production values:

```bash
sudo mkdir -p /etc/omsg
sudo cp /opt/omsg/deploy/ubuntu/api.env.example /etc/omsg/api.env
sudo nano /etc/omsg/api.env
```

Recommended additions in `/etc/omsg/api.env`:

```env
ENVIRONMENT=production
DATABASE_AUTO_MIGRATE=false
```

5. Install and start the systemd service:

```bash
sudo cp /opt/omsg/deploy/ubuntu/omsg-api.service /etc/systemd/system/omsg-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now omsg-api
sudo systemctl status omsg-api
```

6. Configure nginx with `deploy/ubuntu/nginx.omsg.conf` and enable TLS with certbot.

## Why this path is preferred

- `update_git_deploy.sh` now installs dependencies, runs `alembic upgrade head`, and restarts the service
- `.github/workflows/deploy-server.yml` can call that same script over SSH
- release artifacts can be uploaded by `.github/workflows/release-build.yml` into `/opt/omsg/releases`

## Alternative path: Docker Compose

1. Copy `.env.example` to `.env` and change at minimum:
   - `SECRET_KEY`
   - `DATABASE_URL`
   - `REDIS_URL`
   - SMS provider settings
2. Start the stack:

```bash
docker compose -f docker-compose.server.yml up -d --build
```

3. Run database migrations inside the API container:

```bash
docker compose -f docker-compose.server.yml exec api alembic upgrade head
```

4. Put nginx or Caddy in front of `127.0.0.1:8000`.

## Required backend variables

At minimum set these in production:

```env
ENVIRONMENT=production
SECRET_KEY=replace-with-long-random-secret
DATABASE_URL=postgresql+psycopg://omsg:strong-password@127.0.0.1:5432/omsg
DATABASE_AUTO_MIGRATE=false
REDIS_URL=redis://127.0.0.1:6379/0
CORS_ORIGINS=https://your-domain.example
MEDIA_ROOT=/opt/omsg/media
RELEASE_MANIFEST_PATH=/opt/omsg/releases/manifest.json
```

## GitHub Actions integration

Set repository variables and secrets from `deploy/github-secrets.md`, then:

- pushes to `main` or `master` can deploy backend updates to Ubuntu automatically
- release tags like `v1.2.3+4` can publish Windows and Android artifacts to GitHub Releases
- the same release workflow can upload those artifacts to the server and refresh `releases/manifest.json`

## Flutter client configuration

Point the client at the server during build or run:

```bash
flutter run --dart-define=OMSG_API_BASE_URL=https://your-domain.example
flutter build apk --release --dart-define=OMSG_API_BASE_URL=https://your-domain.example
flutter build windows --release --dart-define=OMSG_API_BASE_URL=https://your-domain.example
```

## First production checklist

- switch SQLite to PostgreSQL
- enable Redis
- set a real `SECRET_KEY`
- restrict `CORS_ORIGINS`
- configure a real SMS provider
- back up PostgreSQL, `media/`, and `releases/`
- keep `/api/releases/latest/{platform}` files on persistent storage
