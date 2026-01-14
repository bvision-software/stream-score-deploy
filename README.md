# StreamScore Deploy

Production deployment for StreamScore edge devices.

This setup uses **two docker-compose files**:

| File | Purpose |
|------|---------|
| `docker-compose.agent.yml` | Edge management service (edge-agent) |
| `docker-compose.stack.yml` | Application stack (scoreboard + future services) |

---

## 1. Create GitHub Personal Access Token (classic)

1. Go to
   GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)

2. Click **Generate new token (classic)**

3. Give it a name, e.g.:

   GHCR_STREAM_SCORE_FIRAT

4. Select only:

   read:packages – Download packages from GitHub Package Registry

5. Click **Generate token** and copy it.

---

## 2. Login to GitHub Container Registry

```bash
echo YOUR_GITHUB_TOKEN | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
# example:
# echo ghp_xxxxxxxxxxxxx | docker login ghcr.io -u arslanfirat --password-stdin
```

## 3. System Setup (Run Once)
```bash
chmod +x setup.sh
sudo -E ./setup.sh
```

## 4. Run Edge Agent
```bash
docker compose -f docker-compose.agent.yaml pull
docker compose -f docker-compose.agent.yaml up -d
```

## 5. Run Application Stack (Scoreboard)
```bash
docker compose -f docker-compose.stack.yaml pull
docker compose -f docker-compose.stack.yaml up -d
```