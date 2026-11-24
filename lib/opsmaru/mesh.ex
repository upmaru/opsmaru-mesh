defmodule Opsmaru.Mesh do
  @moduledoc """
  Control plane for project-isolated cross-node networking between Incus
  hosts registered in Opsmaru.

  This is a pure library. It stores nothing and starts nothing: the host
  (central Opsmaru) supplies allocations, node records, policies and Incus
  connections on every call, and persists whatever the library returns.
  Traffic flows directly between nodes over WireGuard and never through the
  control plane.

  The design is proposed in the `add-mesh-foundation` OpenSpec change; no
  behaviour is implemented yet.
  """
end
