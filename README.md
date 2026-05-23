# proxmox-coder-lxc

Install [Coder](https://coder.com/) — a self-hosted remote development platform — on Proxmox VE via an LXC container.

## What it does

- **Run on the Proxmox host shell** → automatically creates a Debian 12 LXC container, then installs Coder inside it
- **Run inside an existing LXC container** → installs Coder directly
- **Existing container detected** → prompts to update it or create a new one

## Quick start

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/N0t4R0b0t/proxmox-coder-lxc/main/coder.sh)
```

Run this on your **Proxmox host shell** or inside an existing Debian/Ubuntu LXC container.

## What gets installed

| Component      | Details                                                         |
|----------------|-----------------------------------------------------------------|
| Coder          | Latest release, auto-detected architecture                      |
| Docker Engine  | For workspace containers and project service dependencies       |
| Dockge         | Web UI for managing Docker Compose stacks (port 5001)           |
| PostgreSQL     | Required by Coder, configured automatically                     |
| systemd        | `coder.service` enabled and started on boot                     |

The LXC container is created as **privileged** with `nesting=1` and `keyctl=1` so Docker runs correctly inside it. Each Coder workspace is a Docker container on the same host, with full access to `docker compose` for service dependencies (databases, caches, etc.).

## Container defaults

| Setting    | Default       |
|------------|---------------|
| OS         | Debian 12     |
| Privileged | yes           |
| Cores      | 4             |
| RAM        | 8192 MB       |
| Disk       | 64 GB         |
| Network    | DHCP, vmbr0   |

Defaults can be changed by editing the `CT_*` variables at the top of `coder.sh`.

## After install

| Service | URL                          |
|---------|------------------------------|
| Coder   | `http://<container-ip>:3000` |
| Dockge  | `http://<container-ip>:5001` |

Open the Coder URL to create your admin account and configure your first workspace template. Use Dockge to manage Docker Compose stacks for shared services (databases, caches, etc.).

Configuration lives at `/etc/coder.d/coder.env` inside the container. After editing, restart with:

```bash
systemctl restart coder
```

## Updating

Re-run the script on the Proxmox host — it will detect the existing container and offer to update it.

## License

MIT
