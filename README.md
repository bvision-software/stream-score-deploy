# StreamScore Deploy

Production deployment for StreamScore edge devices.

This setup uses **two docker-compose files**:

| File | Purpose |
|------|---------|
| `docker-compose.agent.yml` | Edge management service (edge-agent) |
| `docker-compose.stack.yml` | Application stack (scoreboard + future services) |

---
## 1. Install SSH server and connect via SSH

### 1.1 Install required packages
```bash
sudo apt update
sudo apt install -y openssh-server git
```

### 1.2 Find Device IP address
```bash
ip a
```

### 1.3 Connect from your computer
```bash
ssh USER_NAME@DEVICE_IP
```

## 2. Clone Repository
```bash
git clone https://github.com/bvision-software/stream-score-deploy.git
cd stream-score-deploy
```

## 3. System Setup
```bash
chmod +x setup.sh
bash setup.sh
```

## 4. GitHub Container Registry (GHCR) Authentication

### 4.1 Create GitHub Personal Access Token (classic)

1. Go to:

   **GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)**

2. Click **Generate new token (classic)**.

3. Give the token a descriptive name, for example:

   **GHCR_STREAM_SCORE_FIRAT**

4. Select only the following permission:

   - `read:packages` — Download packages from GitHub Package Registry

5. Click **Generate token** and copy the generated token.

---

### 4.2 Login to GitHub Container Registry

```bash
echo YOUR_GITHUB_TOKEN | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin

# Example:
# echo ghp_xxxxxxxxxxxxx | docker login ghcr.io -u arslanfirat --password-stdin
```

## 5. Run Services

### 5.1 Edge Agent
```bash
docker compose -f docker-compose.agent.yaml pull
docker compose -f docker-compose.agent.yaml up -d
```

### 5.2 Run Application Stack (Scoreboard)
```bash
docker compose -f docker-compose.stack.yaml pull
docker compose -f docker-compose.stack.yaml up -d
```