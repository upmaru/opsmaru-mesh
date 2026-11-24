# Design

## Context

See [proposal.md](proposal.md). Central Opsmaru registers Incus servers and calls them through `opsmaru_incus`. It can't run commands on a host or install software there. Everything the mesh needs must therefore be expressible as Incus API objects, plus `exec` and file push into an instance the mesh owns.

Constraints checked against Incus v7.0.1 (source at `github.com/lxc/incus/v7@v7.0.1`):

| Constraint | Where |
| --- | --- |
| Only OVN networks can be created in a project with `features.networks=true`; any other type fails with "Network type does not support non-default projects". | `cmd/incusd/networks.go:409-432` |
| In a cluster, a network's `ipv4.address` is global. The only member-specific keys are `bgp.ipv4.nexthop`, `bgp.ipv6.nexthop`, `bridge.external_interfaces`, `parent`, `tunnel.*.interface` and `tunnel.*.local`. | `internal/server/db/networks.go:892-901` |
| Bridge ACLs apply only at the bridge/host boundary, not between instances on the same bridge (unless set on each NIC). Selectors and groups are not supported on bridges. | `doc/howto/network_acls.md` "Bridge limitations" |
| ACL rules are ordered by action: `drop`, `reject`, `allow`, then the default action (`reject` unless set). The first match wins. | `doc/howto/network_acls.md` "Rule ordering and priorities" |
| Bridge firewall rules accept `ct state established,related`. | `internal/server/firewall/drivers/drivers_nftables_templates.go` |
| Network address sets and bridge network forwards with `snat` need the nftables driver. | `doc/howto/network_address_sets.md`, `doc/howto/network_forwards.md` |
| A forward's listen address may not overlap any address used by another network or forward. Two bridges can't each forward the same host address. | `internal/server/network/driver_bridge.go:2779-2794` |
| A forward's port targets must be inside the forward's own network subnet. | `doc/howto/network_forwards.md` "Configure ports" |
| `restricted.*` keys only take effect when `restricted=true`, which also turns on blocking defaults for every other `restricted.*` key (backups, snapshots, privileged containers, disk devices, …). | `doc/config_options.txt` project-restricted group |
| A bridged NIC's `ipv4.routes` adds host routes to that NIC. No project restriction covers it. | `internal/server/device/nic_bridged.go:836-842`; no reference in `internal/server/project/permissions.go` |
| ACL objects accept only `user.*` config keys. | `doc/howto/network_acls.md` |

## Goals / Non-Goals

**Goals:**
- Instances in one Incus project can reach each other across every registered node.
- No other project's instances, and no other mesh traffic, can reach them, on one node or across nodes.
- The control plane is not on the data path. An applied node keeps forwarding through a control-plane outage, a router restart and a host reboot.
- No host agent, and no private key ever leaves its node.
- Every operation is computed as a pure function and is safe to re-apply.

**Non-Goals:**
- Policy finer than "same project" (tags, ports, services): a later change.
- Identity-bound policy, user/device access, SSO, DNS names, flow logs: later changes. No "zero trust" claim until then.
- IPv6 inside the mesh: project bridges are IPv4 only in this change. IPv6 underlay endpoints are allowed.
- Incus clusters (see decision 9).
- Persistence, scheduling, retries, UI: central Opsmaru owns these.

## Decisions

### 1. Pure library with an explicit apply step

`Opsmaru.Mesh` exposes three kinds of function:

- **Allocation**, pure: `allocate_project/2` and `allocate_node_subnet/3` take the mesh configuration and the existing allocations and return a new allocation or a typed error.
- **Desired state**, pure: `desired/2` takes one node record and the mesh view relevant to it (its joined projects, their allocations and the peer records) and returns the complete list of Incus objects that node should have.
- **Apply / remove**: `apply/3` and `remove/3` take an `opsmaru_incus` client context supplied by the host, read the node's current objects, and converge them on the desired state. They return a per-step result, and any newly learned public keys, for the host to persist.

The library never stores, schedules or retries anything. When a project joins or a node's peers change, central Opsmaru calls `apply/3` for each affected node.

### 2. One bridge per project per node, in the `default` project

A tenant project can't own a bridge, because of the OVN-only constraint above. Each joined project `P` therefore gets a bridge in the `default` project on every node it uses:

- **Name:** `om` plus the project block index as 4 hex digits, e.g. `om0003`. Linux interface names are limited to 15 characters and project names can be longer, so the name comes from the allocation, not the project name.
- **Config:** `ipv4.address` = first host of the node subnet, `ipv4.nat=true`, `ipv6.address=none`, `bridge.mtu` = mesh MTU (decision 8), `security.acls=om0003-isolation`, plus `user.opsmaru.mesh.*` ownership markers.
- **Project lock:** `restricted=true`, `restricted.devices.nic=managed`, `restricted.networks.access=om0003`. The project keeps `features.networks=false` so it can see `default`-project networks. The restriction limits it to its own bridge.
- **Default profile:** the project's `default` profile gets an `eth0` NIC on its bridge.

