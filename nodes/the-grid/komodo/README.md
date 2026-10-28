# Komodo — the-grid

In Komodo v2.3.3, Core and MongoDB run in containers. Periphery runs as a systemd service.
Komodo runs in a trial **alongside DockHand**. The trial started on 2026-09-23. The purpose of
the trial is to choose which of Komodo and DockHand to keep.

The rules are the same as for DockHand:

- The repo remains the source of truth.
- Komodo manages no real Stack until the test on flaresolverr shows what Komodo writes.
- Faginux starts every state transition.

## How it is built

| Part | Where | Notes |
|---|---|---|
| `komodo-mongo` | Container. It publishes no port. | `mongo:8.0.32`. The data is in `/srv/docker/komodo/mongo-*`. |
| `komodo-core` | Container. It publishes `127.0.0.1:9120` and `198.51.100.20:9120`. | It provides the UI and the API. The keys are in `/srv/docker/komodo/keys`. |
| `komodo-periphery` | systemd service. It runs as the user `ops`. | **It opens no port.** Periphery starts the connection to Core (v2). The process has read-only access to the repo. |
| `komodo.homelab.example` | Caddy, private section | It uses `remote_ip 100.64.0.0/10`. This is the same as for dockhand. |

The comments in `docker-compose.yml` and `komodo-periphery.service` explain why Periphery does
not run in a container. They also explain why the unit file is written by hand and why the
official installer is not used.

## Installation (in Termius on the-grid)

Each block is one step. For each step, do these actions:

1. Run the commands in the block.
2. Read the output.
3. Continue to the next step.

### 1. Folders and secrets

```bash
cd ~/github/homelab/nodes/the-grid/komodo
mkdir -p /srv/docker/komodo/{mongo-data,mongo-config,keys,backups,periphery}
cp .env.example .env && chmod 600 .env
for v in KOMODO_DATABASE_PASSWORD KOMODO_INIT_ADMIN_PASSWORD KOMODO_JWT_SECRET KOMODO_WEBHOOK_SECRET; do
  sed -i "s|^$v=.*|$v=$(openssl rand -hex 24)|" .env
done
grep -c changeme .env                    # expected: 0
docker compose config --quiet && echo OK  # validates and prints nothing
```

### 2. First start of Core + MongoDB

```bash
docker compose up -d
docker compose ps                        # both Up
docker logs komodo-core --tail 30 2>&1 | grep -viE 'pass|secret|key|token'
stat -c '%U %n' /srv/docker/komodo/mongo-data   # expected: user 999 (mongodb), not ops
```

### 3. First login

Open `http://198.51.100.20:9120` in a browser on the tailnet. The user is `ops`.

Do not paste the password into the chat. Read the password **yourself** with this command:

```bash
grep '^KOMODO_INIT_ADMIN_PASSWORD=' .env | cut -d= -f2
```

Then create an **onboarding key** in the Servers menu of the UI. The UI shows the exact name of
the menu item. Copy the key. The key starts with `O-`.

### 4. Periphery

```bash
# binary of release v2.3.3, checked with the digest that GitHub publishes
curl -fsSL -o /tmp/periphery https://github.com/moghtech/komodo/releases/download/v2.3.3/periphery-x86_64
echo "40b78f377626799afad8331246a501f077d4ebcfb6d9096894cf55b64f6dcf13  /tmp/periphery" | sha256sum -c -
sudo install -m 755 -o root -g root /tmp/periphery /usr/local/bin/periphery && rm /tmp/periphery

# unit + file of the onboarding key (root, 600)
sudo install -m 644 -o root -g root komodo-periphery.service /etc/systemd/system/komodo-periphery.service
sudo install -d -m 700 /etc/komodo
sudo install -m 600 /dev/null /etc/komodo/periphery-onboarding.env
sudo nano /etc/komodo/periphery-onboarding.env   # one line: PERIPHERY_ONBOARDING_KEY=O_..._O (32 characters)

sudo systemctl daemon-reload && sudo systemctl enable --now komodo-periphery
systemctl status komodo-periphery --no-pager | head -12
```

When the UI shows **OK** for the server `the-grid`, run this command:

```bash
sudo rm /etc/komodo/periphery-onboarding.env     # the key is not necessary now
```

Then **disable or delete the onboarding key** in the UI. The key is reusable. While the key
exists, you can use it to attach new servers.

### 5. Caddy route

Claude makes the route with a script on the-grid. Claude does these actions:

- Claude changes the Caddyfile on the same inode (§10.4).
- Claude validates the Caddyfile with the binary of the container.
- Claude commits the change and pushes it from the-grid.

## Update

- Core and MongoDB: change the tag in the compose file. Then run `docker compose up -d`.
- Periphery: repeat step 4 with the new version and the new digest. Then run
  `sudo systemctl restart komodo-periphery`. Keep Core and Periphery at the same version.
- Periphery reads `periphery.config.toml` from the repo. After a pull that changes the file,
  run `sudo systemctl restart komodo-periphery`.
