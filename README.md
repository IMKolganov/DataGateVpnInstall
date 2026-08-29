# VPN host install — copy folder, fill site.env, run one script

Installs **OpenVPN TCP/UDP WSS + nginx (SNI) + Pi-hole + optional Xray** on a fresh Ubuntu host.

## Before you start

1. Fresh Ubuntu server with SSH access (cloud image / root or `ubuntu`)
2. DNS **A-records** already pointing to the server IP:
   - `UDP_WSS_DOMAIN`
   - `TCP_WSS_DOMAIN`
   - `XRAY_DOMAIN` (if Xray enabled)
3. Know your office/home IP (for SSH UFW allow-list)
4. Your SSH **public** key on the laptop (`~/.ssh/id_ed25519.pub`)

## Recommended order

Do **SSH hardening first**, then the VPN stack. Keep a second SSH session open until the new login works.

| Step | What |
|------|------|
| 1 | Clone `DataGateVpnInstall` or copy `install/vpns` submodule |
| 2 | Create admin user + sudo password + SSH key + Google Authenticator (`setup-host-ssh.sh`) |
| 3 | Confirm login as the new user (key + TOTP) |
| 4 | Fill `site.env` / wizard and run `install-vpn-host.sh` |

SSH policy comes from `templates/ssh/` (same as repo `ssh_configs/`):

- `PermitRootLogin no`
- `PasswordAuthentication no` (password is for **sudo** only)
- `AuthenticationMethods publickey,keyboard-interactive` → **SSH key + TOTP**

### 1) Get installer on the server

```bash
# first time — clone only this repo (~200KB, no monorepo)
git clone https://github.com/IMKolganov/DataGateVpnInstall.git
cd DataGateVpnInstall
chmod +x scripts/*.sh

# updates
cd ~/DataGateVpnInstall && git pull
chmod +x scripts/*.sh
```

Monorepo submodule path (DataGateMonitor developers):

```bash
git clone --recurse-submodules https://github.com/IMKolganov/DataGateMonitor.git
cd DataGateMonitor/install/vpns
```

Or copy only the folder:

```bash
scp -r install/vpns user@NEW_VPN_HOST:~/
```

### 2) Admin user + password + 2FA

```bash
# on the server (as root or ubuntu)
cd ~/vpns
chmod +x scripts/*.sh

# Creates user, asks for sudo password, copies SSH keys, enrols TOTP, installs sshd + PAM
sudo ./scripts/setup-host-ssh.sh --user YOURNAME --pubkey-from-user ubuntu
# or: --pubkey /path/to/id_ed25519.pub
```

Then **open a new SSH session** as `YOURNAME` and enter the authenticator code. Only after that close the old session.

Re-apply sshd/PAM later (if you skipped it):

```bash
sudo ./scripts/setup-host-ssh.sh --user YOURNAME --apply-sshd-only
```

### 3) VPN install

```bash
# as YOURNAME
cd ~/vpns
cp site.env.example site.env
nano site.env          # INSTALL_HOME=/home/YOURNAME — replace EVERY YOUR_* / example.com / CHANGE_ME
sudo ./scripts/install-vpn-host.sh
```

Or answer prompts (recommended first time):

```bash
sudo ./scripts/install-vpn-host.sh --wizard
```

The installer **refuses to run** while placeholders remain (`YOUR_*`, `example.com`, `CHANGE_ME`).

## Layout on the server

```
~/install/vpns/           # installer kit (scripts, templates, site.env)
~/openvpn-tcp-wss/        # TCP OpenVPN only
~/openvpn-udp-wss/        # UDP OpenVPN only
~/pi-hole/
~/nginx-docker/
~/datagate-monitor-xray/  # if Xray enabled
~/host/
```

## What the script does

1. Validates `site.env` (IPs, domains, unique subnets)
2. Preflight: `/dev/net/tun`, DNS → `PUBLIC_IP` warnings
3. Renders stacks under `INSTALL_HOME` (`openvpn-tcp-wss`, `openvpn-udp-wss`, `pi-hole`, `nginx-docker`, optional `datagate-monitor-xray`, `host/`)
4. Installs Docker (optional)
5. UFW + `ip_forward` (SSH allowed for `ADMIN_SSH_IP` **and** your current SSH session IP)
6. Starts in order: OpenVPN → Pi-hole → nginx (HTTP) → **one Let's Encrypt cert per domain** → HTTPS configs → Xray (if enabled)

## Required `site.env` fields

