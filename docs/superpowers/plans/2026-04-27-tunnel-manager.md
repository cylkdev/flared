# Flared.Tunnel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Per project CLAUDE.md, all Elixir source edits MUST be delegated to the `claude-copilot:code-implementer` subagent.

**Goal:** Add a singleton `Flared.Tunnel` GenServer that provisions a Cloudflare Tunnel via `Flared.Provisioner` and runs the cloudflared CLI via erlexec, with bounded exponential backoff on unexpected cloudflared exits.

**Architecture:** A named GenServer (`name: __MODULE__`) holds the tunnel token in state and owns one cloudflared OS process at a time. Provisioning and erlexec are isolated behind two injection seams — a `:provisioner` module and a `Flared.Tunnel.Runner` behaviour — so tests run offline without shelling out. State machine: `:idle → :running → :backing_off → :exhausted` with `close_tunnel/0` returning to `:idle` from any state.

**Tech Stack:** Elixir 1.17, GenServer, `:erlexec` 2.x, ExUnit. Existing project uses `req`, `jason`; tests are plain ExUnit (no Mox).

**Spec:** [`docs/superpowers/specs/2026-04-27-tunnel-manager-design.md`](../specs/2026-04-27-tunnel-manager-design.md)

---

## File Structure

**Create:**
- `lib/flared/tunnel_manager/runner.ex` — runner behaviour (`run_link/2`, `stop/1`).
- `lib/flared/tunnel_manager/exec_runner.ex` — default `Runner` impl wrapping `:exec`.
- `lib/flared/tunnel_manager.ex` — the GenServer.
- `test/flared/tunnel_manager_test.exs` — tests with inline stub modules.

**Modify:**
- `mix.exs` — add `{:erlexec, "~> 2.0"}` to deps; add `:exec` to `extra_applications`.
- `lib/flared/config.ex` — add `executable/0` accessor.

---

## Task 1: Add erlexec dependency

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add erlexec to deps and :exec to extra_applications**

In `mix.exs`, change `application/0` from:

```elixir
def application do
  [
    extra_applications: [:logger],
    mod: {Flared.Application, []}
  ]
end
```

to:

```elixir
def application do
  [
    extra_applications: [:logger, :exec],
    mod: {Flared.Application, []}
  ]
end
```

And in `deps/0`, add `{:erlexec, "~> 2.0"}` immediately after the `:jason` line:

```elixir
defp deps do
  [
    {:req, "~> 0.5"},
    {:jason, "~> 1.4"},
    {:erlexec, "~> 2.0"},
    {:credo, "~> 1.4", only: [:dev, :test], runtime: false},
    {:blitz_credo_checks, "~> 0.1.5", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:excoveralls, "~> 0.13", only: :test, runtime: false},
    {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
  ]
end
```

- [ ] **Step 2: Fetch and compile the dependency**

Run: `mix deps.get && mix deps.compile`
Expected: `erlexec` compiles successfully (it builds a small C port program; this can take 10–30s on first compile).

- [ ] **Step 3: Commit**

```bash
git add mix.exs mix.lock
git commit -m "deps: add erlexec for managing OS processes"
```

---

## Task 2: Add `Flared.Config.executable/0`

**Files:**
- Modify: `lib/flared/config.ex`
- Test: extend `test/flared_test.exs` is unnecessary — test is added in Task 5 alongside Tunnel tests, since this accessor has no behavior worth a standalone test.

- [ ] **Step 1: Add the accessor**

In `lib/flared/config.ex`, add this function below `dns/0`:

```elixir
@spec executable() :: String.t()
def executable do
  Application.get_env(@app, :executable, "cloudflared")
end
```

- [ ] **Step 2: Compile**

