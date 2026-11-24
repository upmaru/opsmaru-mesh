# Spec Delta

## ADDED Requirements

### Requirement: Project-scoped reachability

Instances in a joined Incus project SHALL be able to reach instances of the same project on every node where that project is joined and has a working path. Traffic between two different joined projects MUST be rejected, whether they are on the same node or on different nodes, and so MUST traffic from a joined project to the mesh's transit range.

#### Scenario: Same project across nodes

- **WHEN** an instance of project `A` on node 1 connects to an instance of project `A` on node 2
- **THEN** the connection succeeds over WireGuard between the two nodes' project `A` routers, without passing through Opsmaru

#### Scenario: Different projects on one node

- **WHEN** an instance of project `A` sends to an instance of project `B` on the same node
- **THEN** the packet is rejected by project `A`'s isolation ACL

#### Scenario: Different projects across nodes

- **WHEN** an instance of project `A` sends to an address in project `B`'s block on another node
- **THEN** the packet is rejected at project `A`'s bridge and never reaches any router

### Requirement: Static isolation rules

Each joined project SHALL have one isolation ACL. It rejects egress to, and ingress from, the mesh range minus the project's own block, plus the transit range, and it allows all other traffic. The rejected set SHALL be expressed as a minimal CIDR list that depends only on the mesh configuration and the project's block, so adding or removing other projects never changes it. The ACL's default actions SHALL remain `reject`.

#### Scenario: Another project joins

- **WHEN** project `C` joins a mesh in which projects `A` and `B` are already applied
- **THEN** the isolation ACLs of `A` and `B` are unchanged

#### Scenario: Complement size

- **WHEN** the mesh range is a /9 and blocks are /16
- **THEN** a project's rejected set has seven CIDRs from the mesh range, plus the transit range

### Requirement: Project lock to its bridge

When a project joins, the library SHALL set `restricted=true`, `restricted.devices.nic=managed` and `restricted.networks.access` to exactly that project's mesh bridge, keep `features.networks=false`, and set every other unset `restricted.*` key to its permissive value unless the host supplies different values. It SHALL return the previous value of every key it changes, for the host to persist and restore. Joining SHALL be refused, with the offending instances listed, if any instance in the project has a NIC on a network other than its mesh bridge.

#### Scenario: Instance on the default bridge

- **WHEN** a project has an instance with a NIC on `incusbr0` and the host asks to join it
- **THEN** the join fails listing that instance, and no project key is changed

#### Scenario: Attaching another project's bridge

- **WHEN** a joined project's user adds a NIC on another project's mesh bridge
- **THEN** Incus refuses the device because of the project's network restriction

#### Scenario: Unrelated features preserved

- **WHEN** a project that previously allowed snapshots and backups joins with no host-supplied restrictions
- **THEN** snapshots and backups remain allowed after the join, and the result lists every restriction key that was set

### Requirement: No unrestricted access to mesh bridges

Before creating or attaching any project bridge on a node, and on every apply, the library SHALL verify that every project on that node other than `default` and `opsmaru-mesh` has `restricted=true` and a `restricted.networks.access` list that names no mesh bridge other than its own. While any project fails the check, `apply/3` SHALL refuse to create or attach a project bridge and SHALL name the offending projects. The library MUST NOT change the configuration of a project that is not joined. `default`-project users are node administrators and are outside this guarantee.

#### Scenario: Unrestricted tenant project on the node

- **WHEN** a node has a project `X` that is not joined and has `restricted=false`
- **THEN** applying project `A` to that node fails naming `X`, and no mesh bridge is created

#### Scenario: Drift after apply

- **WHEN** a project's restriction is later removed by someone other than the library
- **THEN** the next apply reports that project and attaches nothing new until it is restricted again

#### Scenario: Leaving with an unrestricted previous state

- **WHEN** project `A` leaves the mesh, its stored previous values had `restricted=false`, and other mesh bridges remain on the node
- **THEN** `remove/3` keeps `A`'s network restriction, excluding the remaining mesh bridges, and reports that it did so

### Requirement: Isolation never widens on failure

An apply SHALL create a project's isolation ACL before its bridge and attach it in the bridge's create request. It MUST NOT detach or delete an ACL while a bridge references it, MUST NOT attach a project's instances by default before the project's restrictions are in place, and MUST stop at the first failed step. At every point during or after an interrupted apply, access MUST be no wider than in the fully applied state.

#### Scenario: Failure after the bridge exists

- **WHEN** an apply fails while creating the router instance
- **THEN** the project's bridge exists with its isolation ACL attached, no default-profile NIC has been added, and the result names the failed step

#### Scenario: ACL rule update race

- **WHEN** an ACL changed since it was read and the update's ETag no longer matches
- **THEN** the update is refused, the ACL stays as it was, and the result reports the conflict

### Requirement: Route hijack detection

On every apply, the library SHALL report each NIC in a joined project whose `ipv4.routes` or `ipv4.routes.external` overlaps the mesh range. The library MUST NOT modify tenant instance devices.

#### Scenario: Tenant adds a mesh route

- **WHEN** an instance in project `A` has a NIC with `ipv4.routes` set to a subnet inside project `B`'s block
- **THEN** the apply result reports that instance and NIC, and project `B`'s ingress rule rejects any of `B`'s traffic routed to `A`'s bridge
