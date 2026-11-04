# Dashboard host: Monitor, Telegram bot, landing

`scripts/install-dashboard-host.sh` prepares a fresh **Ubuntu 24.04 LTS** host and deploys:

| Stack | Contents |
| --- | --- |
| `datagate-monitor` | Monitor backend, frontend, Redis |
| `datagate-monitor-telegrambot` | Telegram bot, HTTPS webhook at `https://TG_DOMAIN/api/bot` |
| `datagate-landing` | Landing built from the configured Git ref |
| `nginx-docker` | HTTP/HTTPS reverse proxy, Let's Encrypt certificates |

Host protection reuses the VPN installer: SSH **key + TOTP**, console **password + TOTP**, GRUB password,
idle session limits, Wazuh, node_exporter, UFW and **LUKS2 + clevis + tang-gate**.
The SSH TOTP protects Linux access; it does not configure application account MFA.

In Server Control, choose **Dashboard — Monitor, Telegram bot and landing** on Create. On an existing,
unenrolled host with an encrypted disk and a data partition, the server card also offers **Install Dashboard +
Telegram bot**. That button opens a form for the deploy key/passphrase, application config, tang-gate bundle
and offline recovery passphrase. Opening the form does not start SSH or change the VM. **Start install** submits
the dashboard profile explicitly, including for hosts created before profile selection existed.
Unsupported settings in an existing env file are ignored, including `TARGETARCH` and `ASPNETCORE_URLS`.
The installer supplies listener and host settings; application images use the deployment host's architecture.
The application config can be empty or unfinished when preparing through Server Control. Domains are taken
from the server card. In that case the installer completes disk protection, Docker, firewall, SSH/console 2FA
and monitoring, then saves application files and `/srv/data/datagate/dashboard.env` for manual editing.
Application containers stay stopped until the database/JWT/bot credentials are ready. The activity log
explicitly distinguishes host preparation from application deployment.

The **data disk/partition** is encrypted. Ubuntu and the boot tunnel remain on the system disk, as on VPN hosts.
After reboot SSH remains available; Docker, containerd and the stacks wait for approval on your PC.
App secrets, backend/bot resources, data-protection keys, Redis, certificates, container layers and Docker logs
live on `/srv/data`. There is no unencrypted deployment mode.

## 1. Prepare the server and service bundle

Use a fresh server with either:

- an empty `dgsc-data` partition reserved when provisioning through Server Control; or
- a separate, empty data disk attached through the cloud provider, for example `/dev/vdb`.

The installer **does not shrink the root filesystem**. If the OS already occupies the whole disk, attach a data
disk or reprovision with reserved data space. It refuses a data device that already has a filesystem/signature
and refuses to migrate an existing populated Docker/containerd installation.

On the PC running your tang-gate stack:

```bash
cd /path/to/tang-gate
./scripts/server-bundle.sh dg-dashboard --device /dev/vdb \
  --start-units "containerd.service docker.service datagate-dashboard-services.target"
scp bundles/service-dg-dashboard.tar.gz root@NEW_IP:/dev/shm/
```

The hub/gate must be reachable **without the dashboard**: the hub must already have its backend key cached
and the service profile must already be issued. Otherwise recovery of the dashboard would depend on the
dashboard itself. Keep the disk recovery passphrase offline for recovery without the gate.

On the new server, keep the installer root-owned and put the bundle/config in RAM:

```bash
git clone https://github.com/IMKolganov/DataGateVpnInstall.git /opt/datagate-installer
cd /opt/datagate-installer
tar xzf /dev/shm/service-dg-dashboard.tar.gz -C /dev/shm
cp dashboard.env.example /dev/shm/dashboard.env
chmod 600 /dev/shm/dashboard.env
nano /dev/shm/dashboard.env
```

Set `PUBLIC_IP`, `DATA_DEVICE`, `ADMIN_USER`, `ADMIN_SSH_IP`, `WAZUH_MANAGER`, `PROMETHEUS_IP`.
Wazuh's version must match the manager. Public admin/Prometheus addresses must be IPv4.
For the separate data disk above use `DATA_DEVICE=/dev/vdb`; otherwise use the `dgsc-data` label.

`dashboard.env` is trusted **Bash**, like `site.env`. Single-quote passwords/tokens containing `$`, spaces or `#`.
Raw Compose env files preserve these characters without a second round of interpolation. Compose 2.30+ is required.
Never commit the filled config, service profile or bundle.

## 2. Prepare encryption, 2FA and monitoring

```bash
sudo bash /opt/datagate-installer/scripts/install-dashboard-host.sh \
  --env /dev/shm/dashboard.env --prepare-only \
  --tang-bundle-dir /dev/shm/service-dg-dashboard
```

tang-gate asks you to save an offline recovery phrase and type the selected device name before formatting it.
Then the existing VPN scripts configure the admin's sudo password, SSH public key, authenticator QR/recovery
codes and GRUB recovery password. Existing TOTP enrollment is preserved. Keep this session open and **test
a second login as `ADMIN_USER` with your key and TOTP**.

For file-based input, set `ADMIN_PUBKEY_FILE`, `ADMIN_PASSWORD_FILE`, `ADMIN_TOTP_SECRET_FILE`,
`GRUB_PASSWORD_FILE`, optional `WAZUH_PASSWORD_FILE` and `DATA_RECOVERY_FILE` in the config. Use `/dev/shm`
and mode `0600` for secret input files. The disk-device confirmation remains interactive. Supplied TOTP must
already be imported into your authenticator. The installer removes its temporary copies; your original inputs
remain available until you remove them or reboot. No recovery phrase/token is printed from a supplied file.