Run: `mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 3: Commit**

```bash
git add lib/flared/config.ex
git commit -m "config: add executable/0 accessor"
```

---

## Task 3: Define the Runner behaviour and default ExecRunner

**Files:**
- Create: `lib/flared/tunnel_manager/runner.ex`
- Create: `lib/flared/tunnel_manager/exec_runner.ex`

- [ ] **Step 1: Create the behaviour**

Create `lib/flared/tunnel_manager/runner.ex`:

```elixir
defmodule Flared.Tunnel.Runner do
  @moduledoc """
  Behaviour for spawning and stopping the cloudflared OS process.

  Abstracts erlexec so `Flared.Tunnel` can be tested without
  shelling out. Default implementation: `Flared.Tunnel.ExecRunner`.

  ## Contract

  - `run_link/2` MUST link the returned Erlang pid to the caller so that
    when the OS process exits, the caller receives `{:EXIT, pid, reason}`.
  - `stop/1` MUST be idempotent and tolerate a pid whose OS process has
    already exited.
  """

  @type cmd :: String.t() | charlist() | [String.t()]
  @type opts :: keyword()

  @callback run_link(cmd(), opts()) ::
              {:ok, pid(), non_neg_integer()} | {:error, term()}
  @callback stop(pid()) :: :ok | {:error, term()}
end
```

- [ ] **Step 2: Create the default impl**

Create `lib/flared/tunnel_manager/exec_runner.ex`:

```elixir
defmodule Flared.Tunnel.ExecRunner do
  @moduledoc """
  Default `Flared.Tunnel.Runner` implementation backed by erlexec.
  """

  @behaviour Flared.Tunnel.Runner

  @impl true
  def run_link(cmd, opts) do
    :exec.run_link(cmd, opts)
  end

  @impl true
  def stop(pid) when is_pid(pid) do
    case :exec.stop(pid) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :no_process} -> :ok
      other -> other
    end
  end
end
```

- [ ] **Step 3: Compile**

Run: `mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 4: Commit**

```bash
git add lib/flared/tunnel_manager/runner.ex lib/flared/tunnel_manager/exec_runner.ex
git commit -m "feat: add Tunnel.Runner behaviour and ExecRunner default"
```

---

## Task 4: Write the failing tests for Tunnel

**Files:**
- Create: `test/flared/tunnel_manager_test.exs`

This task writes the full test file up front. It covers every behavior in the design's "Test cases" list. Tests will fail to compile until Task 5 lands, which is expected and exactly what TDD prescribes.

- [ ] **Step 1: Create the test file**

Create `test/flared/tunnel_manager_test.exs`:

