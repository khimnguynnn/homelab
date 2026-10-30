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
  Service minecraft       ClusterIP     TCP 25565   (in-cluster; playit reaches it via localhost)
  Service minecraft-rcon  ClusterIP     TCP 25575   (internal only)
  Secret  minecraft-rcon   ← ExternalSecret ← Vault (secret/minecraft/minecraft)
  Secret  minecraft-playit ← ExternalSecret ← Vault (secret/minecraft/minecraft)
  NetworkPolicy           optional (disabled by default)

Public access: the playit.gg sidecar relays the internet to the server (no public IP /
port-forward, hides the home IP). No LoadBalancer is used. See §6a.
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
- No LoadBalancer is required — the Service is `ClusterIP` and public access goes through the
  playit.gg sidecar (§6a). (For LAN-direct play instead, switch `serviceType` back to
  `LoadBalancer` and you'll then need MetalLB/Cilium LB-IPAM.)
- A **default StorageClass** supporting `ReadWriteOnce` (same assumption Grafana relies on).
  Pin a specific class with `minecraft.persistence.storageClass` if you don't want the default.
- **External Secrets + Vault** (already in this repo under `platform/`). Seed both keys in
  Vault **before first sync** (same KV path, so use `put` then `patch`):

  ```bash
  vault kv put   secret/minecraft/minecraft rcon-password="$(openssl rand -base64 24)"
  vault kv patch secret/minecraft/minecraft playit-secret-key="<from playit.gg, see §6a>"
  ```

  Without the RCON key the pod won't start; without the playit key the `playit` sidecar
  crash-loops (the rest of the server still runs). Both are internal-only Secrets, never in git.
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
4. Connect to the **playit address** (or your `mc.<domain>` hostname) — see §6a. The Service
   is `ClusterIP`, so there's no LAN LoadBalancer IP; everyone reaches it through playit.
   (Admins can also `kubectl -n minecraft port-forward svc/minecraft 25565:25565` for a quick
   local connection.)

## 6. Installing the matching modpack on clients

Players must install **the exact same pack and version** (v4.1.5hf). Easiest routes:

- **Prism Launcher:** **Add Instance → Import → Import from Modrinth**, search
  "Prominence II", pick the **Hasturian Era** pack and version **4.1.5hf**. Prism installs
  Fabric 1.20.1 + all mods. Then set the offline account and connect.
- **Modrinth App:** search the pack → select version **4.1.5hf** → Install → Play.

Keep client and server on the **same pack version**. When you bump the server (§11), each
player re-imports the matching version, otherwise they'll be rejected on version mismatch.

## 6a. Public internet access — playit.gg (configured)

The game port is **raw TCP 25565 — not HTTP** — so the repo's `cloudflare-tunnel` Ingress
class **cannot** carry it, and Cloudflare Spectrum (the TCP option) is **not free**. This
deploy therefore ships a **playit.gg** agent as a sidecar: a free TCP relay that publishes
the server to the internet with **no public IP, no port-forward**, hiding your home IP and
working even behind CG-NAT. The LoadBalancer Service stays for LAN play.

**One-time activation (the manifests are already in place):**

1. Create a free account at <https://playit.gg> and add an **agent**, copying its
   **secret key** (Account → Agents, or run the agent once locally to claim it).
2. Seed it in Vault (same KV path as RCON):

   ```bash
   vault kv patch secret/minecraft/minecraft playit-secret-key='<secret-key>'
   ```

   The `minecraft-playit` ExternalSecret → `minecraft-playit` Secret → the `playit` sidecar.
3. In the playit dashboard, create a **Minecraft Java** tunnel. Leave the local address at
   the default **127.0.0.1:25565** (the sidecar shares the pod's network, so this reaches the
   server). playit assigns a public address — note its **host and port**.
4. Attach your own domain with an **SRV record** (Cloudflare, DNS-only) so players connect via
   your hostname:

   ```
   Type:     SRV
   Name:     _minecraft._tcp.mc        (i.e. _minecraft._tcp.mc.<your-domain>)
   Service:  _minecraft    Protocol: _tcp
   Priority: 0   Weight: 5   Port: <playit port>   Target: <playit host>
   ```

   Players then join with just `mc.<your-domain>` (the SRV carries the non-standard port).

**Verify / operate:**
```bash
kubectl -n minecraft logs deploy/minecraft -c playit    # agent status / tunnel address
```
If the sidecar crash-loops, the secret key is missing/invalid — recheck step 2. The rest of
the server keeps running regardless.

⚠️ This is an offline-mode server now reachable from the internet — the whitelist stays
deny-by-default, but read §13 before and after going public.

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
kubectl -n minecraft get externalsecret                             # both SecretSynced?
kubectl -n minecraft logs deploy/minecraft -c playit                # playit tunnel/address
kubectl -n minecraft exec "$POD" -c minecraft -- rcon-cli list      # online players
```

Common issues:
- **Server exits with "Incompatible mods found! … requires X"** → the modpack's server install
  is missing a library. Add that mod's Modrinth slug to `minecraftServer.modrinth.projects`
  (e.g. `athena-ctm` is already added for Chipped) and re-sync. Repeat if a new one is reported.
- **`playit` sidecar `Failed to bind to socket`** → it needs a writable `/run/playit`
  (mounted via `extraVolumes`); already configured.
- **`playit` sidecar CrashLoopBackOff** → missing/invalid `playit-secret-key` in Vault (§6a).
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
- **It is now reachable from the internet via playit (§6a).** Offline servers are constantly
  scanned and griefed, so:
  - The whitelist stays enforced (deny-by-default) and only trusted players are op'd (§9) —
    this is the main control, since playit forwards all public traffic to the server.
  - playit already **hides your home IP** (players see playit's relay) and no router port is
    opened — a real advantage over a direct port-forward.
  - The Service is `ClusterIP` (no LoadBalancer door); the only public path is the playit
    sidecar. The optional `networkPolicy` does not block that sidecar (it egresses out), so
    keep relying on the whitelist.
  - To stop public access entirely, remove the `playit` sidecar (and `extraVolumes`) — the
    server then stays reachable only in-cluster / via `kubectl port-forward`.
- **RCON is internal only** (`ClusterIP`, never a LoadBalancer) with its password stored in
  Vault and delivered via an ExternalSecret — never committed to git.
- **Ops are not auto-granted.** Grant operator only to trusted players (§9).
- For stronger identity on offline servers, a verification/login mod can be added, but its
  compatibility with this pack (Fabric 1.20.1) must be verified before relying on it.