Joining a project is refused if any instance in it has a NIC on another network. The error lists those instances so the host can decide; the library never moves them.

**Other projects on the node.** Incus limits network access only from the project side. A project with `restricted=false`, or with `restricted.networks.access` unset, can attach a NIC to *any* `default`-project network, including another project's mesh bridge. Such a NIC would get an address on that bridge and could reach that project's instances on that node with no filtering. Therefore:

- **Trust boundary:** users of the `default` project already administer the node (they can create bridges), so they are trusted. Mesh bridges don't defend against them.
- **Preflight check:** every other project on the node, except `opsmaru-mesh`, must have `restricted=true` and a `restricted.networks.access` list that names no mesh bridge other than its own. While any project fails this, `apply/3` refuses to create or attach a project bridge and names the offending projects. The host fixes them, for example by restricting them to their current networks.
- **Re-checked every apply:** drift is reported, and nothing new is attached until it's fixed.
- **Removal:** `remove/3` never restores a previous restriction value that would give the leaving project access to a remaining mesh bridge. In that case it keeps the network restriction and reports it.

### 3. Isolation is a static complement, enforced at the bridge boundary

Each project gets an ACL `om<idx>-isolation`. Its rules depend only on the mesh range and that project's block, so adding another project never requires an update:

- **Egress:** `reject` destinations in `C(P)`; `allow` everything else.
- **Ingress:** `reject` sources in `C(P)`; `allow` everything else.

Here `C(P)` is the mesh range minus the project's block, written as a minimal list of CIDRs (a /16 block inside a /9 range gives 7 CIDRs), plus the transit range. Because `reject` is ordered before `allow`, no other rule can override it. The default actions stay `reject`.

The ACL is created before the bridge and attached in the bridge's create request, so the bridge never exists without it. It is updated with a full-rule PUT carrying the ETag it was read with, and is never deleted while a bridge references it.

What this blocks:

- **A project's instance sending to another project's subnet on the same node:** rejected on egress at its own bridge.
- **The same, sending to another project on a remote node:** the destination is in `C(P)`, so it's rejected before routing.
- **Traffic that reaches a project bridge from the host with a foreign mesh source:** rejected on ingress.

Instances in the same project, on the same bridge, are not filtered. That is intended.

### 4. One router container per project per node

The router for project `P` on node `N` is a container `om<idx>` in an Opsmaru-owned project `opsmaru-mesh`. Tenants have no access to that project. It has:

- **`eth0` on the project bridge:** static `ipv4.address` = last host of the node subnet, and `ipv4.routes` = the project block. The host therefore routes the project's remote subnets to the router. The node's own subnet is directly connected and wins by longest-prefix match.
- **`eth1` on the node's transit bridge** (decision 6), used only for WireGuard UDP.
- **Inside:** a WireGuard interface `wg0` (MTU from decision 8), and nftables rules that forward only between `wg0` and `eth0`, only for traffic whose source and destination are both in the project block, and between peers on `wg0` when the router is a relay (decision 7). All other forwarding is dropped. `eth1` accepts only the project's WireGuard port.

The router's `eth0` has no `security.ipv4_filtering`, because it legitimately forwards remote sources. Its integrity rests on living in an Opsmaru-owned project.

One router per project, rather than one router per node with VRFs, means a single router never holds two projects' plaintext. Isolation then follows from how the routers are built, not from rules that must stay correct. The cost is one small container per project per node.

**Image:** the host supplies an image source and alias in the mesh configuration. The image must provide `ip`, `wg` and `nft`. The library ships the boot script and documents the requirements but does not choose or download an image.

**Boot persistence:** the library pushes an idempotent init script plus config files (`/etc/opsmaru-mesh/peers.conf`, `/etc/opsmaru-mesh/rules.nft`). The router re-applies them at every boot, so a router or host restart needs no control plane.

### 5. Keys are generated on the router

`apply/3` runs one `exec` in the router. It creates `/etc/opsmaru-mesh/private.key` with `umask 077` if the file is missing, then prints only the derived public key. The library checks the output is exactly one 32-byte base64 key and returns it for the host to store. The private key is never read, pushed, logged or returned. Pushed peer files hold public keys, endpoints and allowed IPs only, and the private key is loaded with `wg set wg0 private-key`.

Rotating a key means removing the file, re-running apply, and re-applying the router's peers.

### 6. Transit bridge and one forward per reachable node

Two bridges can't forward the same host address. So each node has a single transit bridge `omtransit`, using the reserved transit range. It's the same small subnet on every node and is never routed between nodes. On a `reachable` node, `apply/3` keeps one network forward on `omtransit`:

- its listen address is the node's public address, supplied by the host;
- it has one UDP port per project, mapped to that project's router `eth1` address.

The port is `wireguard_base_port + project block index`.

