# StreamScore Deploy
Production Docker Compose file for StreamScore.

1. **Create a GitHub Personal Access Token (classic)**
   - Go to [GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)](https://github.com/settings/tokens)
   - Click **Generate new token (classic)**
   - Give it a name, e.g.: `GHCR_STREAM_SCORE_FIRAT`
   - Select **only** the **Read packages** permission:
     > `read:packages` – Download packages from GitHub Package Registry
   - Click **Generate token** and **copy it** (you can see it only once)

2. **Login to GitHub Container Registry**
```bash
echo YOUR_GITHUB_TOKEN | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
#e.g: echo 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 | docker login ghcr.io -u arslanfirat --password-stdin
```
3. **Pull & Build and Run service**
```bash
docker compose --profile prod -f docker-compose.yaml pull
docker compose --profile prod -f docker-compose.yaml up -d
```