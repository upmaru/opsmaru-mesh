# opsmaru-mesh

Control plane for project-isolated, cross-node networking between Incus
hosts registered in [Opsmaru](https://github.com/upmaru/opsmaru).

Opsmaru allocates addresses, distributes WireGuard public keys and applies
isolation through the Incus API (via
[`opsmaru_incus`](https://github.com/upmaru/opsmaru-incus)). Traffic flows
directly between per-node router instances and never through the control
plane.

**Status:** design in progress. Nothing is implemented yet.

## Development

```bash
mise trust && mise install
mise run setup
mise run check
```
