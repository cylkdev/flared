defmodule FlaredTest do
  use ExUnit.Case
  doctest Flared

  test "greets the world" do
    assert Flared.hello() == :world
  end
end
