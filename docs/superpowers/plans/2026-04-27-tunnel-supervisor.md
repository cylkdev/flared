# Flared.TunnelSupervisor + Tunnel Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Per project CLAUDE.md, all Elixir source edits MUST be delegated to the `claude-copilot:code-implementer` subagent.

**Goal:** Rename `Flared.TunnelManager` → `Flared.Tunnel` (file paths and module names) and add `Flared.TunnelSupervisor`, a `DynamicSupervisor` auto-started under `Flared.Application` with `start_child/1` and `stop_child/1` for managing tunnel processes by pid or registered atom name.

**Architecture:** `Flared.TunnelSupervisor` (DynamicSupervisor) is the long-lived owner of zero-or-more `Flared.Tunnel` processes. `start_child/1` delegates to `DynamicSupervisor.start_child/2` with a `{Flared.Tunnel, opts}` child spec; `stop_child/1` resolves an atom name via `Process.whereis/1` (or accepts a pid directly) and calls `terminate_child/2`. The tunnel GenServer itself is unchanged in behavior — only renamed.

**Tech Stack:** Elixir 1.17, GenServer, DynamicSupervisor, ExUnit.

**Spec:** [`docs/superpowers/specs/2026-04-27-tunnel-manager-design.md`](../specs/2026-04-27-tunnel-manager-design.md)

---

## File Structure

**Rename (git mv):**
- `lib/flared/tunnel_manager.ex` → `lib/flared/tunnel.ex`
- `lib/flared/tunnel_manager/runner.ex` → `lib/flared/tunnel/runner.ex`
- `lib/flared/tunnel_manager/exec_runner.ex` → `lib/flared/tunnel/exec_runner.ex`
- `test/flared/tunnel_manager_test.exs` → `test/flared/tunnel_test.exs`

**Modify (in addition to the renames above):**
- `lib/flared/tunnel.ex` — module name `Flared.TunnelManager` → `Flared.Tunnel`; runner default `Flared.TunnelManager.ExecRunner` → `Flared.Tunnel.ExecRunner`.
- `lib/flared/tunnel/runner.ex` — module name `Flared.TunnelManager.Runner` → `Flared.Tunnel.Runner`; references in `@moduledoc`.
- `lib/flared/tunnel/exec_runner.ex` — module name `Flared.TunnelManager.ExecRunner` → `Flared.Tunnel.ExecRunner`; behaviour reference `Flared.TunnelManager.Runner` → `Flared.Tunnel.Runner`; `@moduledoc`.
- `test/flared/tunnel_test.exs` — test module `Flared.TunnelManagerTest` → `Flared.TunnelTest`; alias `Flared.TunnelManager` → `Flared.Tunnel`; behaviour reference `Flared.TunnelManager.Runner` → `Flared.Tunnel.Runner`.
- `lib/flared/application.ex` — add `Flared.TunnelSupervisor` to `children`.

**Create:**
- `lib/flared/tunnel_supervisor.ex` — the DynamicSupervisor.
- `test/flared/tunnel_supervisor_test.exs` — supervisor tests.

---

## Task 1: Rename module files and references

**Files:**
- Move: `lib/flared/tunnel_manager.ex` → `lib/flared/tunnel.ex`
- Move: `lib/flared/tunnel_manager/runner.ex` → `lib/flared/tunnel/runner.ex`
- Move: `lib/flared/tunnel_manager/exec_runner.ex` → `lib/flared/tunnel/exec_runner.ex`
- Move: `test/flared/tunnel_manager_test.exs` → `test/flared/tunnel_test.exs`
- Modify all four files for module-name references.

- [ ] **Step 1: Move files with git mv (preserves history)**

```bash
git mv lib/flared/tunnel_manager.ex lib/flared/tunnel.ex
git mv lib/flared/tunnel_manager/runner.ex lib/flared/tunnel/runner.ex
git mv lib/flared/tunnel_manager/exec_runner.ex lib/flared/tunnel/exec_runner.ex
rmdir lib/flared/tunnel_manager
git mv test/flared/tunnel_manager_test.exs test/flared/tunnel_test.exs
```

- [ ] **Step 2: Replace `Flared.TunnelManager` with `Flared.Tunnel` everywhere**

Use a single sed pass over the four moved files. The longest match must come first so `Flared.TunnelManager.Runner` is rewritten before its prefix is rewritten:

