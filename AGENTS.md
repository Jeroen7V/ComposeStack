# AGENTS.md

Docker Compose stacks for a home server. One directory per stack, each with
its own `docker-compose.yml` and `.env`. Humans read `README.md` for the full
picture; this file is the rule set for changing anything in this repository.

## Layout

- `<stack>/docker-compose.yml` — the stack definition.
- `<stack>/.env` — all secrets and stack variables. **gitignored, never
  commit, never reference values from it in committed files.**
- `<stack>/.env.example` — committed template: every variable the compose file
  reads, with placeholder values. When adding a variable to a compose file,
  add it to `.env.example` too.
- `appdata/` — live container data. gitignored. Never edit, never commit.

## Hard rules for every compose file

`media/docker-compose.yml` is the reference implementation.

1. Every service defines `container_name`.
2. Every service sets `TZ` (mapping form, value from `.env`, e.g. `TZ: ${TZ}`).
3. `environment` uses the mapping form, not the array form:
   ```yaml
   environment:
     TZ: ${TZ}
     PUID: "0"
   ```
4. Every service has:
   ```yaml
   restart: unless-stopped
   logging:
     driver: json-file
     options:
       max-size: "1m"
   ```
5. Healthchecks wherever the image supports a meaningful check (HTTP endpoint,
   CLI status command). Databases: use their admin ping command. Probe the
   real listen port and endpoint inside the running container before writing
   the check — a healthcheck that has never passed is worse than none.
6. Network exposure:
   - Exposed services join the external macvlan network and get a static IP
     from `.env`:
     ```yaml
     networks:
       default:
         external: true
         name: ${NETWORK}
     # per service:
         ipv4_address: ${SERVICE_IP}
     ```
   - Backend-only services (databases, caches, workers) must NOT take a
     static IP — join without `ipv4_address` or use an internal network.
   - No `ports:` publishing; exposed services are reached via their macvlan IP.
7. Secrets live only in `.env`. Compose files reference `${VARIABLE}`, never a
   literal password, key, or token. This includes connection URLs.
8. Persistent volumes point at `/opt/composition/appdata/<service>` via a
   `${DIR_CONFIG}`-style variable from `.env`.
9. Exposed containers set the `npm.proxy.*` labels so `npm_docker_sync`
   (in `npm/`) auto-registers the route with Nginx Proxy Manager. The domain
   is `<ROUTE_NAME>.int.krokantekrab.be`, terminated with the wildcard
   certificate id 8. Keep route names short: use the app name, or a shorthand
   for long names (e.g. `ma` instead of `music-assistant`):
   ```yaml
   labels:
     npm.proxy.domains: grimmory.int.krokantekrab.be
     npm.proxy.port: "6060"
     npm.proxy.ssl.certificate.id: "8"
   ```
   `npm.proxy.port` is the port the container listens on. Backend-only
   services get no labels.
   - A manually created NPM proxy host on the same domain blocks the sync
     (CONFLICT in its logs) — delete the manual host and restart
     `npm_docker_sync` to trigger a full rescan.
   - After changing labels, verify in `docker logs npm_docker_sync`
     that the host was created/updated; the sync can miss a plain container
     restart, and restarting the sync container forces a rescan.
   - The sync deletes and recreates a proxy host whenever its labeled
     container is recreated, so manual per-host NPM tweaks (advanced config)
     do not survive container recreation — don't build on them.
   - Manual NPM hosts for domains no label claims (`fotos.int`,
     `home.int`, `wairuha.int`) are deliberate routes to non-label-managed
     targets; don't remove them.
   - The *arr apps (Sonarr/Radarr/Prowlarr/Bazarr) enforce authentication for
     any request carrying an X-Forwarded-For header, even with
     `AuthenticationRequired: DisabledForLocalAddresses` — so they show a
     login screen when reached through NPM. That is intentional: don't strip
     the header at NPM and don't disable app authentication to work around
     it.
10. Services that run as a non-root user (UID/GID env vars, e.g.
    `HERMES_UID`) must have `appdata/<service>` owned by that UID/GID. A
    mismatch crash-loops the container with permission errors on start. Fix
    ownership with a throwaway root helper container (the host has no
    passwordless sudo):
    ```sh
    docker run --rm -v /opt/composition/appdata/<service>:/d \
      alpine chown -R <UID>:<GID> /d
    ```
11. No obsolete `version:` key in compose files.

## IP addressing

- macvlan network `services` on the LAN. Usable container range:
  `192.168.1.64/26` (`192.168.1.64`–`192.168.1.127`); host side is
  `192.168.1.10` (host-side setup and boot persistence are documented in
  `README.md`).
- Static IPs are assigned in the stack `.env`, never hardcoded in the compose
  file.
- Before adding a service with a static IP, grep the existing `.env` files and
  `README.md` for the address you plan to use. If it's taken or you're unsure
  which address to allocate, ask — don't guess into a running LAN.

## Validation before committing

Both must pass:

```sh
yamllint **/docker-compose.y*ml   # all YAML must pass with default rules
betterleaks                        # secret detection, including git history
```

If `betterleaks` flags a secret in committed files, the fix is rotating the
secret and removing it from history — not renaming the variable.

## Definition of an aligned stack

A stack is aligned only when all of these hold, checked in order:

```sh
yamllint <stack>/docker-compose.yml     # no errors (warnings acceptable)
docker compose -f <stack>/docker-compose.yml config --quiet
cd <stack> && docker compose up -d      # recreates cleanly
```

- `docker ps` shows every service healthy (or up, where the image offers no
  meaningful check) with stable uptime — no restart loops
  (`docker inspect -f '{{.RestartCount}}' <container>`).
- The healthcheck actually passes: `docker inspect <container>` `.State.Health`
  shows recent exit code 0 — "defined in the compose file" is not enough.
- Exposed services: `docker logs npm_docker_sync` shows the proxy host
  created for the `<route-name>.int.krokantekrab.be` domain.
- `betterleaks` is clean on the stack's committed files (`docker-compose.yml`,
  `.env.example`). The gitignored `.env` is expected to contain real secrets,
  so scan the committed files, not the whole directory.

Never assume image behavior (listen ports, endpoints, run-as user, ownership):
probe the running container first, then write it into the compose file.

## Migration status (as of 2026-10)

All stacks are aligned: `grimmory/`, `hermes/`, `immich/`, `homeassist/`,
`netbird/`, `npm/`, `vinyl/`, `media/`. When asked to fix a stack, bring it
into compliance with all rules above; don't leave half-migrated states.

When creating a new stack, copy the shape of `netbird/docker-compose.yml` and
add a `.env.example`.
