defmodule Opsmaru.MeshTest do
  use ExUnit.Case, async: true

  test "the library defines no application callback" do
    assert Application.spec(:opsmaru_mesh, :mod) in [nil, []]
  end
end
