# CodeSever-Windows

One-click code-server stack for Windows with JWT auth + Cloudflare Tunnel.

## Highlights

- Run code-server on localhost
- Protect access with JWT login
- Auto create public URL with cloudflared Quick Tunnel
- Auto send tunnel URL to Discord webhook
- Persistent data (workspace/settings/extensions) after restart
- Offline-first package: dependencies are bundled in this repo
- `offline/` contains prepacked runtime binaries for one-click start

## Quick Start

1. Download this repository
2. Open `.env.example`, copy to `.env`
3. Edit values in `.env`
4. Double-click `start.bat`

Done. System will boot local server + tunnel.

If `bin/` is missing, `scripts/start.ps1` will auto-extract the bundled files from `offline/`.

## Default `.env.example`

```env
CODE_SERVER_PASSWORD=nguyenmanhhieu
JWT_SECRET=nguyenmanhhieu
TOKEN_TTL=12h
CODE_SERVER_PORT=8080
PROXY_PORT=8443
WORKSPACE_DIR=storage/code-server/workspaces
NODE_VERSION=20.19.0
FORCE_LOCAL_NODE=false
DISCORD_WEBHOOK_URL=your_webhook_discord_link
```

## How It Works

- `start.bat` runs `scripts/start.ps1`
- Script starts:
  - `code-server` (local only)
  - JWT reverse proxy
  - `cloudflared` tunnel
- Tunnel URL is parsed and sent to Discord webhook

## Persistent Storage

Data is stored in:

- `storage/code-server/user-data`
- `storage/code-server/extensions`
- `storage/code-server/workspaces`

So data stays after crash/restart.

## Stop

- Press `Ctrl + C` in start terminal
- Or run `stop.bat`

## Troubleshooting

- Port in use (`8080` or `8443`): run `stop.bat`, then start again
- Tunnel failed: check `logs/cloudflared*.log`
- Cannot access UI: check `logs/proxy*.log` and `logs/code-server*.log`

## Security Notes

- Never commit real `.env`
- Change password/secret before production use
- Quick Tunnel URL changes every run

## License

MIT License - Copyright (c) 2026 Nguyễn Mạnh Hiếu
