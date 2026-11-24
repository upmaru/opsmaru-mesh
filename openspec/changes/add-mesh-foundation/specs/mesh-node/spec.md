# Spec Delta

## ADDED Requirements

### Requirement: Pure library boundary

Loading or starting `:opsmaru_mesh` MUST NOT start any process, listener, timer, table or backend connection, and the library SHALL define no application callback. Every call that reaches Incus SHALL take an `opsmaru_incus` client context from the caller. The library SHALL persist nothing. Allocations, node records, public keys, previous project values and apply results SHALL be returned to the caller.

#### Scenario: Loading the library

- **WHEN** a host starts the `:opsmaru_mesh` application
- **THEN** no process, ETS table or port is created by it

#### Scenario: Desired state without a backend

- **WHEN** `desired/2` is called with a node record and its mesh view
- **THEN** it returns the node's complete desired objects without any network call

### Requirement: Supported node preflight

Before changing a node, `apply/3` SHALL verify that the server is not clustered and reports a kernel of at least 5.6. It SHALL fail with a typed error, changing nothing, when any check fails. The library SHALL NOT require anything to be installed on the host.

#### Scenario: Clustered server

- **WHEN** the node reports `server_clustered: true`
- **THEN** apply returns `{:error, :clustered_server}` and makes no change

#### Scenario: Kernel without WireGuard

- **WHEN** the node reports kernel version 5.4
- **THEN** apply returns a typed error naming the kernel version and makes no change

### Requirement: Router instance per project per node

For each joined project on a node, the library SHALL keep a router container in the Opsmaru-owned `opsmaru-mesh` project, with `linux.kernel_modules=wireguard`, one NIC on the project's bridge at the node subnet's last host address with `ipv4.routes` set to the project block, one NIC on the node's transit bridge, and a custom storage volume mounted at `/var/lib/opsmaru-mesh` that holds its key and pushed configuration. The router SHALL forward only between its WireGuard interface and its project NIC, only for traffic whose source and destination are within the project block, and, when it is a relay, between WireGuard peers within the block. Its configuration SHALL be stored on that volume and re-applied at boot without the control plane.

#### Scenario: Router restart

- **WHEN** a router container restarts while Opsmaru is unreachable
- **THEN** it comes back with its WireGuard interface, peers and filtering rules, and same-project traffic across nodes resumes

#### Scenario: Foreign source at the router

- **WHEN** a packet whose source is outside the project block reaches the router's WireGuard interface
- **THEN** the router drops it

### Requirement: Pinned router image

Routers SHALL be created and rebuilt only from an image whose fingerprint equals the one pinned in the mesh configuration, which by default is the image built from the same release of this library. The image SHALL be delivered either by uploading host-supplied bytes through the Incus images API or by having Incus download it from a configured image server, and the library SHALL verify the fingerprint in the `opsmaru-mesh` project before any router is created or rebuilt from it. Routers MUST NOT be created from a mutable alias. An image upgrade SHALL rebuild routers one at a time and keep each router's state volume, so its WireGuard key and peers are unchanged.

#### Scenario: Fingerprint mismatch

- **WHEN** the image found on the node has a different fingerprint than the pinned one
- **THEN** apply stops at the image step with a typed error naming both fingerprints, and no router is created or rebuilt

#### Scenario: Offline host

- **WHEN** a node has no internet access and the host supplies the image bytes for upload
- **THEN** the image is imported through the Incus API and routers are created from it

#### Scenario: Image upgrade

- **WHEN** a new release pins a new fingerprint and apply runs on a node with two routers
- **THEN** the routers are rebuilt one after the other, and each returns the same public key as before

### Requirement: Node-local private keys

Each router's WireGuard private key SHALL be generated inside the router with owner-only permissions if absent. `apply/3` SHALL return only the derived public key, after checking that it is a single 32-byte base64 key. The library MUST NOT read, push, log, return or embed a private key in any request, result, error or pushed file.

#### Scenario: First apply

- **WHEN** a router is created and its key exec runs
- **THEN** the result contains its public key, and no request or result contains the private key

#### Scenario: Re-apply

- **WHEN** apply runs again on a router whose key file exists
- **THEN** the same public key is returned and the key file is not replaced

### Requirement: Peering by reachability

Each node SHALL be declared `reachable`, with a host-supplied public address, or `outbound_only`. A `reachable` node SHALL have one network forward on its transit bridge, mapping one UDP port per joined project to that project's router. A router SHALL peer with every `reachable` node's router of the same project and, when it is itself `reachable`, with every `outbound_only` router of the project. `outbound_only` routers SHALL send keepalives. Traffic between two `outbound_only` nodes SHALL use the project's relay, the lowest-ID `reachable` node running the project. When a project has no such node, the pair SHALL be reported as unreachable rather than given a path.

#### Scenario: Two NATed Macus hosts and one server

- **WHEN** project `A` runs on `outbound_only` nodes 2 and 3 and on `reachable` node 1
- **THEN** routers 2 and 3 peer with router 1, router 1 relays between them, and no router peers with a router of another project

#### Scenario: Only NATed nodes

- **WHEN** project `A` runs only on `outbound_only` nodes 2 and 3
- **THEN** the desired state reports the pair (2, 3) as unreachable for `A`

### Requirement: Ownership and removal

The library SHALL mark every object it creates with `user.opsmaru.mesh.managed=true` and MUST NOT modify or delete any object without that marker, other than the keys it owns on a joined project and that project's default profile. `remove/3` SHALL remove a project's or node's mesh objects in the reverse of apply order, restore the project keys from values supplied by the host, and refuse to delete a bridge that still has attached instances.

#### Scenario: Pre-existing network named like a mesh bridge

- **WHEN** a node already has a network `om0003` without the ownership marker
- **THEN** apply fails naming it, and the network is not changed

#### Scenario: Project leaves the mesh

- **WHEN** the host removes project `A` from a node with no attached tenant instances
- **THEN** the default-profile NIC, the forward port, the router, its state volume (destroying its key), the bridge and the ACL are removed in that order, and only then are `A`'s restriction keys restored from their supplied previous values, subject to the project-isolation rule against access to remaining mesh bridges

### Requirement: Peer status without secrets

`status/2` SHALL report, for each router on a node and each of its peers, the peer's public key, the time of its last WireGuard handshake or `:never`, the bytes received and sent, and the last seen endpoint. It SHALL obtain them only through read-only `exec` of `wg show wg0 latest-handshakes`, `wg show wg0 transfer` and `wg show wg0 endpoints`, and it MUST NOT run any command that prints a private key, including `wg show` with no arguments, `wg show wg0 dump` and `wg showconf`. `status/2` MUST NOT change any object.

#### Scenario: Closed UDP port

- **WHEN** a reachable node's WireGuard port is blocked by a cloud firewall
- **THEN** its peers report `:never` for that node's router, and the result carries the node's public address and port so the host can point at the cause

#### Scenario: Healthy peer

- **WHEN** two routers of the same project have exchanged traffic
- **THEN** each reports the other's last handshake time and non-zero transfer counts

#### Scenario: No secret in status

- **WHEN** `status/2` runs on a node
- **THEN** no request, response or result contains a private key
