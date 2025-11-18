# Proxy Management Strategies

This guide explores different approaches to managing proxies in production environments, from simple configuration to advanced database-backed solutions.

## Overview of Approaches

| Approach | Best For | Pros | Cons |
|----------|----------|------|------|
| **Static Config** | Small, stable proxy lists | Simple, no dependencies | No runtime updates |
| **Database-Backed** | Large, dynamic proxy pools | Persistent, queryable, shareable | Adds DB overhead |
| **GenServer + Registry** | High-performance, isolated apps | Fast, low latency | Not persistent |
| **Hybrid (DB + Cache)** | Production systems | Best of both worlds | More complexity |

---

## 1. Static Configuration (Current Implementation)

**Best for:** Small proxy lists (< 20 proxies) that rarely change

```elixir
# config/config.exs
config :yt_dlp,
  proxies: [
    "http://proxy1.example.com:8080",
    "http://proxy2.example.com:8080"
  ]
```

### Pros
- ✅ Simple and fast
- ✅ No external dependencies
- ✅ Good for development/testing

### Cons
- ❌ Requires app restart to update
- ❌ Can't share across multiple nodes
- ❌ No persistence of health metrics

---

## 2. Database-Backed Proxy Management

**Best for:** Large proxy pools (100+), multi-node deployments, need for persistence

### Schema Design

```elixir
defmodule MyApp.Proxy do
  use Ecto.Schema
  import Ecto.Changeset

  schema "proxies" do
    field :url, :string
    field :timeout, :integer, default: 30_000
    field :proxy_type, :string  # "http", "https", "socks5"
    field :enabled, :boolean, default: true
    field :success_count, :integer, default: 0
    field :failure_count, :integer, default: 0
    field :last_used_at, :utc_datetime
    field :last_success_at, :utc_datetime
    field :last_failure_at, :utc_datetime
    field :consecutive_failures, :integer, default: 0
    field :region, :string  # For geo-based selection
    field :cost_per_gb, :decimal  # For cost tracking
    field :notes, :string

    timestamps()
  end

  def changeset(proxy, attrs) do
    proxy
    |> cast(attrs, [
      :url, :timeout, :proxy_type, :enabled,
      :success_count, :failure_count, :last_used_at,
      :consecutive_failures, :region, :cost_per_gb, :notes
    ])
    |> validate_required([:url, :proxy_type])
    |> validate_inclusion(:proxy_type, ["http", "https", "socks5"])
    |> unique_constraint(:url)
  end
end
```

### Migration

```elixir
defmodule MyApp.Repo.Migrations.CreateProxies do
  use Ecto.Migration

  def change do
    create table(:proxies) do
      add :url, :string, null: false
      add :timeout, :integer, default: 30_000
      add :proxy_type, :string, null: false
      add :enabled, :boolean, default: true
      add :success_count, :integer, default: 0
      add :failure_count, :integer, default: 0
      add :last_used_at, :utc_datetime
      add :last_success_at, :utc_datetime
      add :last_failure_at, :utc_datetime
      add :consecutive_failures, :integer, default: 0
      add :region, :string
      add :cost_per_gb, :decimal
      add :notes, :text

      timestamps()
    end

    create unique_index(:proxies, [:url])
    create index(:proxies, [:enabled])
    create index(:proxies, [:proxy_type])
    create index(:proxies, [:region])
  end
end
```

### Database-Backed ProxyManager

