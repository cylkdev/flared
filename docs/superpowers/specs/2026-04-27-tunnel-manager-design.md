# Flared.Tunnel — Design

Date: 2026-04-27
Status: Approved (brainstorm)

## Summary

A GenServer named `Flared.Tunnel` that owns the lifecycle of a single Cloudflare Tunnel runtime. Given a list of routes, it provisions tunnel resources via `Flared.Provisioner`, extracts the returned token, and runs `cloudflared tunnel run --token <token>` as an OS process via `erlexec`. If the cloudflared process exits unexpectedly, the manager re-spawns it (without re-provisioning) using a bounded exponential backoff.

Multiple `Flared.Tunnel` processes are supervised by `Flared.TunnelSupervisor`, a `DynamicSupervisor` started under `Flared.Application` that exposes `start_child/1` and `stop_child/1` for managing tunnel processes by pid or registered name.

## Goals

- Provide one place to start, stop, and monitor an individual cloudflared tunnel from inside the BEAM.
- Allow more than one tunnel to run concurrently, each as its own supervised process.
- Survive transient cloudflared crashes by re-spawning with the stored token.
- Stop trying after a bounded number of consecutive failures so a permanently-broken config does not loop forever.
- Stay testable without hitting the Cloudflare API or executing real binaries.

## Non-Goals

- Multiplexing several tunnels through a single `Flared.Tunnel` process. Each `Flared.Tunnel` owns one tunnel.
- Re-provisioning on cloudflared crash. The token is reused across restarts within a session.
- Persisting state across BEAM restarts.

## Modules

- `Flared.Tunnel` — implements `GenServer`. Default `name: __MODULE__` keeps the single-tunnel default ergonomic; callers under the supervisor pass a unique `:name` (or no name, using the pid as the handle).
- `Flared.TunnelSupervisor` — implements `DynamicSupervisor`, registered with `name: __MODULE__`. Auto-started under `Flared.Application`'s top-level supervisor.

## Public API

```elixir
@spec start_link(atom(), [Flared.Provisioner.route()] | nil, keyword()) ::
        GenServer.on_start()
@spec child_spec({atom(), [Flared.Provisioner.route()] | nil, keyword()}) ::
        Supervisor.child_spec()
@spec child_spec({atom(), keyword()}) :: Supervisor.child_spec()
@spec child_spec(keyword()) :: Supervisor.child_spec()
@spec open_tunnel([Flared.Provisioner.route()], keyword()) :: :ok | {:error, term()}
@spec close_tunnel() :: :ok
@spec status() :: :idle | :running | :backing_off | :exhausted
```

`routes` is a first-class positional argument — never a key in `opts`. `start_link/3` takes `(name, routes, opts)`; `init/1` receives `{routes, opts}` as its arg; `child_spec/1` has three clauses to accept all the call shapes.

`child_spec/1` clauses (longest-first):

- `child_spec({name, routes, opts})` when `is_list(opts)` — primary form. Produces `id: {Flared.Tunnel, name}` and `start: {Flared.Tunnel, :start_link, [name, routes, opts]}`.
- `child_spec({name, opts})` when `is_list(opts)` — convenience form for callers that have no routes. Recurses with `routes = nil`: `child_spec({name, nil, opts})`.
- `child_spec(opts)` when `is_list(opts)` — pops `:name` from `opts` and recurses: `opts |> Keyword.pop!(:name) |> child_spec()`. The result is a 2-tuple, which the second clause then forwards to the primary form with `routes = nil`. Raises `KeyError` if `:name` is absent.

This lets the supervisor pass `{Flared.Tunnel, {name, routes, opts}}` (when it has routes), `{Flared.Tunnel, {name, opts}}`, or `{Flared.Tunnel, opts_with_name}` and have all shapes work.

### `start_link/3` arguments

