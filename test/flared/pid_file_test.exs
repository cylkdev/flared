defmodule Flared.PidFileTest do
  use ExUnit.Case

  alias Flared.PidFile

  setup do
    dir =
      Path.join(System.tmp_dir!(), "flared_pid_file_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "path/2" do
    test "joins the resolved dir with <name>.pid", %{dir: dir} do
      assert PidFile.path("alpha", dir: dir) == Path.join(dir, "alpha.pid")
    end
  end

  describe "default_dir/0" do
    test "resolves to priv/tmp under the :flared app" do
      expected = Path.join(to_string(:code.priv_dir(:flared)), "tmp")
      assert PidFile.default_dir() == expected
    end
  end

  describe "write/3 + read/2" do
    test "round-trips a positive integer pid", %{dir: dir} do
      assert :ok = PidFile.write("alpha", 12_345, dir: dir)
      assert {:ok, 12_345} = PidFile.read("alpha", dir: dir)
    end

    test "creates the directory on demand", %{dir: dir} do
      nested = Path.join(dir, "nested")
      assert :ok = PidFile.write("alpha", 42, dir: nested)
      assert {:ok, 42} = PidFile.read("alpha", dir: nested)
    end

    test "overwrites an existing pid file", %{dir: dir} do
      :ok = PidFile.write("alpha", 1, dir: dir)
      :ok = PidFile.write("alpha", 2, dir: dir)
      assert {:ok, 2} = PidFile.read("alpha", dir: dir)
    end

    test "tolerates trailing whitespace on read", %{dir: dir} do
      File.write!(PidFile.path("alpha", dir: dir), "999\n")
      assert {:ok, 999} = PidFile.read("alpha", dir: dir)
    end
  end

  describe "read/2 errors" do
    test "returns :not_found when file is absent", %{dir: dir} do
      assert {:error, :not_found} = PidFile.read("missing", dir: dir)
    end

    test "returns :corrupt when contents are not a positive integer", %{dir: dir} do
      File.write!(PidFile.path("alpha", dir: dir), "not-a-pid")
      assert {:error, :corrupt} = PidFile.read("alpha", dir: dir)
    end

    test "returns :corrupt for zero or negative pids", %{dir: dir} do
      File.write!(PidFile.path("zero", dir: dir), "0")
      File.write!(PidFile.path("neg", dir: dir), "-3")
      assert {:error, :corrupt} = PidFile.read("zero", dir: dir)
      assert {:error, :corrupt} = PidFile.read("neg", dir: dir)
    end
  end

  describe "delete/2" do
    test "removes an existing pid file", %{dir: dir} do
      :ok = PidFile.write("alpha", 1, dir: dir)
      assert :ok = PidFile.delete("alpha", dir: dir)
      assert {:error, :not_found} = PidFile.read("alpha", dir: dir)
    end

    test "is a no-op when file is missing", %{dir: dir} do
      assert :ok = PidFile.delete("missing", dir: dir)
    end
  end

  describe "list/1" do
    test "returns {name, pid} pairs from .pid files", %{dir: dir} do
      :ok = PidFile.write("alpha", 1, dir: dir)
      :ok = PidFile.write("beta", 2, dir: dir)
      assert PidFile.list(dir: dir) |> Enum.sort() == [{"alpha", 1}, {"beta", 2}]
    end

    test "ignores non-.pid files", %{dir: dir} do
      :ok = PidFile.write("alpha", 1, dir: dir)
      File.write!(Path.join(dir, "notes.txt"), "irrelevant")
      assert PidFile.list(dir: dir) == [{"alpha", 1}]
    end

    test "skips corrupt .pid files", %{dir: dir} do
      :ok = PidFile.write("alpha", 1, dir: dir)
      File.write!(Path.join(dir, "broken.pid"), "garbage")
      assert PidFile.list(dir: dir) == [{"alpha", 1}]
    end

    test "returns [] when the directory is missing", %{dir: dir} do
      missing = Path.join(dir, "no-such-subdir")
      assert PidFile.list(dir: missing) == []
    end
  end

  describe "directory resolution" do
    setup do
      previous = Application.get_env(:flared, :tmp_dir)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:flared, :tmp_dir)
          val -> Application.put_env(:flared, :tmp_dir, val)
        end
      end)

      :ok
    end

    test "opts[:dir] takes precedence over config and default", %{dir: dir} do
      Application.put_env(:flared, :tmp_dir, "/should/not/be/used")

      assert :ok = PidFile.write("alpha", 7, dir: dir)
      assert File.exists?(Path.join(dir, "alpha.pid"))
      assert {:ok, 7} = PidFile.read("alpha", dir: dir)
    end

    test "falls back to Config.tmp_dir/0 when opts has no :dir", %{dir: dir} do
      Application.put_env(:flared, :tmp_dir, dir)

      assert :ok = PidFile.write("alpha", 11)
      assert File.exists?(Path.join(dir, "alpha.pid"))
      assert {:ok, 11} = PidFile.read("alpha")
      assert PidFile.list() == [{"alpha", 11}]
      assert :ok = PidFile.delete("alpha")
    end

    test "falls back to default_dir/0 when neither opts nor config is set" do
      Application.delete_env(:flared, :tmp_dir)

      assert PidFile.path("alpha") == Path.join(PidFile.default_dir(), "alpha.pid")
    end
  end
end
