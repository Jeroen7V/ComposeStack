# Composition

Docker Compose stacks for self-hosted services on a home server (Wairuha).
Each subdirectory is an independent stack with its own `docker-compose.yml` and
`.env` file, deployed with `docker compose up -d` from inside the stack directory.

```
/opt/composition
├── <stack>/              # one directory per stack
│   ├── docker-compose.yml
│   ├── .env              # secrets and stack variables (never committed)
│   └── .env.example      # template with all variables, placeholder values
├── appdata/              # persistent container data, one folder per service (gitignored)
└── README.md / AGENTS.md
```

## Networking

All services that need to be reachable from the LAN live on a macvlan network
called `services`, so every exposed container gets its own IP address on the
LAN subnet — no port publishing, no NAT.

The host-side setup (run once per boot):

```sh
ip link add services link enp1s0 type macvlan mode bridge
ip addr add 192.168.1.10/32 dev services
ip link set services up
ip route add 192.168.1.64/26 dev services
```

- The macvlan device bridges onto the physical NIC `enp1s0`.
- The host itself gets `192.168.1.10/32` on that device; the route to
  `192.168.1.64/26` lets the host talk to the containers (the usual macvlan
  limitation workaround).
- Container addresses come from `192.168.1.64/26` (`192.168.1.64` – `192.168.1.127`).
- These commands are **not persistent** — see "Persisting across reboots"
  below. If the host suddenly can't reach container IPs, this is the first
  thing to check.
- The `<app>.int.krokantekrab.be` routes rely on a wildcard DNS record
  (`*.int.krokantekrab.be` → `192.168.1.84`, NPM) existing in the LAN DNS.

### Persisting across reboots

The macvlan device and its route disappear on every reboot. Make the setup a
oneshot systemd unit on the host,
`/etc/systemd/system/macvlan-services.service`:

```ini
[Unit]
Description=macvlan "services" device for containers
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip link add services link enp1s0 type macvlan mode bridge
ExecStart=/usr/sbin/ip addr add 192.168.1.10/32 dev services
ExecStart=/usr/sbin/ip link set services up
ExecStart=/usr/sbin/ip route add 192.168.1.64/26 dev services

[Install]
WantedBy=multi-user.target
```

Then enable it:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now macvlan-services.service
```

`RemainAfterExit=yes` keeps the unit in the "active" state after the commands
have run, so they execute exactly once per boot instead of on every start
request. After a reboot, verify with `ip route show | grep 192.168.1.64` —
if that line is missing, the host can't reach the containers.

The `services` network is created outside of Compose and referenced as
`external: true` in every stack. Each stack picks the network name up from
`NETWORK` in its `.env`, and every exposed container gets a static IP from
`.env` as well:

```yaml
networks:
  default:
    external: true
    name: ${NETWORK}

services:
  example:
    networks:
      default:
        ipv4_address: ${EXAMPLE_IP}
```

Containers that are only consumed by other containers in the same stack
(databases, caches, workers) do not get a static IP — they join the network
without one, or stay on an internal network. Don't burn LAN addresses on
backends.

## Stacks

| Stack        | Services                                          | IPs (192.168.1.x)                |
|--------------|---------------------------------------------------|----------------------------------|
| `media`      | transmission, prowlarr, sonarr, radarr, bazarr, jellyfin, tdarr | 66–72 |
| `immich`     | immich server, machine learning, redis, postgres  | 82 (server only)                |
| `npm`        | nginx proxy manager, npm-docker-sync              | 84                               |
| `grimmory`   | grimmory, mariadb                                  | 81 (grimmory only)               |
| `homeassist` | mqtt (mosquitto), music-assistant                 | 75, 76                           |
| `netbird`    | netbird routing peer, adguard-home                | 85, 86                           |
| `hermes`     | hermes agent                                      | 87                               |

Reverse proxying is handled by Nginx Proxy Manager (`npm/`): exposed
containers are labeled with `npm.proxy.*` labels (rule 9 under Conventions)
and `npm_docker_sync` watches for them, creating the route and attaching the
`*.int.krokantekrab.be` wildcard certificate automatically.

## Deploying

```sh
cd /opt/composition/<stack>
docker compose up -d
```

Each stack is self-contained: it reads its own `.env` (Compose loads it
automatically from the stack directory). Config and data persist under
`/opt/composition/appdata/<service>`.

To add a new service: create a directory, copy the shape of an existing
conformant stack (e.g. `netbird/`), assign a free IP in the `.env`, and bring
it up.

## Conventions (hard rules)

These apply to every stack. `media/docker-compose.yml` is the reference
implementation for most of them (exception: rule 5 — its environment
variables use the array form and still need converting).

1. **Logging** — JSON file driver with a maximum size, so logs can't fill the
   disk:
   ```yaml
   logging:
     driver: json-file
     options:
       max-size: "1m"
   ```
2. **`container_name`** — always defined, on every service.
3. **Exposure** — exposed containers sit on the `services` macvlan network with
   a static IP set through the stack's `.env`; unexposed containers don't.
4. **Healthchecks** — set them where the image offers a meaningful check
   (HTTP endpoint, CLI ping, etc.).
5. **Environment variables** — use the mapping form, not the array form:
   ```yaml
   environment:
     TZ: ${TZ}
     PUID: "0"
   ```
6. **Timezone** — `TZ` is always set (via `.env`, `Europe/Brussels`).
7. **Secrets** — never in `docker-compose.yml`, only in `.env`. `.env` files
   are gitignored and must stay out of git.
8. **Linting** — all YAML files must pass `yamllint`.
9. **Reverse proxy labels** — every exposed container carries the labels that
   `npm_docker_sync` uses to register it with Nginx Proxy Manager
   automatically. The route is `<app-name>.int.krokantekrab.be` (use a route
   name if it differs from the app name), terminated with the wildcard
   certificate (id 8):
   ```yaml
   labels:
     npm.proxy.domains: grimmory.int.krokantekrab.be
     npm.proxy.port: "6060"
     npm.proxy.ssl.certificate.id: "8"
   ```
   `npm.proxy.port` is the port the container itself listens on; NPM reaches
   the container over the macvlan network.

Additionally standard:

- `restart: unless-stopped` on every service.
- Persistent data goes under `/opt/composition/appdata/<service>`, referenced
  through `${DIR_CONFIG}` (or an equivalent directory variable) from `.env`.
- Services running as a non-root user must have their `appdata/<service>`
  directory owned by that UID/GID, or they crash-loop on start.
- Every stack directory contains a committed `.env.example` listing all
  variables the compose file expects, with placeholder (non-secret) values.
  `.env` itself is never committed, so a fresh clone can be rebuilt from the
  examples.

## Tooling

Both of these are expected to pass before any change is committed:

```sh
# YAML validity/style
yamllint **/docker-compose.y*ml

# secret detection in compose files, examples and history
betterleaks
```

`betterleaks` also scans git history, so a secret that was ever committed keeps
getting flagged — clean history is the only real fix for that.

## Notes

- `.env` files are not in git. Back them up separately; they contain every
  password and the full IP plan.
- `appdata/` is gitignored: it is live data (databases, caches, letsencrypt
  certificates), not configuration.
