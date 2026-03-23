# Contributing to hass-n8n-claw

Thanks for your interest in contributing!

## Development Setup

1. Clone this repo
2. Copy `dev/.env.example` to `dev/.env` and fill in your values
3. Run `docker compose -f dev/docker-compose.yml up --build`
4. Access n8n at `http://localhost:5690`

## Reporting Issues

Please open a GitHub issue with:
- Your Home Assistant version
- Addon logs (Settings → Add-ons → n8n-claw → Log)
- Steps to reproduce

## Pull Requests

1. Fork the repo
2. Create a feature branch
3. Test with `docker compose -f dev/docker-compose.yml up --build`
4. Submit a PR with a clear description
