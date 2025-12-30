# StreamScore Deploy
Production Docker Compose file for StreamScore.

```bash
echo <YOUR_READ_ONLY_TOKEN> | docker login ghcr.io -u <YOUR_GITHUB_USERNAME> --password-stdin
#e.g: echo ghp_
#NlxkHp6VHY44fVSM1
#CmRw0ERaGcGHq0atlF4 | docker login ghcr.io -u arslanfirat --password-stdin
```

```bash
docker compose --profile prod -f docker-compose.yaml pull
docker compose --profile prod -f docker-compose.yaml up -d
```