```elixir
defmodule Flared.TunnelTest do
  use ExUnit.Case, async: false

  alias Flared.Tunnel

  defmodule StubProvisioner do
    @moduledoc false

    def provision(routes, opts) do
      reply = :persistent_term.get({__MODULE__, :reply}, {:ok, default_result()})
      send(test_pid(), {:provision_called, routes, opts})

      case reply do
        {:fn, fun} -> fun.(routes, opts)
        other -> other
      end
    end

    def set_reply(reply), do: :persistent_term.put({__MODULE__, :reply}, reply)
    def reset, do: :persistent_term.erase({__MODULE__, :reply})

    def set_test_pid(pid), do: :persistent_term.put({__MODULE__, :test_pid}, pid)
    defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid}, self())

    defp default_result do
      %{
        tunnel_id: "tunnel-123",
        tunnel_name: "flare",
        tunnel_token: "tok-abc",
        routes: [],
        dns: [],
        dry_run?: false,
        token_present?: true
      }
    end
  end

  defmodule StubRunner do
    @moduledoc false
    @behaviour Flared.Tunnel.Runner

    @impl true
    def run_link(cmd, opts) do
      send(test_pid(), {:runner_run_link, cmd, opts})

      case :persistent_term.get({__MODULE__, :run_reply}, :default) do
        :default ->
          fake = spawn_link(fn ->
            receive do
              :stop -> :ok
              {:exit, reason} -> exit(reason)
            end
          end)

          os_pid = :persistent_term.get({__MODULE__, :next_os_pid}, 4242)
          :persistent_term.put({__MODULE__, :last_pid}, fake)
          {:ok, fake, os_pid}

        {:error, _} = err ->
          err
      end
    end

    @impl true
    def stop(pid) do
      send(test_pid(), {:runner_stop, pid})

      if Process.alive?(pid) do
        send(pid, :stop)
      end

      :ok
    end

    def set_run_reply(reply), do: :persistent_term.put({__MODULE__, :run_reply}, reply)
    def reset_run_reply, do: :persistent_term.erase({__MODULE__, :run_reply})
    def last_pid, do: :persistent_term.get({__MODULE__, :last_pid}, nil)
    def kill_last(reason \\ :killed) do
      case last_pid() do
        nil -> :ok
        pid ->
          if Process.alive?(pid), do: send(pid, {:exit, reason})
          :ok
      end
    end

    def set_test_pid(pid), do: :persistent_term.put({__MODULE__, :test_pid}, pid)
    defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid}, self())
  end

  setup do
    StubProvisioner.set_test_pid(self())
    StubRunner.set_test_pid(self())
    StubProvisioner.reset()
    StubRunner.reset_run_reply()
    :ok
  end

  defp start_manager(extra \\ []) do
    opts =
      Keyword.merge(
        [
          name: :"tm_#{System.unique_integer([:positive])}",
          provisioner: StubProvisioner,
          runner: StubRunner,
          base_backoff_ms: 10,
          max_backoff_ms: 80,
          max_attempts: 3,
          stabilization_ms: 50,
          executable: "cloudflared"
        ],
        extra
      )

    {:ok, pid} = Tunnel.start_link(opts)
    {pid, opts[:name]}
  end

  test "starts in :idle status" do
    {_pid, name} = start_manager()
    assert Tunnel.status(name) == :idle
  end

  test "open_tunnel/2 happy path: provisions, spawns cloudflared, transitions to :running" do
    {_pid, name} = start_manager()
    routes = [%{hostname: "x.example.com", service: "http://localhost:4000"}]

    assert :ok = Tunnel.open_tunnel(name, routes)
    assert_received {:provision_called, ^routes, _opts}
    assert_received {:runner_run_link, _cmd, _opts}
    assert Tunnel.status(name) == :running
  end

  test "open_tunnel/2 returns {:error, reason} when provisioner fails" do
    {_pid, name} = start_manager()
    StubProvisioner.set_reply({:error, :missing_account_id})

    assert {:error, :missing_account_id} =
             Tunnel.open_tunnel(name, [
               %{hostname: "x.example.com", service: "http://localhost:4000"}
             ])

    assert Tunnel.status(name) == :idle
  end

  test "open_tunnel/2 returns {:error, :missing_token} when token is nil" do
    {_pid, name} = start_manager()

    StubProvisioner.set_reply(
      {:ok,
       %{
         tunnel_id: "t1",
         tunnel_name: "flare",
         tunnel_token: nil,
         routes: [],
         dns: [],
         dry_run?: false,
         token_present?: false
       }}
    )

    assert {:error, :missing_token} =
             Tunnel.open_tunnel(name, [
               %{hostname: "x.example.com", service: "http://localhost:4000"}
             ])

    assert Tunnel.status(name) == :idle
  end

  test "open_tunnel/2 returns {:error, {:spawn_failed, _}} when runner fails" do
    {_pid, name} = start_manager()
    StubRunner.set_run_reply({:error, :enoent})

    assert {:error, {:spawn_failed, :enoent}} =
             Tunnel.open_tunnel(name, [
               %{hostname: "x.example.com", service: "http://localhost:4000"}
             ])

    assert Tunnel.status(name) == :idle
  end

  test "open_tunnel/2 from :running returns {:error, :already_started}" do
    {_pid, name} = start_manager()

    routes = [%{hostname: "x.example.com", service: "http://localhost:4000"}]
    assert :ok = Tunnel.open_tunnel(name, routes)
    assert {:error, :already_started} = Tunnel.open_tunnel(name, routes)
  end

  test "cloudflared exit while :running schedules retry with backoff" do
    {_pid, name} = start_manager()
    routes = [%{hostname: "x.example.com", service: "http://localhost:4000"}]

    assert :ok = Tunnel.open_tunnel(name, routes)
    assert_received {:runner_run_link, _, _}

    StubRunner.kill_last(:abnormal)

    Process.sleep(5)
    assert Tunnel.status(name) == :backing_off

    assert_receive {:runner_run_link, _, _}, 200
    assert Tunnel.status(name) == :running
  end

  test "exhausts after max_attempts consecutive failures" do
    {_pid, name} = start_manager(max_attempts: 2, base_backoff_ms: 5, max_backoff_ms: 10)
    routes = [%{hostname: "x.example.com", service: "http://localhost:4000"}]

    assert :ok = Tunnel.open_tunnel(name, routes)

    StubRunner.kill_last(:boom)
    assert_receive {:runner_run_link, _, _}, 200
    StubRunner.kill_last(:boom)
    assert_receive {:runner_run_link, _, _}, 200
    StubRunner.kill_last(:boom)

    Process.sleep(50)
    assert Tunnel.status(name) == :exhausted
  end

  test "open_tunnel/2 from :exhausted resets attempts and proceeds" do
    {_pid, name} = start_manager(max_attempts: 1, base_backoff_ms: 5)
    routes = [%{hostname: "x.example.com", service: "http://localhost:4000"}]

    assert :ok = Tunnel.open_tunnel(name, routes)
    StubRunner.kill_last(:boom)
    Process.sleep(30)
    StubRunner.kill_last(:boom)
    Process.sleep(30)
    assert Tunnel.status(name) == :exhausted

    assert :ok = Tunnel.open_tunnel(name, routes)
    assert Tunnel.status(name) == :running
  end

  test "stabilization timer resets attempt counter after success" do
    {_pid, name} =
      start_manager(max_attempts: 2, base_backoff_ms: 5, stabilization_ms: 30)

    routes = [%{hostname: "x.example.com", service: "http://localhost:4000"}]
    assert :ok = Tunnel.open_tunnel(name, routes)

    StubRunner.kill_last(:boom)
    assert_receive {:runner_run_link, _, _}, 200

    Process.sleep(60)
    assert Tunnel.status(name) == :running

    StubRunner.kill_last(:boom)
    assert_receive {:runner_run_link, _, _}, 200
    assert Tunnel.status(name) == :running
  end

  test "close_tunnel/1 from :running stops runner and returns to :idle" do
    {_pid, name} = start_manager()

    assert :ok =
             Tunnel.open_tunnel(name, [
               %{hostname: "x.example.com", service: "http://localhost:4000"}
             ])

    assert :ok = Tunnel.close_tunnel(name)
    assert_received {:runner_stop, _pid}
    assert Tunnel.status(name) == :idle
  end

  test "close_tunnel/1 from :backing_off cancels pending retry" do
    {_pid, name} = start_manager(base_backoff_ms: 200)

    assert :ok =
             Tunnel.open_tunnel(name, [
               %{hostname: "x.example.com", service: "http://localhost:4000"}
             ])

    StubRunner.kill_last(:boom)
    Process.sleep(10)
    assert Tunnel.status(name) == :backing_off

    assert :ok = Tunnel.close_tunnel(name)
    assert Tunnel.status(name) == :idle

    Process.sleep(250)
    refute_received {:runner_run_link, _, _}
  end

  test "close_tunnel/1 from :idle is a no-op" do
    {_pid, name} = start_manager()
    assert :ok = Tunnel.close_tunnel(name)
    assert Tunnel.status(name) == :idle
  end

  test "terminate stops runner if a process is running" do
    {pid, name} = start_manager()

    assert :ok =
             Tunnel.open_tunnel(name, [
               %{hostname: "x.example.com", service: "http://localhost:4000"}
             ])

    Process.flag(:trap_exit, true)
    GenServer.stop(pid, :normal)
    assert_received {:runner_stop, _}
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/flared/tunnel_manager_test.exs`
Expected: FAIL with compile error — `Flared.Tunnel` is undefined.