| Position | Default | Meaning |
| --- | --- | --- |
| `name` | `Flared.Tunnel` | Registered atom name for the GenServer. |
| `routes` | `nil` | List of `Flared.Provisioner.route()` to auto-provision, or `nil` to skip auto-start. |
| `opts` | `[]` | Tunnel configuration; see table below. |

### `opts` keys

| Option | Default | Meaning |
| --- | --- | --- |
| `:auto_start` | `true` | When `true` and `routes` is a list, init returns `{:ok, state, {:continue, ...}}` so the tunnel comes up `:running` without an explicit `open_tunnel/3` call. When `false`, the GenServer starts `:idle` regardless of `routes`; the caller drives it via `open_tunnel/3`. |
| `:max_attempts` | `5` | Max consecutive cloudflared spawn attempts before giving up. |
| `:base_backoff_ms` | `1_000` | First backoff delay. |
| `:max_backoff_ms` | `30_000` | Cap on backoff delay. |
| `:executable` | from `Flared.Config` | Path to `cloudflared` binary; defaults to `"cloudflared"` (PATH). |
| `:stabilization_ms` | `10_000` | Time the process must stay up before the attempt counter resets. |
| `:provisioner` | `Flared.Provisioner` | Test seam — module that exposes `provision/2`. |
| `:runner` | `Flared.Tunnel.ExecRunner` | Test seam — module that wraps erlexec calls. |

`opts` MUST NOT contain a `:routes` key — routes flow exclusively through the positional argument. Provision keys (`:account_id`, `:tunnel_name`, `:dry_run?`, `:token`, `:concurrency`) may appear in `opts`; they are forwarded to `Flared.Provisioner.provision/2` during the auto-start `handle_continue/2`. `Provisioner.provision/2` ignores keys it does not recognize, so a single opts list serves both tunnel-config and provision-config purposes.

### Auto-start behavior

- `init({routes, opts})` checks `auto_start? and is_list(routes)`. If both true, return `{:ok, state, {:continue, {:auto_start, routes, opts}}}`. Otherwise return `{:ok, state}` (idle).
- `handle_continue({:auto_start, routes, opts}, state)` performs the same provisioning + spawn flow as `handle_call({:open_tunnel, ...}, _, state)`. On success, transitions to `:running`. On failure, logs the error and stays `:idle` (does NOT crash the GenServer — that would loop under a `:permanent` supervisor).
- The provisioning logic is shared between `handle_continue/2` and `handle_call/3` via a single private helper, e.g. `do_open_tunnel(routes, provision_opts, state) :: {:ok, new_state} | {:error, reason}`.

### `open_tunnel/2` options

Forwarded to the configured `:provisioner` module's `provision/2`. Per `Flared.Provisioner.provision/2`: `:account_id`, `:tunnel_name`, `:dry_run?`, `:token`, etc. Use this function directly when `auto_start: false` was passed to `start_link/1`, or to retry from `:idle`/`:exhausted` after a failure.

## State

```elixir
%{
  status: :idle | :running | :backing_off | :exhausted,
  routes: [Flared.Provisioner.route()] | nil,
  token: String.t() | nil,
  tunnel_id: String.t() | nil,
  exec_pid: pid() | nil,
  os_pid: non_neg_integer() | nil,
  attempt: non_neg_integer(),
  backoff_ref: reference() | nil,
  stabilization_ref: reference() | nil,
  opts: %{
    max_attempts: pos_integer(),
    base_backoff_ms: pos_integer(),
    max_backoff_ms: pos_integer(),
    stabilization_ms: pos_integer(),
    executable: String.t(),
    provisioner: module(),
    runner: module()
  }
}
```

## Behavior

### `open_tunnel/2` (state transitions)

