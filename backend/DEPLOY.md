# Deploying the Hearth relay

The relay is the optional **cold-start bootstrap** — a pubkey-addressed signalling
mailbox plus the media-search proxies. It holds no plaintext and is only needed to
broker the *first* handshake; once peers connect, sync is pure P2P. You self-host it
and point the app's **Relay** setting at it.

This covers the **Tailscale Funnel** path (public HTTPS, no domain, no port-forward)
deployed as a **Portainer** stack — what's running in production. Alternatives are at
the end.

## TL;DR
1. Push a version tag → GitHub Actions publishes `ghcr.io/<you>/hearth-relay`.
2. Tailscale: an auth key + HTTPS enabled + **Funnel granted in the ACL**.
3. Portainer stack from `backend/docker-compose.tailscale.yml`; set `TS_AUTHKEY`.
4. The host needs `/dev/net/tun` (kernel mode — Funnel requires it).
5. `curl https://<host>.<tailnet>.ts.net/health` → `{"ok":true}`, point the app there.

## 1 · Publish the image
The relay runs from a prebuilt image, published by `.github/workflows/deploy.yml` on a
version tag (bare `0.1.0` or `v0.1.0` both trigger it):
```
git tag 0.1.0 && git push origin 0.1.0
```
Then make the GHCR package **Public** (GitHub → Packages → `hearth-relay` → settings →
visibility) so Portainer can pull it — or keep it private and add a `ghcr.io` registry
credential in Portainer (a **classic PAT with `read:packages`**).

## 2 · Tailscale prerequisites
- **Auth key** — admin console → Settings → Keys → a **reusable, non-ephemeral** key.
- **HTTPS** — admin console → DNS → Enable HTTPS certificates.
- **Funnel grant** (the easy-to-miss one) — the policy must grant the node the funnel
  attribute. The container applies the serve config directly, which *bypasses* the
  CLI's interactive "enable Funnel" step, so without this the funnel reads as "on"
  locally but is never published publicly. Add to **Access controls**:
  ```json
  "nodeAttrs": [
    { "target": ["autogroup:member"], "attr": ["funnel"] }
  ]
  ```

## 3 · Deploy the stack (Portainer)
**Stacks → Add stack → Repository**: this repo, compose path
`backend/docker-compose.tailscale.yml`. Set **environment variables**:

| var | required | notes |
|-----|----------|-------|
| `TS_AUTHKEY` | yes | the reusable auth key |
| `TS_HOSTNAME` | no | node name → `https://<name>.<tailnet>.ts.net` (default `hearth-relay`) |
| `GIPHY_KEY` | no | GIF search; without it search falls back to paste-a-URL |
| `FREESOUND_KEY` | no | sound search |
| `TAG` | no | image tag (default `latest`) |

The stack runs the official `tailscale/tailscale` **sidecar** (joins your tailnet as
the node, runs Funnel) plus the relay sharing its network namespace. Funnel proxies to
the relay on localhost and **nothing else on the host is exposed** — the tailnet node
is the *container*, not your NAS.

### Kernel mode + /dev/net/tun
Funnel needs **kernel networking** (a real TUN interface), so the stack maps
`/dev/net/tun` and grants `NET_ADMIN`. The host must provide that device:
- Many hosts already have it (Synology DSM x86 does) — the container just works.
- If the container errors with *"no such device"*, load the module on the host:
  ```
  sudo modprobe tun         # then, only if /dev/net/tun is still missing:
  sudo mkdir -p /dev/net && sudo mknod /dev/net/tun c 10 200 && sudo chmod 600 /dev/net/tun
  ```
  Persist it across reboots (Synology: Task Scheduler → boot-up task → `modprobe tun`).

`NET_ADMIN` + `/dev/net/tun` is the standard minimal grant every VPN container uses —
scoped to the container's own network namespace, **not** privileged mode, no host or
filesystem access.

## 4 · Verify + point the app
```
curl https://<host>.<tailnet>.ts.net/health    # → {"ok":true}
```
Then in Hearth on each device: drawer → **Relay** → that URL → restart. Devices do
**not** need to be on your tailnet (Funnel is public).

## Troubleshooting (things we actually hit)
- **`502` after a ~20s hang** — Funnel reached the node but the relay didn't answer.
  Almost always **userspace mode** (`TS_USERSPACE=true`): it configures Funnel but
  never receives inbound traffic. Use kernel mode (the default). Confirm the relay
  itself is fine by exec'ing the tailscale container: `wget -qO- http://127.0.0.1:8787/health`.
- **`NXDOMAIN` / "could not resolve"** — usually a **stale negative DNS cache** from
  querying the name before Funnel published it. Try another resolver
  (`nslookup <host> 9.9.9.9`) or wait out the negative TTL. Funnel DNS is public.
- **`denied` on deploy** — the image is private and Portainer has no GHCR creds. Make
  the package Public, or add a `read:packages` PAT registry credential.
- **`/gif/search` → `configured:false`** — `GIPHY_KEY` isn't set (optional).

## Alternatives
- **Cloudflare Tunnel** (`docker compose --profile cloudflare up -d`): no TUN, no
  privileges (`cloudflared` is outbound-only userspace), but needs a domain on
  Cloudflare. Set `TUNNEL_TOKEN`.
- **Plain local / LAN** (`backend/docker-compose.yml`): the relay on `127.0.0.1:8787`,
  no tunnel — point the app at `http://<host>:8787` over your LAN or tailnet.