- [ ] **Step 3: Commit**

```bash
git add test/flared/tunnel_manager_test.exs
git commit -m "test: add failing tests for Tunnel"
```

---

## Task 5: Implement Tunnel

**Files:**
- Create: `lib/flared/tunnel_manager.ex`

- [ ] **Step 1: Implement the GenServer**

Create `lib/flared/tunnel_manager.ex`:

```elixir
defmodule Flared.Tunnel do
  @moduledoc """
  Singleton GenServer that owns the lifecycle of a single Cloudflare Tunnel
  runtime.

  Given a list of routes, it provisions tunnel resources via
  `Flared.Provisioner.provision/2`, extracts the returned token, and runs
  `cloudflared tunnel run --token <token>` as an OS process via erlexec.

  If the cloudflared OS process exits unexpectedly, the manager re-spawns
  it (without re-provisioning) using a bounded exponential backoff. After
  `:max_attempts` consecutive failures, it transitions to `:exhausted` and
  stays inert until `open_tunnel/2` is called again.

  ## Lifecycle

      :idle --open_tunnel--> :running
        :running --cloudflared exits--> :backing_off --retry--> :running
        :backing_off --attempts exhausted--> :exhausted
        any --close_tunnel--> :idle

  See `docs/superpowers/specs/2026-04-27-tunnel-manager-design.md` for the
  full design.
  """

  use GenServer

  require Logger

  alias Flared.Config

  @default_max_attempts 5
  @default_base_backoff_ms 1_000
  @default_max_backoff_ms 30_000
  @default_stabilization_ms 10_000

  @type status :: :idle | :running | :backing_off | :exhausted

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec open_tunnel(GenServer.server(), [map()], keyword()) :: :ok | {:error, term()}
  def open_tunnel(server \\ __MODULE__, routes, provision_opts \\ [])
      when is_list(routes) do
    GenServer.call(server, {:open_tunnel, routes, provision_opts}, :infinity)
  end

  @spec close_tunnel(GenServer.server()) :: :ok
  def close_tunnel(server \\ __MODULE__) do
    GenServer.call(server, :close_tunnel)
  end

  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      status: :idle,
      routes: nil,
      provision_opts: nil,
      token: nil,
      tunnel_id: nil,
      exec_pid: nil,
      os_pid: nil,
      attempt: 0,
      backoff_ref: nil,
      stabilization_ref: nil,
      opts: %{
        max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
        base_backoff_ms: Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms),
        max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms),
        stabilization_ms: Keyword.get(opts, :stabilization_ms, @default_stabilization_ms),
        executable: Keyword.get(opts, :executable) || Config.executable(),
        provisioner: Keyword.get(opts, :provisioner, Flared.Provisioner),
        runner: Keyword.get(opts, :runner, Flared.Tunnel.ExecRunner)
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:open_tunnel, _routes, _opts}, _from, %{status: status} = state)
      when status in [:running, :backing_off] do
    {:reply, {:error, :already_started}, state}
  end

  def handle_call({:open_tunnel, routes, provision_opts}, _from, state) do
    state = reset_for_new_session(state)

    case state.opts.provisioner.provision(routes, provision_opts) do
      {:ok, %{tunnel_token: token, tunnel_id: tunnel_id}} when is_binary(token) and token != "" ->
        case spawn_cloudflared(token, state) do
          {:ok, exec_pid, os_pid} ->
            stabilization_ref = arm_stabilization(state.opts.stabilization_ms)

            new_state = %{
              state
              | status: :running,
                routes: routes,
                provision_opts: provision_opts,
                token: token,
                tunnel_id: tunnel_id,
                exec_pid: exec_pid,
                os_pid: os_pid,
                stabilization_ref: stabilization_ref
            }

            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, {:spawn_failed, reason}}, state}
        end

      {:ok, _result} ->
        {:reply, {:error, :missing_token}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close_tunnel, _from, state) do
    {:reply, :ok, do_stop(state)}
  end

  @impl true
  def handle_info(:retry, %{status: :backing_off} = state) do
    case spawn_cloudflared(state.token, state) do
      {:ok, exec_pid, os_pid} ->
        stabilization_ref = arm_stabilization(state.opts.stabilization_ms)

        {:noreply,
         %{
           state
           | status: :running,
             exec_pid: exec_pid,
             os_pid: os_pid,
             backoff_ref: nil,
             stabilization_ref: stabilization_ref
         }}

      {:error, reason} ->
        Logger.warning("cloudflared respawn failed: #{inspect(reason)}")
        schedule_or_exhaust(%{state | exec_pid: nil, os_pid: nil, backoff_ref: nil})
    end
  end

  def handle_info(:retry, state), do: {:noreply, state}

  def handle_info(:stabilized, %{status: :running} = state) do
    {:noreply, %{state | attempt: 0, stabilization_ref: nil}}
  end

  def handle_info(:stabilized, state), do: {:noreply, %{state | stabilization_ref: nil}}

  def handle_info({:EXIT, exec_pid, reason}, %{status: :running, exec_pid: exec_pid} = state) do
    Logger.warning("cloudflared exited: #{inspect(reason)}")

    state =
      state
      |> cancel_stabilization()
      |> Map.put(:exec_pid, nil)
      |> Map.put(:os_pid, nil)

    schedule_or_exhaust(state)
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{exec_pid: pid} = state) when is_pid(pid) do
    state.opts.runner.stop(pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp spawn_cloudflared(token, state) do
    cmd = build_cmd(state.opts.executable, token)
    state.opts.runner.run_link(cmd, [])
  end

  defp build_cmd(path, token) do
    ~c"#{path} tunnel run --token #{token}"
  end

  defp arm_stabilization(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :stabilized, ms)
  end

  defp cancel_stabilization(%{stabilization_ref: nil} = state), do: state

  defp cancel_stabilization(%{stabilization_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | stabilization_ref: nil}
  end

  defp cancel_backoff(%{backoff_ref: nil} = state), do: state

  defp cancel_backoff(%{backoff_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | backoff_ref: nil}
  end

  defp schedule_or_exhaust(%{attempt: attempt, opts: opts} = state) do
    next_attempt = attempt + 1

    if next_attempt > opts.max_attempts do
      {:noreply, %{state | status: :exhausted, attempt: next_attempt}}
    else
      delay =
        min(
          opts.base_backoff_ms * Integer.pow(2, next_attempt - 1),
          opts.max_backoff_ms
        )

      ref = Process.send_after(self(), :retry, delay)

      {:noreply,
       %{state | status: :backing_off, attempt: next_attempt, backoff_ref: ref}}
    end
  end

  defp do_stop(state) do
    state =
      state
      |> cancel_backoff()
      |> cancel_stabilization()

    if is_pid(state.exec_pid) do
      state.opts.runner.stop(state.exec_pid)
    end

    %{
      state
      | status: :idle,
        exec_pid: nil,
        os_pid: nil,
        attempt: 0
    }
  end

  defp reset_for_new_session(%{status: :exhausted} = state) do
    %{state | status: :idle, attempt: 0, exec_pid: nil, os_pid: nil}
    |> cancel_backoff()
    |> cancel_stabilization()
  end

  defp reset_for_new_session(state), do: state
end
```

