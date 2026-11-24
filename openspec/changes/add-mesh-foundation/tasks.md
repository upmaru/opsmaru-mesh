# Tasks

Evidence levels are distinct: **unit** (pure functions, no I/O), **fixture** (recorded Incus v7.0.1 responses served to `opsmaru_incus`), and **acceptance** (a real, isolated Incus host, explicitly opted in). A task closes only on the evidence it names.

## 1. Client prerequisites

- [ ] 1.1 Check that `opsmaru_incus` can do everything the mesh needs, with ETags and typed errors:
  - networks: list, `/state`, create, update;
  - network ACLs: create, get, update (PUT with ETag), delete;
  - network forwards: create, get, update, delete;
  - projects: list, get, update;
  - profiles: get, update;
  - instances: list, create, rebuild;
  - images: create from uploaded bytes, copy from a remote server, get by fingerprint;
  - custom storage volumes: create, attach, delete;
  - instance exec with captured stdout;
  - instance file push;
  - server environment: `server_clustered`, kernel version.

  `priv/incus/coverage.json` lists all of these as `partial`. File any gap as a change in opsmaru-incus, with coverage evidence there; never work around it here.

## 2. Addressing (unit)

- [ ] 2.1 Mesh configuration struct with validation: range, block prefix, node prefix, MTU, WireGuard base port, router state storage pool, router image delivery (`{:upload, stream_fun}` or `{:server, url, protocol}`) and pinned fingerprint. Verify every invalid combination returns a typed error.
- [ ] 2.2 `allocate_project/2` and `allocate_node_subnet/3`. Verify every `mesh-addressing` scenario, plus property tests: no overlap, deterministic, index 0 never allocated.
- [ ] 2.3 CIDR complement (mesh range minus block, plus transit range) as a minimal list. Verify the /9 and /16 case gives 7 CIDRs, that the result plus the block exactly covers the range, and edge prefixes (/8 with /24 blocks, block equal to the range).
- [ ] 2.4 Overlap check against a node's network addresses. Verify the `incusbr0` scenario using a fixture of `GET /1.0/networks` and `/state`.

## 3. Desired state (unit)

- [ ] 3.1 Naming (`om<hex4>`, `om<hex4>-isolation`, `omtransit`), ownership markers and the 15-character interface limit.
- [ ] 3.2 Isolation ACL rules from decision 3; bridge, transit-bridge and router configs (including `linux.kernel_modules=wireguard` and the state volume); the network forward's port map.
- [ ] 3.3 Project lock values. The permissive value for every `restricted.*` key, taken from Incus 7.0.1 `doc/config_options.txt` with the source line cited in a comment. Host override. Return of previous values.
- [ ] 3.4 Peering and relay selection. Verify both `Peering by reachability` scenarios and that no router ever gets a peer or allowed IP from another project.
- [ ] 3.5 Router files: init script, `peers.conf` (public keys only), `rules.nft`. Verify by inspection that no file template has a private-key field.
- [ ] 3.6 `desired/2` assembles all of the above. Verify it makes no network call.

## 4. Apply and remove (fixture)

- [ ] 4.1 Preflight: clustered server, kernel version, address overlap, unrestricted other projects. Verify each failure changes nothing (no mutating request recorded).
- [ ] 4.2 The eleven apply steps from decision 10, each idempotent. Verify a fresh apply, an immediate re-apply that makes no mutating request, and a failure injected at every step that stops there with access no wider than the full apply.
- [ ] 4.3 Key exec: output validation and public-key return. Verify through captured requests and results that no private key appears in any request body, result, error or log.
- [ ] 4.4 Ownership: refuse objects without a marker that have a mesh name; never touch unmarked objects. Verify the "pre-existing `om0003`" scenario.
- [ ] 4.5 ETag conflict on an ACL update, and reporting of tenant NICs with mesh-overlapping `ipv4.routes`.
- [ ] 4.6 `remove/3` in reverse order, including the rule against restoring access to remaining mesh bridges.
- [ ] 4.7 Image step: upload and server delivery, fingerprint verification before any create or rebuild, and one-at-a-time rebuild on a new pinned fingerprint. Verify the mismatch scenario stops with no router created, and that a rebuild keeps the state volume attached.
- [ ] 4.8 `status/2`: parse `latest-handshakes`, `transfer` and `endpoints` output, including `:never`. Verify by captured requests that only those three read-only commands are run and that no mutating request is made.
- [ ] 4.9 Verify that loading and starting `:opsmaru_mesh` creates no process, ETS table or port.

## 5. Router image

- [ ] 5.1 Image definition in `image/`: a minimal Alpine root filesystem with busybox, OpenRC, `iproute2`, `wireguard-tools-wg` and `nftables`, the mesh boot script, and Incus `metadata.yaml`, for `x86_64` and `aarch64`. Verify the tarball is under 16 MiB and that `ip`, `wg` and `nft` run in a container started from it.
- [ ] 5.2 Reproducible build in CI with pinned inputs (Alpine release and package versions). Verify two builds of the same commit produce the same SHA-256.
- [ ] 5.3 Release workflow: on a `v*` tag, attach both tarballs, their SHA-256 and a provenance attestation to the GitHub Release, and check that the fingerprints pinned in the library match. Verify that `mix hex.build` contains no image file.

## 6. Real-Incus acceptance (explicit opt-in, isolated hosts)

- [ ] 6.1 Two standalone Incus 7.0.1 hosts, one `reachable` and one `outbound_only` behind NAT, plus a third `outbound_only` host. Verify:
  - same-project traffic across all three, the NATed pair going via the relay;
  - cross-project rejection on one node and across nodes;
  - transit-range rejection;
  - forwarding survives stopping the control plane and restarting a router and a host.
- [ ] 6.2 Verify that a tenant NIC `ipv4.routes` hijack is rejected by the victim project's ingress rule and reported by apply.
- [ ] 6.3 Verify that an unrestricted project on a node blocks apply, and that restricting it lets apply continue.
- [ ] 6.4 Verify on a host with no internet access that an uploaded image creates working routers, that `linux.kernel_modules` loads WireGuard with no manual host setup, that a closed UDP port shows `:never` in `status/2`, and that an image upgrade keeps every router's public key.

## 7. Documentation

- [ ] 7.1 README: what the mesh does and does not guarantee (no "zero trust" claim), host prerequisites (standalone Incus 7.x, kernel 5.6+, UDP ports on reachable nodes, no host firewall dropping forwarded traffic), the router image and how to deliver it, and the central Opsmaru integration contract.
