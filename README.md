# StreamScore Deploy

Production deployment for StreamScore edge devices.

This setup uses **two docker-compose files**:

| File | Purpose |
|------|---------|
| `docker-compose.agent.yml` | Edge management service (edge-agent) |
| `docker-compose.stack.yml` | Application stack (scoreboard + future services) |

---
## 1. Create GitHub Personal Access Token (classic)

1. Go to:

   **GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)**

2. Click **Generate new token (classic)**.

3. Give the token a descriptive name, for example:

   **GHCR_STREAM_SCORE_FIRAT**

4. Select only the following permission:

   - `read:packages` — Download packages from GitHub Package Registry

5. Click **Generate token** and copy the generated token.

## 2. Install SSH server and connect via SSH

### 2.1 Install required packages
```bash
sudo apt update
sudo apt install openssh-server git -y
```

### 2.2 Find Device IP address
```bash
ip a
```

### 2.3 Connect from your computer
```bash
ssh USER_NAME@DEVICE_IP
```

## 3. Clone Repository
```bash
git clone https://github.com/bvision-software/stream-score-deploy.git
cd stream-score-deploy
```

### 4. Export GitHub Container Registry (GHCR) Credentials
```bash
export GHCR_USER="your_ghcr_user_name"
export GHCR_DEPLOY_TOKEN="your_ghcr_deploy_token"
#example:
#export GHCR_USER="arslanfirat"
#export GHCR_DEPLOY_TOKEN="ghp_xxxxxxxxxxxxx"
```

## 5. System Setup
```bash
chmod +x setup.sh
./setup.sh install

# To uninstall:
./setup.sh uninstall
```