```bash
LC_ALL=C sed -i '' \
  -e 's/Flared\.TunnelManager\.ExecRunner/Flared.Tunnel.ExecRunner/g' \
  -e 's/Flared\.TunnelManager\.Runner/Flared.Tunnel.Runner/g' \
  -e 's/Flared\.TunnelManagerTest/Flared.TunnelTest/g' \
  -e 's/Flared\.TunnelManager/Flared.Tunnel/g' \
  lib/flared/tunnel.ex \
  lib/flared/tunnel/runner.ex \
  lib/flared/tunnel/exec_runner.ex \
  test/flared/tunnel_test.exs
```

- [ ] **Step 3: Sanity-check no stray references remain**

Run: `grep -rn 'TunnelManager' lib test`
Expected: no output.

- [ ] **Step 4: Compile and run tests at the renamed scope**

Run: `mix compile --warnings-as-errors && mix test test/flared/tunnel_test.exs`
Expected: PASS, no warnings, all 13 tunnel tests still green.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename TunnelManager to Tunnel"
```

---

## Task 2: Write the failing tests for TunnelSupervisor

**Files:**
- Create: `test/flared/tunnel_supervisor_test.exs`

- [ ] **Step 1: Create the test file**

Create `test/flared/tunnel_supervisor_test.exs`:

```elixir
defmodule Flared.TunnelSupervisorTest do
  use ExUnit.Case

  alias Flared.TunnelSupervisor

  defmodule NoopProvisioner do
    @moduledoc false
    def provision(_routes, _opts) do
      {:ok,
       %{
         tunnel_id: "t",
         tunnel_name: "n",
         tunnel_token: "tok",
         routes: [],
         dns: [],
         dry_run?: false,
         token_present?: true
       }}
    end
  end

  defmodule NoopRunner do
    @moduledoc false
    @behaviour Flared.Tunnel.Runner

    @impl true
    def run_link(_cmd, _opts) do
      pid =
        spawn_link(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, pid, 1234}
    end

    @impl true
    def stop(pid) do
      if Process.alive?(pid), do: send(pid, :stop)
      :ok
    end
  end

  defp tunnel_opts(extra \\ []) do
    Keyword.merge(
      [provisioner: NoopProvisioner, runner: NoopRunner],
      extra
    )
  end

  test "TunnelSupervisor is started by the application under its registered name" do
    pid = Process.whereis(TunnelSupervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "start_child/1 starts a Flared.Tunnel and returns {:ok, pid}" do
    {:ok, pid} = TunnelSupervisor.start_child(tunnel_opts())
    assert is_pid(pid)
    assert Process.alive?(pid)
    assert Flared.Tunnel.status(pid) == :idle
    :ok = TunnelSupervisor.stop_child(pid)
  end

  test "start_child/1 registers the child under the given :name" do
    name = :"tunnel_named_#{System.unique_integer([:positive])}"
    {:ok, pid} = TunnelSupervisor.start_child(tunnel_opts(name: name))
    assert Process.whereis(name) == pid
    :ok = TunnelSupervisor.stop_child(name)
  end

  test "stop_child/1 with a pid terminates the running child" do
    {:ok, pid} = TunnelSupervisor.start_child(tunnel_opts())
    assert :ok = TunnelSupervisor.stop_child(pid)
    refute Process.alive?(pid)
  end

  test "stop_child/1 with a registered atom name terminates the child" do
    name = :"tunnel_byname_#{System.unique_integer([:positive])}"
    {:ok, pid} = TunnelSupervisor.start_child(tunnel_opts(name: name))
    assert :ok = TunnelSupervisor.stop_child(name)
    refute Process.alive?(pid)
    assert Process.whereis(name) == nil
  end

  test "stop_child/1 returns {:error, :not_found} for an unregistered name" do
    assert {:error, :not_found} =
             TunnelSupervisor.stop_child(:no_such_tunnel_xyz_definitely_unregistered)
  end

  test "two named children can run concurrently under the supervisor" do
    name_a = :"tunnel_a_#{System.unique_integer([:positive])}"
    name_b = :"tunnel_b_#{System.unique_integer([:positive])}"

    {:ok, pid_a} = TunnelSupervisor.start_child(tunnel_opts(name: name_a))
    {:ok, pid_b} = TunnelSupervisor.start_child(tunnel_opts(name: name_b))

    assert pid_a != pid_b
    assert Process.alive?(pid_a)
    assert Process.alive?(pid_b)

    :ok = TunnelSupervisor.stop_child(name_a)
    :ok = TunnelSupervisor.stop_child(name_b)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/flared/tunnel_supervisor_test.exs`
Expected: FAIL — `Flared.TunnelSupervisor` undefined (compile error).

- [ ] **Step 3: Commit**

```bash
git add test/flared/tunnel_supervisor_test.exs
git commit -m "test: add failing tests for TunnelSupervisor"
```

---

## Task 3: Implement TunnelSupervisor

**Files:**
- Create: `lib/flared/tunnel_supervisor.ex`

- [ ] **Step 1: Create the module**

Create `lib/flared/tunnel_supervisor.ex`:

```elixir
defmodule Flared.TunnelSupervisor do
  @moduledoc """
  `DynamicSupervisor` for `Flared.Tunnel` processes.

  Auto-started under `Flared.Application`'s top-level supervisor.
  Use `start_child/1` to launch a tunnel process and `stop_child/1`
  to terminate it by pid or by registered atom name.

  ## Examples

      {:ok, pid} = Flared.TunnelSupervisor.start_child(name: :site_a)
      :ok = Flared.Tunnel.open_tunnel(:site_a, routes)
      :ok = Flared.TunnelSupervisor.stop_child(:site_a)
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a `Flared.Tunnel` child under this supervisor.

  `tunnel_opts` are forwarded to `Flared.Tunnel.start_link/1`. Pass
  `:name` to register the tunnel so it can be stopped by name later.
  """
  @spec start_child(keyword()) :: DynamicSupervisor.on_start_child()
  def start_child(tunnel_opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {Flared.Tunnel, tunnel_opts})
  end

  @doc """
  Stops a tunnel child by pid or registered atom name.

  Returns `{:error, :not_found}` if the atom name is not registered.
  """
  @spec stop_child(pid() | atom()) :: :ok | {:error, :not_found | term()}
  def stop_child(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  def stop_child(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> {:error, :not_found}
      pid -> stop_child(pid)
    end
  end
end
```

- [ ] **Step 2: Compile**

Run: `mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 3: Commit**

```bash
git add lib/flared/tunnel_supervisor.ex
git commit -m "feat: add Flared.TunnelSupervisor DynamicSupervisor"
```

---

## Task 4: Wire TunnelSupervisor into Flared.Application

**Files:**
- Modify: `lib/flared/application.ex`

- [ ] **Step 1: Add the child**

In `lib/flared/application.ex`, change the `children` list from:

```elixir
children = [
  # Starts a worker by calling: Flared.Worker.start_link(arg)
  # {Flared.Worker, arg}
]
```

to:

```elixir
children = [
  Flared.TunnelSupervisor
]
```

Resulting file:

```elixir
defmodule Flared.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Flared.TunnelSupervisor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Flared.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 2: Run the supervisor tests (now expected to pass)**

Run: `mix test test/flared/tunnel_supervisor_test.exs`
Expected: All 7 tests PASS.

- [ ] **Step 3: Run the full suite**

Run: `mix test`
Expected: All tests PASS (47 + 7 new = 54).

- [ ] **Step 4: Commit**

```bash
git add lib/flared/application.ex
git commit -m "feat: auto-start TunnelSupervisor under Flared.Application"
```

---

## Task 5: Run full project quality checks

**Files:** verification only.

- [ ] **Step 1: Compile cleanliness**

Run: `mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 2: Credo**

Run: `mix credo --strict`
Expected: No new issues introduced by this change. Pre-existing project-wide issues unrelated to this work may remain.

- [ ] **Step 3: Dialyzer**

Run: `mix dialyzer`
Expected: No new warnings introduced. The pre-existing warning in `lib/flared/template_writer.ex` may remain — out of scope.

- [ ] **Step 4: Commit any check-driven fixes**

If any of the above produced fixes:

```bash
git add -A
git commit -m "chore: address Credo/Dialyzer findings on TunnelSupervisor"
```

---

## Self-Review (completed)

**Spec coverage:**
- Module rename `TunnelManager` → `Tunnel` — Task 1.
- `Flared.TunnelSupervisor` DynamicSupervisor module — Task 3.
- `start_child/1`, `stop_child/1` (pid + atom name forms) — Task 3, tested in Task 2.
- Auto-start under `Flared.Application` — Task 4.
- 7 supervisor test cases from spec — all in Task 2.

**Placeholder scan:** None.

**Type consistency:** `start_child/1` returns `DynamicSupervisor.on_start_child()`, which is `{:ok, pid}` in tests. `stop_child/1` returns `:ok | {:error, :not_found}`, matching the spec table and the test assertions.

**Sed safety:** The sed expressions are ordered longest-first (`Flared.TunnelManager.ExecRunner` before `Flared.TunnelManager.Runner` before `Flared.TunnelManager`) so prefixes are rewritten correctly. `LC_ALL=C` keeps macOS BSD sed deterministic.