| From | Action | To |
| --- | --- | --- |
| `:idle` | provisioner returns `{:ok, %{tunnel_token: token, tunnel_id: id}}` and `token` is non-nil; runner spawns cloudflared OK | `:running` |
| `:idle` | provisioner returns `{:error, reason}` | `:idle` (returns `{:error, reason}`) |
| `:idle` | provisioner returns `{:ok, %{tunnel_token: nil}}` | `:idle` (returns `{:error, :missing_token}`) |
| `:idle` | runner fails to spawn cloudflared | `:idle` (returns `{:error, {:spawn_failed, reason}}`) |
| `:running` \| `:backing_off` | already-active call | unchanged (returns `{:error, :already_started}`) |
| `:exhausted` | resets `attempt` to `0` and proceeds as from `:idle` | `:running` (or `:idle` on error) |

### Restart loop (cloudflared exits while `:running`)

Trigger: linked erlexec port sends `{:EXIT, exec_pid, _reason}` (or equivalent erlexec event) while `status == :running`.

```
attempt := attempt + 1
if attempt > max_attempts:
  status := :exhausted
  clear exec_pid, os_pid
else:
  delay := min(base_backoff_ms * 2^(attempt - 1), max_backoff_ms)
  schedule send_after(self(), :retry, delay)
  status := :backing_off
```

On `:retry`: re-spawn `cloudflared tunnel run --token <token>` with the stored token. On successful spawn, transition to `:running` and start a `stabilization_ms` timer. If the OS process is still up when the stabilization timer fires, reset `attempt := 0`.

### `close_tunnel/0`

| From | Action | To |
| --- | --- | --- |
| `:idle` | no-op | `:idle` |
| `:running` | runner stops `exec_pid`; cancel stabilization timer | `:idle` |
| `:backing_off` | cancel `backoff_ref` | `:idle` |
| `:exhausted` | clear retained state | `:idle` |

### `terminate/2`

Best-effort: if `exec_pid` is set, ask the runner to stop it so the OS process is not orphaned on supervisor shutdown.

## Dependencies (mix.exs changes)

- Add `{:erlexec, "~> 2.0"}` to `deps/0`.
- Add `:exec` to `extra_applications` in `application/0`.
- Note: `erlexec` compiles a small C port program at install time. Document this in the module docs so first compile is not a surprise.

## Configuration

`Flared.Config.executable/0` — new accessor returning `Application.get_env(:flared, :executable, "cloudflared")`.

## Testability

Two injection seams keep tests offline and silent:

- `:provisioner` — defaults to `Flared.Provisioner`. Tests pass a stub module returning canned `{:ok, %{...}}` / `{:error, _}`.
- `:runner` — defaults to `Flared.Tunnel.ExecRunner` (thin wrapper around `:exec.run_link/2` and `:exec.stop/1`). Tests pass a stub that records spawn calls and lets the test trigger fake exits.

### Test cases

1. Happy path: `open_tunnel/2` provisions and spawns; `status/0` returns `:running`.
2. Provisioner error returns `{:error, reason}` and stays `:idle`.
3. Provisioner returns `tunnel_token: nil` → `{:error, :missing_token}`.
4. Spawn failure from runner returns `{:error, {:spawn_failed, reason}}` and stays `:idle`.
5. cloudflared exits while `:running` → schedules retry with expected backoff.
6. Backoff progression: 1s, 2s, 4s, 8s, 16s (capped at `max_backoff_ms`).
7. Exhaustion after `max_attempts` consecutive failures → `:exhausted`.
8. `open_tunnel/2` from `:exhausted` resets `attempt` and re-runs flow.
9. Surviving past `stabilization_ms` resets `attempt`.
10. `close_tunnel/0` from `:running` stops runner and transitions to `:idle`.
11. `close_tunnel/0` from `:backing_off` cancels pending retry.
12. `terminate/2` stops runner if `exec_pid` is set.
13. `open_tunnel/2` while `:running` returns `{:error, :already_started}`.

## Flared.TunnelSupervisor

`DynamicSupervisor` registered as `Flared.TunnelSupervisor`, auto-started under `Flared.Application`'s top-level supervisor with `strategy: :one_for_one`.

### Public API