```elixir
defmodule MyApp.ProxyManager.DB do
  @moduledoc """
  Database-backed proxy manager with ETS cache for performance.

  Syncs with database periodically and caches active proxies in ETS
  for fast access. Updates are written to DB asynchronously.
  """

  use GenServer
  require Logger
  alias MyApp.{Repo, Proxy}
  import Ecto.Query

  @cache_table :proxy_cache
  @sync_interval :timer.minutes(5)  # Sync with DB every 5 minutes
  @batch_update_interval :timer.seconds(30)  # Batch updates every 30s

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_proxy(strategy \\ :round_robin) do
    GenServer.call(__MODULE__, {:get_proxy, strategy})
  end

  def report_success(proxy_url) do
    GenServer.cast(__MODULE__, {:report_success, proxy_url})
  end

  def report_failure(proxy_url) do
    GenServer.cast(__MODULE__, {:report_failure, proxy_url})
  end

  def sync_from_db do
    GenServer.cast(__MODULE__, :sync_from_db)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])

    # Load proxies from database
    load_proxies_from_db()

    # Schedule periodic sync
    Process.send_after(self(), :sync_from_db, @sync_interval)
    Process.send_after(self(), :flush_updates, @batch_update_interval)

    state = %{
      current_index: 0,
      pending_updates: %{},  # Batch updates before writing to DB
      strategy: :round_robin,
      failure_threshold: 3
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get_proxy, strategy}, _from, state) do
    case select_proxy_from_cache(strategy, state) do
      {:ok, proxy, new_state} ->
        # Update last_used in cache
        :ets.update_element(@cache_table, proxy.url, {6, DateTime.utc_now()})

        # Queue DB update (batched)
        queue_update(state, proxy.url, :last_used, DateTime.utc_now())

        {:reply, {:ok, proxy}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      :ets.tab2list(@cache_table)
      |> Enum.map(fn {_url, proxy} -> proxy end)

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:report_success, proxy_url}, state) do
    case :ets.lookup(@cache_table, proxy_url) do
      [{^proxy_url, proxy}] ->
        updated_proxy = %{
          proxy
          | success_count: proxy.success_count + 1,
            consecutive_failures: 0,
            last_success_at: DateTime.utc_now()
        }

        :ets.insert(@cache_table, {proxy_url, updated_proxy})

        # Queue DB update
        queue_update(state, proxy_url, :success, updated_proxy)

      [] ->
        Logger.warning("Proxy not found in cache: #{proxy_url}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:report_failure, proxy_url}, state) do
    case :ets.lookup(@cache_table, proxy_url) do
      [{^proxy_url, proxy}] ->
        consecutive = proxy.consecutive_failures + 1
        enabled = consecutive < state.failure_threshold

        updated_proxy = %{
          proxy
          | failure_count: proxy.failure_count + 1,
            consecutive_failures: consecutive,
            enabled: enabled,
            last_failure_at: DateTime.utc_now()
        }

        :ets.insert(@cache_table, {proxy_url, updated_proxy})

        # Queue DB update
        queue_update(state, proxy_url, :failure, updated_proxy)

        if not enabled and proxy.enabled do
          Logger.warning("Proxy disabled due to failures: #{proxy_url}")
        end

      [] ->
        Logger.warning("Proxy not found in cache: #{proxy_url}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:sync_from_db, state) do
    load_proxies_from_db()
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync_from_db, state) do
    load_proxies_from_db()
    Process.send_after(self(), :sync_from_db, @sync_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush_updates, state) do
    flush_pending_updates(state)
    Process.send_after(self(), :flush_updates, @batch_update_interval)
    {:noreply, %{state | pending_updates: %{}}}
  end

  # Private Functions

  defp load_proxies_from_db do
    proxies =
      Proxy
      |> where([p], p.enabled == true)
      |> Repo.all()
      |> Enum.map(&proxy_to_map/1)

    # Clear and reload cache
    :ets.delete_all_objects(@cache_table)

    Enum.each(proxies, fn proxy ->
      :ets.insert(@cache_table, {proxy.url, proxy})
    end)

    Logger.info("Loaded #{length(proxies)} proxies from database")
  end

  defp proxy_to_map(proxy) do
    %{
      url: proxy.url,
      timeout: proxy.timeout,
      success_count: proxy.success_count,
      failure_count: proxy.failure_count,
      last_used_at: proxy.last_used_at,
      enabled: proxy.enabled,
      consecutive_failures: proxy.consecutive_failures
    }
  end

  defp select_proxy_from_cache(strategy, state) do
    enabled_proxies =
      :ets.tab2list(@cache_table)
      |> Enum.map(fn {_url, proxy} -> proxy end)
      |> Enum.filter(& &1.enabled)

    if Enum.empty?(enabled_proxies) do
      {:error, :no_proxies}
    else
      case strategy do
        :round_robin ->
          proxy = Enum.at(enabled_proxies, rem(state.current_index, length(enabled_proxies)))
          {:ok, proxy, %{state | current_index: state.current_index + 1}}

        :random ->
          {:ok, Enum.random(enabled_proxies), state}

        :healthiest ->
          proxy =
            Enum.max_by(enabled_proxies, fn p ->
              total = p.success_count + p.failure_count
              if total == 0, do: 1.0, else: p.success_count / total
            end)

          {:ok, proxy, state}

        :least_used ->
          proxy =
            Enum.min_by(enabled_proxies, fn p ->
              case p.last_used_at do
                nil -> 0
                dt -> DateTime.to_unix(dt)
              end
            end)

          {:ok, proxy, state}
      end
    end
  end

  defp queue_update(state, proxy_url, type, value) do
    updates = Map.get(state.pending_updates, proxy_url, [])
    new_updates = [{type, value} | updates]
    %{state | pending_updates: Map.put(state.pending_updates, proxy_url, new_updates)}
  end

  defp flush_pending_updates(state) do
    Enum.each(state.pending_updates, fn {proxy_url, updates} ->
      Task.start(fn ->
        apply_updates_to_db(proxy_url, updates)
      end)
    end)
  end

  defp apply_updates_to_db(proxy_url, updates) do
    # Consolidate updates
    attrs =
      Enum.reduce(updates, %{}, fn
        {:success, proxy}, acc ->
          Map.merge(acc, %{
            success_count: proxy.success_count,
            consecutive_failures: 0,
            last_success_at: proxy.last_success_at
          })

        {:failure, proxy}, acc ->
          Map.merge(acc, %{
            failure_count: proxy.failure_count,
            consecutive_failures: proxy.consecutive_failures,
            enabled: proxy.enabled,
            last_failure_at: proxy.last_failure_at
          })

        {:last_used, datetime}, acc ->
          Map.put(acc, :last_used_at, datetime)

        _, acc ->
          acc
      end)

    Proxy
    |> Repo.get_by(url: proxy_url)
    |> case do
      nil ->
        Logger.warning("Proxy not found in DB: #{proxy_url}")

      proxy ->
        proxy
        |> Proxy.changeset(attrs)
        |> Repo.update()
    end
  end
end
```

