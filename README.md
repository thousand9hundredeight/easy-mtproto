# easy-mtproto 🌐

Automatic installation of **MTProto Fake TLS** with Docker and **nginx stream** on Debian 12 / Ubuntu 22.04+.

The script is idempotent: you can run it again safely. It removes only its own MTProto containers and nginx files, then recreates everything from scratch.

## Architecture

```text
Internet
  |
  \-- :443 (or custom PUBLIC_PORT) -> nginx (ssl_preread, no TLS decryption)
                                     |-- SNI = ya.ru         -> MTProto Desktop  127.0.0.1:7788
                                     |-- SNI = www.ozon.ru   -> MTProto Mobile   127.0.0.1:7789
                                     \-- default            -> Fallback HTML    127.0.0.1:8080
```

nginx reads the beginning of the TCP stream with `ssl_preread` and routes traffic by SNI without terminating TLS.

## What gets installed

| Service | Container / Process | Internal port | Public port | Purpose |
|---|---|---:|---:|---|
| MTProto Desktop | `mtproto-desktop` | `7788` | `443` by default | Telegram Desktop proxy |
| MTProto Mobile | `mtproto-mobile` | `7789` | `443` by default | Telegram Mobile proxy |
| Fallback HTML | `nginx` | `8080` | — | Default non-MTProto fallback |
| Stream router | `nginx` | — | `443` by default | SNI-based TCP routing |

## Requirements

- Debian 12 or Ubuntu 22.04+
- Root access
- A server with a public IPv4 address
- Port `443/tcp` available, or another public port if you change `PUBLIC_PORT`
- Docker and nginx can be installed on the server

## Usage

Run the installer as root:

```bash
bash install-mtproto.sh
```

After installation, credentials are saved to:

```bash
/root/mtproto-credentials.txt
```

Permissions for that file are set to `600`.

## Editable settings

At the top of `install-mtproto.sh` there is a `SETTINGS` block.

```bash
MTPROTO_SNI_DESKTOP="ya.ru"
MTPROTO_SNI_MOBILE="www.ozon.ru"

MTPROTO_PORT_DESKTOP=7788
MTPROTO_PORT_MOBILE=7789

PUBLIC_PORT=443
FALLBACK_PORT=8080
CREDS_FILE="/root/mtproto-credentials.txt"
```

### What you may want to change

- `MTPROTO_SNI_DESKTOP` / `MTPROTO_SNI_MOBILE` — Fake TLS SNI domains. These should be real HTTPS domains reachable from your server.
- `MTPROTO_PORT_DESKTOP` / `MTPROTO_PORT_MOBILE` — internal localhost ports for the two MTProto containers.
- `PUBLIC_PORT` — the public nginx port. Change this if `443` is already used by another service.
- `FALLBACK_PORT` — internal port for the fallback nginx page.
- `CREDS_FILE` — where generated proxy links and secrets are saved.

## Important compatibility notes

This script is designed to avoid breaking unrelated services, but you still need to check your server layout before running it.

### nginx

The script creates only these nginx files:

```text
/etc/nginx/stream.d/mtproto.conf
/etc/nginx/sites-available/mtproto-fallback
/etc/nginx/sites-enabled/mtproto-fallback
```

It does **not** remove your other nginx sites or stream configs.

### Port conflicts

If another service already listens on `443`, nginx will not be able to bind that port.
In that case, change:

```bash
PUBLIC_PORT=8443
```

### Firewall

The script opens only:

- `ssh`
- `${PUBLIC_PORT}/tcp`

If you already run other services on the same server, add their firewall rules before enabling UFW inside the script.
Examples:

```bash
ufw allow 2443/tcp    # VLESS Reality
ufw allow 51820/udp   # WireGuard
ufw allow 3000/tcp    # Another service
```

## Installation steps

The script does the following:

1. Stops and removes old `mtproto-desktop` and `mtproto-mobile` containers.
2. Removes only its own nginx files.
3. Installs `curl`, `wget`, `nginx`, `ufw`, `tmux`, and Docker if needed.
4. Generates MTProto secrets for desktop and mobile profiles.
5. Starts two `mtg` containers bound to localhost.
6. Creates a fallback HTML page.
7. Writes nginx stream config with SNI-based routing.
8. Tests and reloads nginx.
9. Enables firewall rules.
10. Saves Telegram proxy links to `/root/mtproto-credentials.txt`.

## Credentials output

The script prints and saves two Telegram links:

- MTProto Desktop link
- MTProto Mobile link

They look like this:

```text
tg://proxy?server=SERVER_IP&port=443&secret=...
```

## Repository structure

```text
mtproto-setup/
├── install-mtproto.sh   — main installation script
├── README.md            — documentation
└── .gitignore           — excludes sensitive generated files
```

## Security note

`/root/mtproto-credentials.txt` contains active proxy secrets.
Do not commit it to git, do not publish it, and do not send it to public chats.
