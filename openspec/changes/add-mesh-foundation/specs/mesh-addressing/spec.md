# Spec Delta

## ADDED Requirements

### Requirement: Deterministic project and node allocation

The library SHALL allocate each joined Incus project a block of the host-configured mesh range, and each project/node pair a subnet of that block, as a pure function of the mesh configuration and the existing allocations supplied by the host. Allocation SHALL return the lowest free index, MUST NOT return an index or subnet already allocated, and MUST NOT allocate block index 0, which is reserved for the transit range. When the range or block is exhausted it SHALL return a typed error, never an overlapping allocation.

#### Scenario: First project

- **WHEN** the host allocates a block for the first project in an empty mesh with range `10.128.0.0/9` and /16 blocks
- **THEN** the project receives block index 1, `10.129.0.0/16`

#### Scenario: Same input, same output

- **WHEN** the same configuration and existing allocations are passed twice
- **THEN** both calls return the same allocation

#### Scenario: Released index reused

- **WHEN** block 2 is free and blocks 1 and 3 are allocated
- **THEN** the next project receives block 2

#### Scenario: Exhausted block

- **WHEN** every node subnet in a project's block is allocated
- **THEN** allocating another node subnet returns `{:error, :block_exhausted}`

### Requirement: No overlap with existing node networks

Before a node's first apply, the library SHALL read the addresses of every network on that node through `opsmaru_incus`. If any of them overlaps the mesh range, it SHALL fail the join with a typed error naming the overlapping network. The library MUST NOT renumber, modify or delete any network it did not create.

#### Scenario: Existing bridge inside the mesh range

- **WHEN** a node's `incusbr0` uses `10.129.4.1/24` and the mesh range is `10.128.0.0/9`
- **THEN** the join fails with an error naming `incusbr0`, and no object is created on the node

#### Scenario: Unrelated existing networks

- **WHEN** a node's existing networks lie outside the mesh range
- **THEN** they are left untouched and the join proceeds