### Usage

```elixir
# Add proxies via seeds or admin interface
Repo.insert!(%Proxy{
  url: "http://proxy1.example.com:8080",
  proxy_type: "http",
  timeout: 30_000,
  region: "us-east",
  enabled: true
})

# Use in your application
{:ok, proxy} = MyApp.ProxyManager.DB.get_proxy(:healthiest)

# Reports are automatically batched and written to DB
MyApp.ProxyManager.DB.report_success(proxy.url)
```

### Pros
- ✅ Persistent across restarts
- ✅ Queryable (analytics, reporting)
- ✅ Shareable across multiple nodes
- ✅ Can be updated via admin interface
- ✅ Batched writes reduce DB load

### Cons
- ❌ Adds database dependency
- ❌ Slightly higher latency (mitigated by ETS cache)
- ❌ More complex

---

## 3. GenServer + Registry (High Performance)

**Best for:** Single-node apps, maximum performance, isolated proxy pools per service

```elixir
defmodule MyApp.ProxyPool.Supervisor do
  @moduledoc """
  Supervises multiple proxy pools using Registry for lookups.
  Each pool is isolated and can have its own configuration.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Registry for looking up proxy pools
      {Registry, keys: :unique, name: MyApp.ProxyRegistry},

      # Multiple proxy pools for different services
      {MyApp.ProxyPool, name: {:via, Registry, {MyApp.ProxyRegistry, :downloads}},
       proxies: Application.get_env(:my_app, :download_proxies)},

      {MyApp.ProxyPool, name: {:via, Registry, {MyApp.ProxyRegistry, :metadata}},
       proxies: Application.get_env(:my_app, :metadata_proxies)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule MyApp.ProxyPool do
  @moduledoc """
  Individual proxy pool GenServer registered via Registry.
  Fast, isolated, and can be dynamically started/stopped.
  """

  use GenServer
  require Logger

  # Client API

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get_proxy(pool_name \\ :downloads) do
    case Registry.lookup(MyApp.ProxyRegistry, pool_name) do
      [{pid, _}] -> GenServer.call(pid, :get_proxy)
      [] -> {:error, :pool_not_found}
    end
  end

  def report_success(pool_name, proxy_url) do
    case Registry.lookup(MyApp.ProxyRegistry, pool_name) do
      [{pid, _}] -> GenServer.cast(pid, {:report_success, proxy_url})
      [] -> :ok
    end
  end

  def report_failure(pool_name, proxy_url) do
    case Registry.lookup(MyApp.ProxyRegistry, pool_name) do
      [{pid, _}] -> GenServer.cast(pid, {:report_failure, proxy_url})
      [] -> :ok
    end
  end

  # Add proxy at runtime
  def add_proxy(pool_name, proxy_config) do
    case Registry.lookup(MyApp.ProxyRegistry, pool_name) do
      [{pid, _}] -> GenServer.call(pid, {:add_proxy, proxy_config})
      [] -> {:error, :pool_not_found}
    end
  end

  # Remove proxy at runtime
  def remove_proxy(pool_name, proxy_url) do
    case Registry.lookup(MyApp.ProxyRegistry, pool_name) do
      [{pid, _}] -> GenServer.call(pid, {:remove_proxy, proxy_url})
      [] -> {:error, :pool_not_found}
    end
  end

  # Server implementation similar to ProxyManager...
  # (Same as current implementation but with add/remove support)
end
```