| Variable | Notes |
|----------|--------|
| `PUBLIC_IP` | Server public IPv4 |
| `INSTALL_HOME` | e.g. `/home/YOURNAME` — sibling folders for each stack |
| `CERTBOT_EMAIL` | Real email (not `@example.com`) |
| `UDP_WSS_DOMAIN` / `TCP_WSS_DOMAIN` | DNS A → `PUBLIC_IP` |
| `BACKEND__BASEURL` | e.g. `https://api.datagateapp.com/` |
| `DASHBOARD_API_IP` | Dashboard host IPv4 |
| `ADMIN_SSH_IP` | **Your** IPv4 — wrong value risks SSH lockout |
| `TCP_VPN_SUBNET` / `UDP_VPN_SUBNET` | Different `/24` per host |
| `PIHOLE_WEBPASSWORD` | Strong password |

If `INSTALL_XRAY=true` also set `XRAY_DOMAIN`, `XRAY_DNS_IDENTITY_SUBNET`, `XRAY_API_ALLOW_IPS`.

Two new servers → **different** VPN + Xray identity subnets on each.

## Adding another VPN host (zero manual host tweaks)

Use the **latest** installer (`git pull` / fresh clone). After `install-vpn-host.sh` finishes, `post-install-check.sh` must pass — that covers the Helsinki class of bugs (identity iface, UFW :53, host route, DCO, CIPHER in compose).

### DNS A-records (create before certbot)

Point all of these to the **new** server `PUBLIC_IP` (not hel):

| Record | Example |
|--------|---------|
| UDP WSS | `s1-xxx.datagateapp.com` → PUBLIC_IP |
| TCP WSS | `s2-xxx.datagateapp.com` → PUBLIC_IP |
| Xray (if enabled) | `xs1-xxx.datagateapp.com` → PUBLIC_IP |

Wait until `dig +short DOMAIN` returns the new IP, then install.

### Unique subnets (never reuse hel)

| Variable | hel-1 (taken) | next host example |
|----------|---------------|-------------------|
| `TCP_VPN_SUBNET` | `10.51.44.0` | `10.51.48.0` |
| `UDP_VPN_SUBNET` | `10.51.46.0` | `10.51.50.0` |
| `XRAY_DNS_IDENTITY_SUBNET` | `10.80.2.0/24` | `10.80.3.0/24` |

### Install (host side — no post-edit)

```bash
git clone https://github.com/IMKolganov/DataGateVpnInstall.git
cd DataGateVpnInstall && git pull && chmod +x scripts/*.sh
cp site.env.example site.env && nano site.env   # unique subnets + domains + IPs
# or: sudo ./scripts/install-vpn-host.sh --wizard

sudo ./scripts/install-vpn-host.sh
# ends with post-install-check — must print POST-INSTALL OK

# re-check anytime:
sudo ENV_FILE=~/site.env ./scripts/post-install-check.sh
```

Installer applies automatically (no hel-style hand fixes):

- OpenVPN cipher from **AES-NI** detect (AES-128-GCM vs ChaCha)
- `CIPHER` / `DATA_CIPHERS` in TCP **and** UDP compose
- Host DCO module (`ovpn` / ovpn-dco)
- `XRAY_DNS_IDENTITY_IFACE=eth0`
- UFW: identity subnet → Pi-hole `:53` + forward
- Host route + `datagate-xray-dns-route.service`
- Pi-hole re-join after TCP recreate (`datagate-pihole-after-tcp.service`)

### Existing hosts — Pi-hole exit 128 after reboot

`network_mode: container:openvpn-tcp-wss` stores a container **id**. After TCP recreate, Pi-hole exits 128 until force-recreated.

```bash
cd ~/DataGateVpnInstall && git pull && chmod +x scripts/*.sh
mkdir -p ~/host
cp scripts/recreate-pihole-after-tcp.sh ~/host/ && chmod +x ~/host/recreate-pihole-after-tcp.sh
sed "s|__INSTALL_HOME__|$HOME|g" templates/host/datagate-pihole-after-tcp.service \
  | sudo tee /etc/systemd/system/datagate-pihole-after-tcp.service >/dev/null
sudo systemctl unmask datagate-pihole-after-tcp.service 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl enable --now datagate-pihole-after-tcp.service
# dig only after healthy (~20–40s importing query DB is normal):
# dig @$(ip -4 -br addr show tun-tcp | awk '{print $3}' | cut -d/ -f1) youtube.com +short
```

### Dashboard only (not on the VPS)

After host checks pass:

1. Register UDP / TCP / Xray ApiUrls
2. New servers get seeded export templates with AES-128-GCM (deploy backend/frontend first)
3. Xray: JSON template with `dnsServers: ["10.51.x.1"]`
4. Pi-hole: `http://10.51.x.1:8080`, prefix `10.80.x.`
5. Issue client links

Client: Private DNS Off.

After `docker compose up --force-recreate` on xray only:

```bash
sudo systemctl start datagate-xray-dns-route.service
```

## Useful flags

