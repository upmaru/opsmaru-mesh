# Proposal

## Why

Instances on different Incus hosts registered in Opsmaru cannot reach each other unless an operator builds the network by hand. Incus's built-in answer, OVN, is too heavy for small fleets and for Macus hosts behind NAT. Opsmaru already knows every registered host and its tenants, which makes it the natural authority for addressing and isolation. This change defines the foundation: an Incus project's instances can reach each other across all registered nodes, and nothing else can reach them.

## What Changes

- **Project-isolated mesh.** Each Incus project joined to the mesh gets its own bridge on every node it runs on, its own address range, and cross-node reachability over WireGuard. Projects can't reach each other's instances, on the same node or across nodes.
- **Control plane only.** The library computes what each node should have (bridges, project restrictions, ACLs, router instance, peers) and applies it through `opsmaru_incus`. Traffic flows node to node. An applied node keeps forwarding when Opsmaru is unavailable.
- **No host agent.** Everything is created through the Incus API: bridges, network ACLs, a network forward, project restrictions and one router container per project per node. The router generates its own WireGuard key; only the public key leaves the node.
- **Deterministic addressing.** A pure allocator assigns each project a block of a host-configured mesh range and each project/node pair a subnet from that block. Allocation is a pure function of the existing allocations, which the host persists.
- **Safe apply.** Isolation is put in place before a project can attach to its bridge. A failed or partial apply never widens access. The library never touches resources it didn't create, including `incusbr0` and the `default` project's existing resources.
- **NAT-aware peering.** Nodes are declared `reachable` (accepts inbound WireGuard) or `outbound_only` (behind NAT, such as Macus). Two `outbound_only` nodes reach each other through a reachable relay node's router for the same project.
- **Standalone Incus servers only.** Incus clusters are rejected with a clear error in this change; see design.md.

## Capabilities

### New Capabilities

- `mesh-addressing`: the mesh range, per-project blocks, per-node subnets and collision avoidance.
- `project-isolation`: what separates projects on one node and across nodes, and the invariants an apply must keep.
- `mesh-node`: registering a node, its desired state, the router instance and its key, peering, applying and removing a node.

### Modified Capabilities

None.

## Impact

- **New library surface:** `Opsmaru.Mesh` with pure allocation, desired-state and peer-config functions, and an apply/removal entry point that takes an `opsmaru_incus` client context from the host. No processes, storage or schedules.
- **Dependency:** `{:opsmaru_incus, "~> 0.2.9"}`. If the typed client lacks a needed endpoint (network forwards, ACLs, file push or exec), that gap is filled in opsmaru-incus first, with coverage evidence there, not worked around here.
- **Central Opsmaru (follow-up change there):** persists allocations, node records and public keys; calls apply on registration, project join and peer change; shows mesh status. Not part of this repository.
- **Incus hosts:** need the nftables firewall driver and the WireGuard kernel module (Linux 5.6+). Joining a project to the mesh sets `restricted=true` on it, which changes defaults for unrelated `restricted.*` keys; design.md says how that is handled.
- **Evidence:** pure unit tests and recorded Incus fixtures in this change. Real-Incus acceptance on an isolated host is a separate, explicitly opted-in task. Macus hardware acceptance belongs to Macus.
