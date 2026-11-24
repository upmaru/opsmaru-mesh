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

Before changing a node, `apply/3` SHALL verify that the server is not clustered, uses the nftables firewall driver and reports a kernel of at least 5.6. It SHALL fail with a typed error, changing nothing, when any check fails.

#### Scenario: Clustered server

- **WHEN** the node reports `server_clustered: true`
- **THEN** apply returns `{:error, :clustered_server}` and makes no change

#### Scenario: xtables firewall

- **WHEN** the node reports a firewall driver other than nftables
- **THEN** apply returns a typed error naming the firewall driver and makes no change

### Requirement: Router instance per project per node

For each joined project on a node, the library SHALL keep a router container in the Opsmaru-owned `opsmaru-mesh` project, with one NIC on the project's bridge at the node subnet's last host address with `ipv4.routes` set to the project block, and one NIC on the node's transit bridge. The router SHALL forward only between its WireGuard interface and its project NIC, only for traffic whose source and destination are within the project block, and, when it is a relay, between WireGuard peers within the block. Its configuration SHALL be stored inside the router and re-applied at boot without the control plane.

#### Scenario: Router restart

- **WHEN** a router container restarts while Opsmaru is unreachable
- **THEN** it comes back with its WireGuard interface, peers and filtering rules, and same-project traffic across nodes resumes

#### Scenario: Foreign source at the router

- **WHEN** a packet whose source is outside the project block reaches the router's WireGuard interface
- **THEN** the router drops it

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
- **THEN** the default-profile NIC, the forward port, the router, the bridge and the ACL are removed in that order, and only then are `A`'s restriction keys restored from their supplied previous values, subject to the project-isolation rule against access to remaining mesh bridges