An `outbound_only` node gets no forward. Its routers connect out through the transit bridge's NAT with `PersistentKeepalive = 25`.

### 7. Peering and relays

For project `P`, a router peers with:

- every `reachable` node's `P` router, with endpoint `public address:port` and allowed IPs = that node's `P` subnet;
- if it is `reachable` itself, every `outbound_only` node's `P` router, with no endpoint (they connect in), and allowed IPs = that node's subnet.

Two `outbound_only` nodes can't connect directly. The relay for `P` is the `reachable` node running `P` with the lowest node ID:

- Each `outbound_only` router adds the other `outbound_only` nodes' subnets to its relay peer's allowed IPs.
- The relay forwards `wg0`↔`wg0` only within the project block.

If a project has two or more `outbound_only` nodes and no `reachable` node, the library reports those pairs as `unreachable` in the desired state instead of inventing a path. The relay decrypts the project's traffic, but it is the same project's own router.

### 8. Addressing

The host supplies:
- the mesh range (e.g. `10.128.0.0/9`);
- the project block prefix (default /16);
- the node subnet prefix (default /24);
- the MTU (default 1420; hosts nested behind extra encapsulation, such as Macus, may need less).

Block index 0 is reserved: its first node-sized subnet is the transit range. Allocation takes the lowest free index and is deterministic for a given set of existing allocations.

Before the first apply on a node, the library reads the addresses of every network on that node (`GET /1.0/networks` and `/state`). If any address overlaps the mesh range, joining the node fails with a typed error naming the network. The library never renumbers anything.

### 9. Clusters are rejected in this change

A cluster's bridge has one subnet across all members, so the per-node subnet model doesn't fit. The options are:

- (a) treat the whole cluster as one mesh node, with a single router and a subnet shared through Incus's own bridge tunnels (`tunnel.*`), DHCP on one member only;
- (b) create a separate bridge per member, unused elsewhere.

This needs real-cluster evidence. In this change, `apply/3` returns `{:error, :clustered_server}` when `environment.server_clustered` is true.

### 10. Apply order and failure

Steps, each idempotent and each only after the previous one succeeded:

1. preflight (not clustered, nftables firewall, kernel ≥ 5.6, no address overlap, every other non-`default` project restricted away from mesh bridges);
2. isolation ACL;
3. project bridge with the ACL attached;
4. transit bridge;
5. `opsmaru-mesh` project and router instance;
6. key exec;
7. router config push and reload;
8. network forward (reachable nodes);
9. project restrictions;
10. default-profile NIC.

From step 3 on, the bridge is always isolated. Until step 10, no tenant instance is attached to it by default. Stopping at any step therefore leaves access the same as or narrower than the final state. A failure stops the run and reports the step, and the next run resumes. Mutations are never retried inside one run. A write that may have been accepted is re-read on the next run, not replayed (matching `opsmaru_incus` semantics).

The library touches only objects that carry `user.opsmaru.mesh.managed=true`, plus the keys it owns on a joined project and its default profile. For those, it returns the previous values so the host can store them, and `remove/3` restores them.

Turning on `restricted=true` blocks other features by default (backups, snapshots, privileged containers and so on). By default, `apply/3` sets every other `restricted.*` key the project hasn't set to its permissive value, so joining the mesh changes only network access. A host may pass its own stricter values instead.

## Risks / Trade-offs

- **Tenant NIC host routes.** A tenant can set `ipv4.routes` on its own NIC, adding a host route that draws another project's mesh traffic toward its bridge. That project's ingress rule (decision 3) rejects the traffic, so it's not readable, but it's lost: an availability risk across projects. → `apply/3` reports any NIC in a joined project whose `ipv4.routes` or `ipv4.routes.external` overlaps the mesh range, and the risk is recorded for an upstream Incus restriction request. Real-Incus acceptance must demonstrate both the rejection and the detection.
- **Hairpin through the host.** Traffic leaving a node goes instance → host → router on the same bridge. That's one extra hop, and it keeps the bridge ACL as the single enforcement point for egress.
- **One container per project per node.** Simple isolation, but container count grows with projects × nodes. Acceptable for this change's target scale. A future change could consolidate if evidence demands it.
- **Relay load.** The lowest-ID reachable node carries relayed traffic for each project with several NATed nodes. A later change could pick relays by capacity.
- **Restricted-project defaults.** Keeping the project's prior behaviour by default could hide that `restricted=true` is now set. → `apply/3` reports the keys it set, and the host shows them.

## Open Questions

1. Should the router image be a published Opsmaru image, or a stock distribution image plus packages installed by `exec` at creation? (This change: host-supplied, requirements documented.)
2. Should a cluster be one mesh node (option 9a) or per-member bridges (9b)?
3. Should the transit range, the port base and the reserved index be configurable per host, or fixed for the whole mesh?
4. Should Opsmaru ask Incus upstream for a project restriction on NIC `ipv4.routes`?
