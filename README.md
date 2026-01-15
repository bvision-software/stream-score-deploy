# StreamScore Deploy

Production deployment for StreamScore edge devices.

This setup uses **two docker-compose files**:

| File | Purpose |
|------|---------|
| `docker-compose.agent.yml` | Edge management service (edge-agent) |
| `docker-compose.stack.yml` | Application stack (scoreboard + future services) |

---

## 1. Clone Repository
```bash
sudo apt update
sudo apt install git -y
git clone https://github.com/bvision-software/stream-score-deploy.git
```

## 2. System Setup
```bash
chmod +x setup.sh
bash setup.sh
```

## 3. GitHub Container Registry (GHCR) Authentication

### 3.1 Create GitHub Personal Access Token (classic)

1. Go to:

   **GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)**

2. Click **Generate new token (classic)**.

3. Give the token a descriptive name, for example:

   **GHCR_STREAM_SCORE_FIRAT**

4. Select only the following permission:

   - `read:packages` — Download packages from GitHub Package Registry

5. Click **Generate token** and copy the generated token.

---

### 3.2 Login to GitHub Container Registry

```bash
echo YOUR_GITHUB_TOKEN | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin

# Example:
# echo ghp_xxxxxxxxxxxxx | docker login ghcr.io -u arslanfirat --password-stdin
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