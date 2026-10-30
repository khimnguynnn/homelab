# Minecraft Java (Fabric) Server

A private, offline-mode Minecraft server running the **Prominence II: Hasturian Era**
modpack (**Fabric, Minecraft 1.20.1**), deployed via the
[`itzg/minecraft`](https://github.com/itzg/minecraft-server-charts) Helm chart and
managed by ArgoCD in this GitOps repo.

## 1. Architecture

```
ArgoCD (bootstrap root) ──► kubernetes/projects/minecraft.yaml
                              ├─ AppProject      "minecraft"
                              └─ ApplicationSet  "minecraft"  (globs apps/minecraft/*/config.json)
                                   └─ Application "minecraft"  (namespace: minecraft)
                                        └─ Helm umbrella chart  kubernetes/apps/minecraft/minecraft
                                             ├─ dep: itzg/minecraft 5.3.1
                                             └─ dep: external-secret-helper 0.1.2  (RCON Secret from Vault)

Workload (namespace: minecraft)
  Deployment minecraft (strategy: Recreate, replicas: 1)
    ├─ container minecraft     (itzg/minecraft-server:java21)  → PVC minecraft-datadir  (40Gi, /data)
    ├─ container mc-backup     (itzg/mc-backup)                → PVC minecraft-backupdir (25Gi, /backups)
    └─ container playit        (playit-agent)  public internet relay → 127.0.0.1:25565
  Service minecraft       LoadBalancer  TCP 25565   (LAN; externalTrafficPolicy: Local)
  Service minecraft-rcon  ClusterIP     TCP 25575   (internal only)
  Secret  minecraft-rcon   ← ExternalSecret ← Vault (secret/minecraft/minecraft)
  Secret  minecraft-playit ← ExternalSecret ← Vault (secret/minecraft/minecraft)
  NetworkPolicy           optional (disabled by default)

Public access: the playit.gg sidecar relays the internet to the server (no public IP /
port-forward, hides the home IP); the LoadBalancer Service is for LAN. See §6a.
```

- **Modpack:** [Prominence II: Hasturian Era](https://modrinth.com/modpack/prominence-2-fabric)
  from Modrinth, pinned to **v4.1.5hf** via `MODRINTH_MODPACK`. Fabric loader + the pack's
  full mod set install automatically on first boot (no CurseForge key needed).
- **Persistence:** world/mods/config on a 40Gi RWO PVC; backups on a separate 25Gi PVC.
  Both PVCs are annotated to survive ArgoCD prune **and** app deletion.
- **Backups:** daily, application-consistent (RCON `save-off`/`save-all`/`save-on`) via the
  chart's `mc-backup` sidecar — no custom CronJob.

## 2. Prerequisites

- ArgoCD running (bootstrap root Application syncs `kubernetes/projects/`).
- A **LoadBalancer implementation** that serves `type: LoadBalancer` Services on the
  cluster (MetalLB **or** Cilium LB-IPAM). ⚠️ This repo does **not** manage one; it must
  already exist. The Service stays `Pending` for an external IP otherwise.
- A **default StorageClass** supporting `ReadWriteOnce` (same assumption Grafana relies on).
  Pin a specific class with `minecraft.persistence.storageClass` if you don't want the default.
- **External Secrets + Vault** (already in this repo under `platform/`), and the RCON
  password seeded in Vault **before first sync**:

  ```bash
  vault kv put secret/minecraft/minecraft rcon-password="$(openssl rand -base64 24)"
  ```

  Without this, the `minecraft-rcon` Secret never materializes and the pod won't start.
- **Node RAM:** Prominence II wants a lot of memory. This deploy requests **7Gi** and caps
  at **10Gi** per pod, so a worker node needs ~10Gi free to schedule it (the two 14Gi
  workers can, but watch co-located workloads). Lower `minecraft.minecraftServer.memory` +
  `resources.limits.memory` together if a node can't spare it.

## 3. Deployment

Everything is declarative. Merge the files under
`kubernetes/apps/minecraft/` and `kubernetes/projects/minecraft.yaml` to the default
branch and ArgoCD does the rest.

```bash
# 1. Seed the RCON password in Vault (see Prerequisites).
# 2. Commit & push the new files (projects/minecraft.yaml + apps/minecraft/minecraft/).
# 3. ArgoCD picks up the new project + ApplicationSet automatically.
```

## 4. ArgoCD synchronization

```bash
argocd app list | grep minecraft
argocd app get minecraft
argocd app sync minecraft          # if auto-sync is lagging
argocd app wait minecraft --health
```

The ApplicationSet uses `prune: true, selfHeal: true`. World/backup PVCs are protected
per-resource (`argocd.argoproj.io/sync-options: Prune=false,Delete=false`), so sync/prune
never deletes world data.

## 5. Connect with PrismLauncher (offline)

This is a **modpack server**: every client must run the **same Prominence II: Hasturian Era
v4.1.5hf** pack — a vanilla or Fabric-only client **cannot** join.

1. In Prism: **Add Account → Offline**, pick a username.
2. Install the modpack as an instance (see §6).
3. The player's username must be on the whitelist (see §8) — the server is deny-by-default.
4. Find the server address:

   ```bash
   kubectl -n minecraft get svc minecraft -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```

   Add a server in-game pointing at `<EXTERNAL-IP>:25565` (or your public hostname, see §6a).

## 6. Installing the matching modpack on clients

Players must install **the exact same pack and version** (v4.1.5hf). Easiest routes:

- **Prism Launcher:** **Add Instance → Import → Import from Modrinth**, search
  "Prominence II", pick the **Hasturian Era** pack and version **4.1.5hf**. Prism installs
  Fabric 1.20.1 + all mods. Then set the offline account and connect.
- **Modrinth App:** search the pack → select version **4.1.5hf** → Install → Play.

Keep client and server on the **same pack version**. When you bump the server (§11), each
player re-imports the matching version, otherwise they'll be rejected on version mismatch.

## 6a. Public internet access (optional)

The game port is **raw TCP 25565 — not HTTP** — so the repo's `cloudflare-tunnel` Ingress
class **cannot** carry it (that class only proxies HTTP/S, which is why other apps use it).
A normal Prism/vanilla client can't reach the game through an HTTP tunnel. Pick one of:

- **Cloudflare Spectrum — paid (hostname + hides your IP).** Spectrum is **not on the Free
  plan**; Minecraft needs at least a **paid plan** (Pro/Business cover selected protocols,
  Enterprise covers arbitrary TCP). Create a Spectrum app (TCP, edge port 25565) whose origin
  is your public IP:25565 — which **still needs a router port-forward** to the LoadBalancer IP.
  Then harden by restricting `minecraft.minecraftServer.loadBalancerSourceRanges` to
  Cloudflare's published IP ranges so only Cloudflare can reach the origin.
- **Port-forward + Cloudflare DNS — free.** Forward your router's TCP 25565 → the Service's
  LoadBalancer IP, and add a **DNS-only (grey-cloud)** record, e.g. `A mc.0xk3m.dev → <public IP>`
  (optionally an `SRV _minecraft._tcp.mc.0xk3m.dev` record so players can omit the port).
  Simple, but exposes your home IP.
- **Client-side tunnel — free, less convenient.** Each player runs a cloudflared/Modflared
  connector; no port-forward, but everyone must install it.
- **VPN / LAN only — safest.** e.g. Tailscale; no public exposure at all.

Set a stable `minecraft.minecraftServer.loadBalancerIP` (from your LB pool) so the
port-forward / Spectrum origin target doesn't change.

⚠️ This is an offline-mode server — read §13 before exposing it to the internet.

## 7. Add / change mods

The mod set comes from the modpack. Two levers:

**Change the whole pack / version** — edit `minecraft.extraEnv.MODRINTH_MODPACK` in
`values.yaml` (and keep `minecraftServer.version` matching the pack's Minecraft version):

```yaml
minecraft:
  extraEnv:
    MODRINTH_MODPACK: "https://modrinth.com/modpack/prominence-2-fabric/version/<new-ver>"
```

**Add EXTRA mods on top of the pack** — add server-safe Modrinth slugs to
`minecraft.minecraftServer.modrinth.projects`:

```yaml
minecraft:
  minecraftServer:
    modrinth:
      projects:
        - <extra-server-safe-slug>
      downloadDependencies: required
```

Commit → ArgoCD syncs → pod restarts and re-syncs. **Any client-visible mod change must be
mirrored on every client** (§6), and **only add server-safe mods** — client-only mods crash
the server.

## 8. Whitelist management

Whitelist is **enabled and enforced** (deny-by-default via `ENABLE_WHITELIST` +
`ENFORCE_WHITELIST`). Two ways to manage it:

**Imperative (quick):**
```bash
POD=$(kubectl -n minecraft get pod -l app.kubernetes.io/name=minecraft -o name)
kubectl -n minecraft exec -it "$POD" -c minecraft -- rcon-cli whitelist add Alice
kubectl -n minecraft exec -it "$POD" -c minecraft -- rcon-cli whitelist list
kubectl -n minecraft exec -it "$POD" -c minecraft -- rcon-cli whitelist remove Alice
```

**Declarative (GitOps, git is source of truth):** set in `values.yaml` and add
`OVERRIDE_WHITELIST: "true"` under `minecraft.extraEnv`:
```yaml
minecraft:
  minecraftServer:
    whitelist: "Alice,Bob,Carol"
```
> ⚠️ Offline mode does **not** verify identity — the whitelist only filters by *claimed*
> username and does not stop impersonation. See §13.

## 9. Operator permissions (safely)

Ops are **not** granted automatically. Grant deliberately, to trusted players only:
```bash
kubectl -n minecraft exec -it "$POD" -c minecraft -- rcon-cli op Alice
kubectl -n minecraft exec -it "$POD" -c minecraft -- rcon-cli deop Alice
```
Or declaratively: `minecraft.minecraftServer.ops: "Alice"`. In offline mode, never op a
username you can't vouch for — anyone can claim it.

## 10. Backup & restore

Backups run every 24h to PVC `minecraft-backupdir` (`/backups/*.tgz`), pruned after 7 days,
plus a final backup on pod termination. Tune via `minecraft.mcbackup.*`
(`backupInterval`, `pruneBackupsDays`, `pauseIfNoPlayers`).

```bash
# List backups
kubectl -n minecraft exec "$POD" -c minecraft -- ls -lh /backups

# Trigger an on-demand backup
kubectl -n minecraft exec "$POD" -c <backup-container> -- backup now
#   (backup container name: kubectl -n minecraft get pod "$POD" -o jsonpath='{.spec.containers[*].name}')
```

**Restore:**
```bash
# 1. Scale down so nothing writes /data
kubectl -n minecraft scale deploy minecraft --replicas=0
# 2. Mount both PVCs in a throwaway pod and extract the chosen tgz over /data
#    (example: debug pod with datadir + backupdir mounted)
#    tar -C /data -xzf /backups/<world>-<timestamp>.tgz
# 3. Scale back up
kubectl -n minecraft scale deploy minecraft --replicas=1
```
> Backups are application-consistent (world is flushed via RCON before each backup) and
> autosave is re-enabled even if a backup step fails.

## 11. Upgrade the modpack / Minecraft / chart

- **Modpack version:** bump `minecraft.extraEnv.MODRINTH_MODPACK` to the new version-page URL,
  and set `minecraft.minecraftServer.version` to that version's Minecraft version. **Every
  client must re-import the matching pack version** (§6), or they'll be rejected.
- **Fabric loader:** installed by the pack; override only via `minecraftServer.fabricLoaderVersion`
  if a specific loader is required.
- **Helm chart:** bump the `minecraft` dependency version in `Chart.yaml`, then re-review this
  chart's rendered output for changed keys.
- **Always back up before upgrading** (`backup now`). World data persists across upgrades
  (the PVC is retained), but a major modpack/MC jump can still break an existing world — keep
  the backup.

## 12. Troubleshooting

```bash
kubectl -n minecraft get pods,svc,pvc,externalsecret
kubectl -n minecraft logs deploy/minecraft -c minecraft -f          # server log
kubectl -n minecraft logs deploy/minecraft -c <backup-container>     # backup log
kubectl -n minecraft describe pod -l app.kubernetes.io/name=minecraft
kubectl -n minecraft get svc minecraft -o wide                      # LoadBalancer IP
kubectl -n minecraft get externalsecret minecraft-rcon              # SecretSynced?
kubectl -n minecraft exec "$POD" -c minecraft -- rcon-cli list      # online players
```

Common issues:
- **Service EXTERNAL-IP `<pending>`** → no LB implementation / pool exhausted.
- **Pod `CreateContainerConfigError`** → `minecraft-rcon` Secret missing → seed Vault (§2).
- **Can't join / "You are not white-listed"** → add the username (§8).
- **Slow first boot** → the modpack is downloading/installing; `startupProbe` allows ~30 min.
- **Client rejected / version mismatch** → the client's pack version must match the server (§6).
- **OOMKilled / heavy GC lag** → raise `minecraftServer.memory` + `resources.limits.memory`
  together (if the node allows), or lower `viewDistance`/`SIMULATION_DISTANCE`.

## 13. Security considerations

- **Offline mode (`online-mode=false`, `enforce-secure-profile=false`) disables Mojang
  authentication.** Usernames are self-asserted and **can be impersonated**. The whitelist
  filters by claimed name only — it is *not* an identity control.
- **Exposing it publicly (§6a) raises the stakes.** Offline servers are constantly scanned
  and griefed. If you go public, at minimum:
  - Keep the whitelist enforced (already the default) and only op trusted players (§9).
  - Prefer Cloudflare Spectrum (hides your origin IP) and restrict
    `minecraft.minecraftServer.loadBalancerSourceRanges` to Cloudflare's IP ranges; for a
    direct port-forward, understand your home IP is exposed.
  - Optionally enable the bundled `networkPolicy` (`networkPolicy.enabled: true` +
    `networkPolicy.allowedCIDRs`) for pod-level ingress filtering (source-IP preservation is
    already on via `externalTrafficPolicy: Local`).
  - For LAN/VPN-only instead, set `loadBalancerSourceRanges` to your LAN/VPN CIDR(s) (e.g.
    use Tailscale).
- **RCON is internal only** (`ClusterIP`, never a LoadBalancer) with its password stored in
  Vault and delivered via an ExternalSecret — never committed to git.
- **Ops are not auto-granted.** Grant operator only to trusted players (§9).
- For stronger identity on offline servers, a verification/login mod can be added, but its
  compatibility with this pack (Fabric 1.20.1) must be verified before relying on it.