```elixir
@spec start_link(keyword()) :: Supervisor.on_start()
@spec start_child(atom(), [Flared.Provisioner.route()] | nil, keyword()) ::
        DynamicSupervisor.on_start_child()
@spec stop_child(pid() | atom()) :: :ok | {:error, :not_found | term()}
```

### Behavior

- `start_child/3` is a thin wrapper that hands the 3-tuple `{name, routes, opts}` directly to `Flared.Tunnel.child_spec/1`. It does NOT munge opts in any way — routes flow through the tuple, never through opts. The supervisor itself has no awareness of provisioning — that lives in `Flared.Tunnel.init/1` + `handle_continue/2`. Implementation:

  ```elixir
  def start_child(name \\ Flared.Tunnel, routes \\ nil, opts \\ [])

  def start_child(name, routes, opts) when is_atom(name) and is_list(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Flared.Tunnel, {name, routes, opts}})
  end
  ```

  - `name` defaults to `Flared.Tunnel`.
  - `routes` defaults to `nil`. When `nil`, no auto-start fires (`is_list(nil) === false` in `init/1`). When a list, the GenServer auto-provisions during init.
  - `opts` defaults to `[]`. Pass `auto_start: false` here to leave the tunnel idle even when `routes` is a list. Other keys recognized by `Flared.Tunnel.start_link/3` and `Flared.Provisioner.provision/2` may also appear, but `:routes` MUST NOT.
  - The `is_atom(name)` guard turns the common-misuse case (`start_child(routes)` without a name) into a clear `FunctionClauseError` instead of silent misbinding.
- `stop_child/1` accepts either a pid or a registered atom name. For an atom, it resolves via `Process.whereis/1`; if not found, returns `{:error, :not_found}`. Otherwise calls `DynamicSupervisor.terminate_child/2`. Termination triggers the `Flared.Tunnel`'s `terminate/2`, which best-effort kills its cloudflared OS process.
- Restart policy for children: default `:permanent`. The in-process cloudflared crash handling (backoff + `:exhausted`) means the GenServer almost never crashes; supervisor restart only kicks in for hard process kills (OOM, etc.). On restart, the GenServer comes up via `init/1` again and — if `:routes` and `:auto_start` were passed — auto-provisions a fresh tunnel from scratch.

### Application wiring

`Flared.Application` adds `Flared.TunnelSupervisor` to its `children` list:

```elixir
children = [Flared.TunnelSupervisor]
```

### TunnelSupervisor test cases

1. `start_link/1` starts the supervisor under its registered name.
2. `start_child/3` with default name and no routes registers the child under `Flared.Tunnel`, leaves it `:idle`, and returns `{:ok, pid}`.
3. `start_child/3` with an explicit `name` and a list of `routes` registers the child under that name and lands `:running`.
4. `start_child/3` with routes but `auto_start: false` in `opts` leaves the GenServer `:idle`.
5. `stop_child(pid)` terminates the running child.
6. `stop_child(name)` resolves the registered name and terminates the child.
7. `stop_child(name)` with no such registered name returns `{:error, :not_found}`.
8. Two children with distinct names can run concurrently under the supervisor.

### Auto-start test cases (in `tunnel_test.exs`)

10. `start_link/1` with `:routes` and `auto_start: true` (default) lands `:running` after init.
11. `start_link/1` with `:routes` but `auto_start: false` stays `:idle`; the caller can then call `open_tunnel/3`.
12. `start_link/1` without `:routes` stays `:idle` regardless of `:auto_start`.
13. `start_link/1` with `:routes` where the provisioner returns `{:error, _}` logs the error and stays `:idle` (no GenServer crash, no supervisor restart loop).

## Open Questions

None. Defaults locked at brainstorm:
- `max_attempts: 5`, `base: 1_000ms`, `cap: 30_000ms`, exponential.
- `:exhausted` keeps the GenServer alive (does not crash).
- `Flared.TunnelSupervisor` auto-starts under `Flared.Application`.
