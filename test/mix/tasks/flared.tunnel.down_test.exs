defmodule Mix.Tasks.Flared.Tunnel.DownTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Flared.Tunnel.Down

  describe "validate_flags/1" do
    test "graceful mode by default" do
      assert {:ok, :graceful} = Down.validate_flags([])
    end

    test "dry-run mode when --dry-run is set" do
      assert {:ok, :dry_run} = Down.validate_flags(dry_run: true)
    end

    test "force mode when --force is set" do
      assert {:ok, :force} = Down.validate_flags(force: true)
    end

    test "rejects --dry-run + --force as conflicting" do
      assert {:error, :conflicting_actions} =
               Down.validate_flags(dry_run: true, force: true)
    end

    test "treats false flags the same as absent" do
      assert {:ok, :graceful} = Down.validate_flags(dry_run: false, force: false)
    end
  end

  describe "filter_by_name/2" do
    test "returns all entries when filter is nil" do
      entries = [{"a", 1}, {"b", 2}]
      assert ^entries = Down.filter_by_name(entries, nil)
    end

    test "filters to entries with the matching name" do
      assert [{"api", 7}] = Down.filter_by_name([{"api", 7}, {"web", 8}], "api")
    end

    test "returns [] when no entry matches" do
      assert [] = Down.filter_by_name([{"api", 7}], "nope")
    end

    test "returns [] when the input list is empty" do
      assert [] = Down.filter_by_name([], "anything")
    end
  end
end