```bash
sudo ./scripts/install-vpn-host.sh --render-only      # write files only (no root needed)
sudo ./scripts/install-vpn-host.sh --skip-ufw
sudo ./scripts/install-vpn-host.sh --skip-certs
sudo ./scripts/install-vpn-host.sh --skip-start
sudo ./scripts/install-vpn-host.sh --skip-preflight
sudo ./scripts/install-vpn-host.sh --env /path/to/site.env
```

Safe first dry-run on a new VPS:

```bash
sudo ./scripts/install-vpn-host.sh --skip-ufw --skip-certs --skip-start
# inspect ~/openvpn ~/pi-hole ~/nginx-docker
# then full run once DNS is ready:
sudo ./scripts/install-vpn-host.sh
```

## After install — dashboard

| Service | ApiUrl / field |
|---------|----------------|
| OpenVPN UDP | `https://UDP_WSS_DOMAIN/` — type **OpenVPN** |
| OpenVPN TCP | `https://TCP_WSS_DOMAIN/` — type **OpenVPN** |
| Xray | `https://XRAY_DOMAIN:9443` — type **Xray** (not OpenVPN; wrong type → JWT audience mismatch → **401**) |
| Xray Pi-hole Base URL | `http://{PIHOLE_DNS_IP}:8080` (e.g. `http://10.51.48.1:8080`) |
| Xray Pi-hole app password | same as `PIHOLE_WEBPASSWORD` |
| Xray Pi-hole client subnet | identity prefix, e.g. `10.80.3.` |

Issued Xray profiles default to **VLESS xHTTP on `:2053`** (`XRAY_CLIENT_LINK_TRANSPORT=xhttp`) with SNI = `XRAY_DOMAIN` (your LE hostname — not microsoft/apple). Primary TLS on `:443` stays up as fallback; set `XRAY_CLIENT_LINK_TRANSPORT=primary` only for soft regions.

## Traffic path (full stack)

```
:443  nginx stream (SNI)
        ├─ XRAY_DOMAIN → xray:443 + PROXY protocol   (primary VLESS+TLS; soft regions / fallback)
        └─ default     → :8443 OpenVPN WSS + PROXY → host :5010/:5011

:2053 xray xHTTP VLESS (direct; **default issued client profile** for RF/Iran)
:9443 nginx → xray:5010 (manager, IP allow-list)
:80   ACME + redirect
```

## Troubleshooting

| Symptom | Check |
|---------|--------|
| certbot fails | `dig +short DOMAIN` must equal `PUBLIC_IP`; port 80 open |
| Dashboard Xray Offline / **401 Unauthorized** on `:9443` | nginx `xray-api.conf` must `proxy_set_header Authorization $http_authorization;` (JWT otherwise never reaches manager). Also: ServerType must be **Xray** (audience `DataGateXRayManager`); `docker logs datagate-monitor-xray` must show public key fetched from `Backend__BaseUrl` |
| Xray Pi-hole step 4 timeout | Xray Base URL must be `http://{PIHOLE_DNS_IP}:8080` (e.g. `10.51.44.1`), not `172.17.0.1` — Pi-hole listens on tun-tcp, not docker0 |
| Xray DNS fails / step 5 forwarded=0 | `XRAY_DNS_IDENTITY_IFACE=eth0`; host route for identity subnet → xray container; UFW allow **identity subnet** (e.g. `10.80.2.0/24`) → `{PIHOLE_DNS_IP}:53` (not only docker CIDR — sendThrough uses identity IPs as source); re-issue link after sync |
| Pi-hole exits (128) | TCP OpenVPN recreated; Pi-hole still on old container id. `cd ~/pi-hole && docker compose up -d --force-recreate`. Enable `datagate-pihole-after-tcp.service` so reboot auto-fixes |
| Pi-hole exits | OpenVPN TCP must be Up first; `docker logs datagate-pihole` |
| no SSH after UFW | reconnect from `ADMIN_SSH_IP` or console; installer also allows session IP |
| no SSH after 2FA | console/VNC: restore `/etc/ssh/sshd_config.bak.*` and `/etc/pam.d/sshd.bak.*`, `systemctl restart ssh` |
| Xray won't start | certs must exist under `nginx-docker/certbot/conf/live/XRAY_DOMAIN/` |
| OpenVPN slow / high CPU | 1 vCPU + WSS caps ~50–100 Mbit; installer picks AES-128-GCM if AES-NI else ChaCha; prefer Xray for speed; DCO: `lsmod \| grep ovpn` |
| Xray DNS route unit failed | Prefer `host/setup-xray-dns-identity-route.sh` over inline `bash -c`; check `journalctl -xeu datagate-xray-dns-route` |

Local smoke test (developer machine):

```bash
./scripts/smoke-test-local.sh
./scripts/verify-installer.sh
```