- [ ] **Step 2: Run the tests**

Run: `mix test test/flared/tunnel_manager_test.exs --max-failures 1`
Expected: All tests in the file PASS.

If any test fails, read the failure carefully — common issues:
- `:exec` not in `extra_applications` (Task 1).
- A typo in option propagation between `start_link/1` and `init/1`.
- A timing issue where `Process.sleep/1` values are too short for CI; bump them in the failing test only.

- [ ] **Step 3: Commit**

```bash
git add lib/flared/tunnel_manager.ex
git commit -m "feat: add Tunnel GenServer with bounded backoff retry"
```

---

## Task 6: Run full project quality checks

**Files:**
- (none modified — verification only)

- [ ] **Step 1: Run the full test suite**

Run: `mix test`
Expected: All tests PASS.

- [ ] **Step 2: Run Credo**

Run: `mix credo --strict`
Expected: No issues. If style issues are reported, fix them in place and re-run. Do NOT suppress without justification.

- [ ] **Step 3: Run Dialyzer**

Run: `mix dialyzer`
Expected: No warnings. If a warning is a true type bug, fix the typespec or implementation. Only add to `.dialyzer-ignore.exs` for known false positives with a comment explaining why.

- [ ] **Step 4: Verify compile cleanliness**

Run: `mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 5: Commit any check-driven fixes**

If any of the above produced fixes:

```bash
git add -A
git commit -m "chore: address Credo/Dialyzer findings on Tunnel"
```

---

## Self-Review (completed)

**Spec coverage:**
- Module/API/state — Tasks 3, 5.
- `open_tunnel/2` state transitions (5 cases) — Task 4 tests + Task 5 `handle_call`.
- Restart loop with bounded exponential backoff — Task 5 `schedule_or_exhaust/1` + Task 4 backoff/exhaustion tests.
- `close_tunnel/0` from each state — Task 4 tests + Task 5 `do_stop/1`.
- `terminate/2` best-effort kill — Task 4 last test + Task 5 `terminate/2`.
- erlexec dependency + `:exec` in extra_applications — Task 1.
- `Flared.Config.executable/0` — Task 2.
- Two injection seams (`:provisioner`, `:runner`) — Tasks 3, 5; tests in Task 4.
- 13 test cases from spec — all in Task 4.

**Placeholder scan:** None.

**Type consistency:** `open_tunnel/2`, `close_tunnel/1`, and `status/1` signatures match between test file and implementation. `Runner` callbacks `run_link/2` and `stop/1` match between behaviour, `ExecRunner`, and `StubRunner`.