### Usage

```elixir
# Use different proxy pools for different services
{:ok, proxy} = MyApp.ProxyPool.get_proxy(:downloads)
{:ok, proxy} = MyApp.ProxyPool.get_proxy(:metadata)

# Add proxy at runtime
MyApp.ProxyPool.add_proxy(:downloads, "http://new-proxy.com:8080")

# Remove proxy at runtime
MyApp.ProxyPool.remove_proxy(:downloads, "http://bad-proxy.com:8080")
```

### Pros
- ✅ Extremely fast (no DB, direct process calls)
- ✅ Isolated pools per service
- ✅ Dynamic proxy management
- ✅ No external dependencies

### Cons
- ❌ Not persistent (lost on restart)
- ❌ Can't share across nodes easily
- ❌ State only in memory

---

## 4. Hybrid Approach (Recommended for Production)

**Best for:** Production systems needing both performance and persistence

Combines database persistence with ETS/Registry for performance:

```elixir
defmodule MyApp.ProxyManager.Hybrid do
  @moduledoc """
  Hybrid proxy manager combining DB persistence with ETS performance.

  Architecture:
  - Load proxies from DB on startup
  - Cache in ETS for fast reads
  - Batch writes to DB every 30s
  - Periodic sync from DB every 5 minutes
  - Pub/Sub for multi-node sync
  """

  use GenServer
  require Logger

  # Uses Phoenix.PubSub for multi-node synchronization
  @pubsub MyApp.PubSub
  @topic "proxy_updates"

  # ... (Implementation combines DB-backed + Registry approaches)

  def init(opts) do
    # Subscribe to proxy updates from other nodes
    Phoenix.PubSub.subscribe(@pubsub, @topic)

    # ... rest of init
  end

  # When proxy state changes, broadcast to other nodes
  defp broadcast_update(proxy_url, update_type) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:proxy_update, proxy_url, update_type})
  end

  # Handle updates from other nodes
  def handle_info({:proxy_update, proxy_url, update_type}, state) do
    # Update local cache
    # ...
    {:noreply, state}
  end
end
```

### Features
- ✅ Fast reads from ETS
- ✅ Persistent to database
- ✅ Multi-node synchronization
- ✅ Batched writes
- ✅ Real-time updates across nodes

---

## Recommended Architecture by Scale

### Small Scale (< 20 proxies, single node)
```
Static Config → ProxyManager (current implementation)
```

### Medium Scale (20-100 proxies, 2-5 nodes)
```
Database → ProxyManager.DB (with ETS cache)
```

### Large Scale (100+ proxies, 5+ nodes)
```
Database → ProxyManager.Hybrid (DB + ETS + PubSub)
          ↓
     Multiple Pools via Registry
```

### Enterprise Scale (1000+ proxies)
```
External Service (Redis/Consul) → ProxyManager.Distributed
                                     ↓
                            Multiple Pools per Service
                                     ↓
                            Health Check Workers
                                     ↓
                              Analytics Pipeline
```

---

## Implementation Recommendation

For your use case, I'd recommend:

1. **Start with Database-Backed approach** if:
   - You have > 50 proxies
   - Need to update proxies without redeploying
   - Want analytics and reporting
   - Running multiple nodes

2. **Use Registry approach** if:
   - Maximum performance is critical
   - Single node deployment
   - Proxies rarely change
   - Can tolerate losing state on restart

3. **Go Hybrid** if:
   - Production system with high traffic
   - Need both performance and persistence
   - Multi-node deployment
   - Want real-time synchronization

Would you like me to implement any of these approaches for your library?