Do not reboot yet if your only filled config is in `/dev/shm`. Complete deployment below first, or save the
config to `/srv/data/datagate/dashboard.env` with mode `0600`.

## 3. Fill application secrets and deploy

Before deployment:

1. Point A records for `DASHBOARD_DOMAIN`, `API_DOMAIN`, every `LANDING_DOMAINS` hostname and `TG_DOMAIN`
   to the new `PUBLIC_IP`. Remove stale AAAA records, or prepare an IPv6 deployment separately.
2. On the Postgres host, allow the **new dashboard IP** through its firewall and `pg_hba.conf`.
   Set `DB_CONNECTION_STRING_DATAGATE` to the existing database. No Postgres container is created here.
3. Restore `JWT_SECRET`, `Jwt__RefreshPepper`, SMTP/Resend configuration and any OAuth/Elastic credentials.
   A new JWT secret invalidates previous tokens. Set `Auth__PublicWebBaseUrl` to the dashboard web origin.
4. Set `TELEGRAMBOT_BOT_TOKEN` for the **existing bot**, and `DASHBOARDAPI_CLIENTID` /
   `DASHBOARDAPI_CLIENTSECRET` for its registered Dashboard application. Reuse the existing registration from
   the surviving database, or register a replacement through Monitor's Applications UI/API. Keep optional
   Crypto Pay/Stars settings if used. The bot registers its webhook automatically.
5. Restore a backup of the backend/bot `resources` directories if available. In particular, backend signing
   keys are not recreated with their previous identity. Installing images does not recover data lost with the disk.

You can inspect the generated configs before starting containers, after unlocking the disk:

```bash
sudo bash /opt/datagate-installer/scripts/install-dashboard-host.sh \
  --env /dev/shm/dashboard.env --render-only
# If restoring resources, restore them now into the directories below.

sudo bash /opt/datagate-installer/scripts/install-dashboard-host.sh \
  --env /dev/shm/dashboard.env --deploy-only
```

`--render-only` writes configs but performs no host changes or network requests; it can also target a temporary
`INSTALL_HOME` on a developer workstation. App secrets must be filled before rendering/deploying.
Preparation alone does not require the application secrets.

With no mode flag, the script runs both preparation and deployment. An already configured tang-gate partition
is checked and reused; it is never reformatted. A locked partition stops the run until you approve unlocking.

The deploy step checks DNS, creates stacks, bootstraps HTTP-01 certificates, validates/reloads nginx, waits for
backend readiness and frontend/bot/landing HTTP responses, and verifies the expected webhook using Telegram's
`getWebhookInfo`. Only then does it print `DASHBOARD INSTALL OK`. The bot's external port is `443`, its internal
HTTP listener is `5050`; TLS belongs to nginx. Backend, frontend, Redis, bot and landing publish no host ports.

Certificates renew twice daily with a systemd timer. Docker/containerd and that timer start after disk approval.
The firewall allows HTTP/HTTPS, SSH from the configured/current session IP, and node_exporter from Prometheus.
Register the node_exporter target on your Prometheus server; the installer does not edit a remote Prometheus.

```text
/srv/data/
  docker/                            Docker layers, volumes, logs
  containerd/                        containerd image storage
  datagate/
    dashboard.env                     mode 0600
    datagate-monitor/
      backend.env, frontend.env        mode 0600
      resources/, data-protection/, redis/
    datagate-monitor-telegrambot/
      telegrambot.env                  mode 0600
      resources/, data-protection/
    datagate-landing/source/
    nginx-docker/conf.d/, certbot/
    host/renew-certs.sh
```

Use the same `DASHBOARD_DOMAIN` and `API_DOMAIN` if you want UI and API on one hostname.
Empty `LANDING_DOMAINS` skips landing. To skip the bot, empty `TG_DOMAIN` and its credentials.
Changing those to empty later does not delete an existing stack or its data; stop any retired stack explicitly.
Set image tags/digests and `LANDING_GIT_REF` to the release you intend to deploy.

## 4. Restart and recovery

After successful deployment, the filled config is on the encrypted disk. Delete the original bundle/archive
and secret input files from `/dev/shm` when no longer needed.

```bash
sudo reboot
# On your PC:
sudo tang-gate approve
# On the server, after approval:
sudo tang-gate-unlock --status
sudo docker ps
sudo systemctl status datagate-dashboard-cert-renew.timer --no-pager
```

Without the gate, use the **actual DEVICE and NAME** from `/etc/tang-gate/unlock.conf`:

```bash
sudo cryptsetup open /dev/disk/by-partlabel/dgsc-data tang-data
sudo tang-gate-unlock --after-manual-open
```

Later deployments use the saved config and preserve resources/certificates:

```bash
sudo bash /opt/datagate-installer/scripts/install-dashboard-host.sh \
  --env /srv/data/datagate/dashboard.env --deploy-only
```

Check logs with `sudo docker logs datagate-monitor-backend` / `datagate-monitor-telegrambot`,
`journalctl -u tang-gate-unlock`, and `journalctl -u datagate-dashboard-cert-renew`.

Local verification, with no host modifications or published test ports:

```bash
bash scripts/smoke-test-dashboard.sh
```
