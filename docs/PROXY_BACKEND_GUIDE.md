# Proxy Backend Integration Guide

This guide explains how to integrate your own proxy management system with yt-dlp.ex.

## Philosophy

The library provides a **pluggable architecture** for proxy management:

- **Built-in default**: Simple in-memory proxy manager for quick setup
- **Your implementation**: Bring your own database, Redis, API, or any custom logic
- **Clean interface**: Implement 3 simple callbacks, no library internals needed

## Quick Start

### 1. Implement the Behaviour

Create a module that implements `YtDlp.ProxyBackend`:

```elixir
defmodule MyApp.ProxyBackend do
  @behaviour YtDlp.ProxyBackend

  @impl true
  def get_proxy(opts) do
    # Return next proxy
    {:ok, %{url: "http://proxy.example.com:8080", timeout: 30_000}}
  end

  @impl true
  def report_success(proxy_url, opts) do
    # Track success
    :ok
  end

  @impl true
  def report_failure(proxy_url, opts) do
    # Track failure
    :ok
  end
end
```

### 2. Configure It

```elixir
# config/config.exs
config :yt_dlp,
  proxy_backend: MyApp.ProxyBackend,
  proxy_backend_opts: [
    # Your custom options
    pool_name: :main,
    failure_threshold: 3
  ]
```

### 3. Use It

```elixir
# The library automatically uses your backend
{:ok, download_id} = YtDlp.download(url, use_proxy_manager: true)

# That's it! Your backend is called automatically
```

## The Behaviour

### Required Callbacks

#### `get_proxy/1`

```elixir
@callback get_proxy(opts :: keyword()) ::
  {:ok, %{url: String.t(), timeout: pos_integer()}} | {:error, term()}
```

**Purpose**: Return the next proxy to use

**Returns**:
- `{:ok, proxy}` - A map with at least `:url` and `:timeout` keys
- `{:error, reason}` - When no proxy is available

**Example**:
```elixir
@impl true
def get_proxy(opts) do
  case MyApp.ProxyDB.get_next_available() do
    nil -> {:error, :no_proxies}
    proxy -> {:ok, %{url: proxy.url, timeout: proxy.timeout}}
  end
end
```

#### `report_success/2`

```elixir
@callback report_success(proxy_url :: String.t(), opts :: keyword()) :: :ok
```

**Purpose**: Called after successful download through a proxy

**Example**:
```elixir
@impl true
def report_success(proxy_url, _opts) do
  from(p in Proxy, where: p.url == ^proxy_url)
  |> Repo.update_all(inc: [success_count: 1])

  :ok
end
```

#### `report_failure/2`

```elixir
@callback report_failure(proxy_url :: String.t(), opts :: keyword()) :: :ok
```

**Purpose**: Called after failed download through a proxy

**Example**:
```elixir
@impl true
def report_failure(proxy_url, opts) do
  threshold = Keyword.get(opts, :failure_threshold, 3)

  proxy = Repo.get_by!(Proxy, url: proxy_url)
  new_failures = proxy.failure_count + 1

  proxy
  |> change(%{
    failure_count: new_failures,
    enabled: new_failures < threshold
  })
  |> Repo.update!()

  :ok
end
```

### Optional Callbacks

#### `get_stats/1`

```elixir
@callback get_stats(opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
```

**Purpose**: Return statistics about proxies (optional)

```elixir
@impl true
def get_stats(_opts) do
  proxies = Repo.all(Proxy)
  stats = Enum.map(proxies, &Map.take(&1, [:url, :success_count, :failure_count]))
  {:ok, stats}
end
```

## Complete Examples

### Example 1: Database-Backed (Ecto)

```elixir
defmodule MyApp.ProxyBackend.Database do
  @behaviour YtDlp.ProxyBackend

  alias MyApp.{Repo, Proxy}
  import Ecto.Query

  @impl true
  def get_proxy(opts) do
    strategy = Keyword.get(opts, :strategy, :round_robin)

    query = case strategy do
      :round_robin ->
        from p in Proxy,
          where: p.enabled == true,
          order_by: [asc: p.last_used_at],
          limit: 1

      :healthiest ->
        from p in Proxy,
          where: p.enabled == true,
          order_by: [desc: fragment("success_count::float / NULLIF(success_count + failure_count, 0)")],
          limit: 1
    end

    case Repo.one(query) do
      nil ->
        {:error, :no_proxies}

      proxy ->
        # Update last_used_at
        proxy
        |> Ecto.Changeset.change(last_used_at: DateTime.utc_now())
        |> Repo.update()

        {:ok, %{url: proxy.url, timeout: proxy.timeout}}
    end
  end

  @impl true
  def report_success(proxy_url, _opts) do
    from(p in Proxy, where: p.url == ^proxy_url)
    |> Repo.update_all(inc: [success_count: 1], set: [last_success_at: DateTime.utc_now()])

    :ok
  end

  @impl true
  def report_failure(proxy_url, opts) do
    threshold = Keyword.get(opts, :failure_threshold, 3)

    proxy = Repo.get_by!(Proxy, url: proxy_url)
    new_failures = proxy.failure_count + 1

    proxy
    |> Ecto.Changeset.change(%{
      failure_count: new_failures,
      consecutive_failures: proxy.consecutive_failures + 1,
      enabled: new_failures < threshold,
      last_failure_at: DateTime.utc_now()
    })
    |> Repo.update()

    :ok
  end

  @impl true
  def get_stats(_opts) do
    stats = Repo.all(from p in Proxy, select: %{
      url: p.url,
      success_count: p.success_count,
      failure_count: p.failure_count,
      enabled: p.enabled,
      last_used_at: p.last_used_at
    })

    {:ok, stats}
  end
end
```

### Example 2: Redis-Backed (Distributed)

```elixir
defmodule MyApp.ProxyBackend.Redis do
  @behaviour YtDlp.ProxyBackend

  @redis_pool MyApp.RedisPool

  @impl true
  def get_proxy(opts) do
    pool = Keyword.get(opts, :pool_name, "default")

    # Pop from available queue
    case Redix.command(@redis_pool, ["LPOP", "proxies:#{pool}:available"]) do
      {:ok, nil} ->
        {:error, :no_proxies}

      {:ok, proxy_json} ->
        proxy = Jason.decode!(proxy_json)

        # Push back to end (rotation)
        Redix.command(@redis_pool, ["RPUSH", "proxies:#{pool}:available", proxy_json])

        # Update usage timestamp
        Redix.command(@redis_pool, ["HSET", "proxies:#{pool}:last_used", proxy["url"], DateTime.utc_now() |> DateTime.to_unix()])

        {:ok, %{url: proxy["url"], timeout: proxy["timeout"]}}
    end
  end

  @impl true
  def report_success(proxy_url, opts) do
    pool = Keyword.get(opts, :pool_name, "default")
    Redix.command(@redis_pool, ["HINCRBY", "proxies:#{pool}:success", proxy_url, 1])
    :ok
  end

  @impl true
  def report_failure(proxy_url, opts) do
    pool = Keyword.get(opts, :pool_name, "default")
    threshold = Keyword.get(opts, :failure_threshold, 3)

    {:ok, failures} = Redix.command(@redis_pool, ["HINCRBY", "proxies:#{pool}:failures", proxy_url, 1])
    failures_int = String.to_integer(failures)

    # Disable if threshold exceeded
    if failures_int >= threshold do
      Redix.command(@redis_pool, ["SREM", "proxies:#{pool}:enabled", proxy_url])
    end

    :ok
  end
end
```

### Example 3: External API

```elixir
defmodule MyApp.ProxyBackend.API do
  @behaviour YtDlp.ProxyBackend

  @impl true
  def get_proxy(opts) do
    api_key = Keyword.fetch!(opts, :api_key)

    case Req.get("https://api.proxyservice.com/v1/proxy",
           headers: [{"authorization", "Bearer #{api_key}"}]) do
      {:ok, %{status: 200, body: %{"proxy" => proxy}}} ->
        {:ok, %{
          url: "#{proxy["protocol"]}://#{proxy["host"]}:#{proxy["port"]}",
          timeout: proxy["timeout"] || 30_000
        }}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def report_success(proxy_url, opts) do
    api_key = Keyword.fetch!(opts, :api_key)

    Req.post("https://api.proxyservice.com/v1/report",
      headers: [{"authorization", "Bearer #{api_key}"}],
      json: %{proxy_url: proxy_url, status: "success"}
    )

    :ok
  end

  @impl true
  def report_failure(proxy_url, opts) do
    api_key = Keyword.fetch!(opts, :api_key)

    Req.post("https://api.proxyservice.com/v1/report",
      headers: [{"authorization", "Bearer #{api_key}"}],
      json: %{proxy_url: proxy_url, status: "failure"}
    )

    :ok
  end
end
```

## Testing Your Backend

```elixir
# Test backend directly
{:ok, proxy} = MyApp.ProxyBackend.get_proxy([])
assert %{url: url, timeout: timeout} = proxy
assert is_binary(url)
assert is_integer(timeout)

MyApp.ProxyBackend.report_success(proxy.url, [])
MyApp.ProxyBackend.report_failure(proxy.url, [])

# Test with YtDlp
config :yt_dlp,
  proxy_backend: MyApp.ProxyBackend,
  proxy_backend_opts: [test: true]

{:ok, download_id} = YtDlp.download(url, use_proxy_manager: true)
# Your backend methods are called automatically
```

## Best Practices

### 1. Handle Errors Gracefully

```elixir
@impl true
def get_proxy(opts) do
  try do
    # Your logic
  rescue
    e ->
      Logger.error("Failed to get proxy: #{inspect(e)}")
      {:error, :backend_error}
  end
end
```

### 2. Use Async Updates

```elixir
@impl true
def report_success(proxy_url, _opts) do
  Task.start(fn ->
    # DB write in background
    update_stats(proxy_url, :success)
  end)
  :ok
end
```

### 3. Cache When Possible

```elixir
# Keep frequently accessed data in ETS
@impl true
def get_proxy(opts) do
  case :ets.lookup(:proxy_cache, :next) do
    [{:next, proxy}] -> {:ok, proxy}
    [] -> load_from_db_and_cache()
  end
end
```

### 4. Log Important Events

```elixir
@impl true
def report_failure(proxy_url, opts) do
  threshold = Keyword.get(opts, :failure_threshold, 3)
  failures = increment_failures(proxy_url)

  if failures >= threshold do
    Logger.warning("Proxy disabled due to failures: #{proxy_url}")
  end

  :ok
end
```

## Migration Guide

### From Default to Custom Backend

**Before** (using built-in):
```elixir
config :yt_dlp,
  proxies: ["http://proxy1.com:8080", "http://proxy2.com:8080"]
```

**After** (using custom):
```elixir
config :yt_dlp,
  proxy_backend: MyApp.ProxyBackend,
  proxy_backend_opts: []

# Load your proxies into your system
MyApp.ProxyBackend.seed_proxies([
  "http://proxy1.com:8080",
  "http://proxy2.com:8080"
])
```

No code changes needed! All downloads with `use_proxy_manager: true` automatically use your backend.

## FAQ

**Q: Can I still use the default ProxyManager?**
A: Yes! If no `proxy_backend` is configured, the library uses the built-in `YtDlp.ProxyManager`.

**Q: Can I pass options at runtime?**
A: Yes, merge them in your implementation:
```elixir
def get_proxy(opts) do
  region = Keyword.get(opts, :region, "us-east")
  # Use region to filter proxies
end

# Usage:
YtDlp.download(url,
  use_proxy_manager: true,
  proxy_backend_opts: [region: "eu-west"]
)
```

**Q: How do I test without yt-dlp?**
A: Just call your backend directly:
```elixir
{:ok, proxy} = MyApp.ProxyBackend.get_proxy([])
MyApp.ProxyBackend.report_success(proxy.url, [])
```

**Q: Can I use multiple backends?**
A: Not simultaneously in one application, but you can implement a backend that delegates to multiple sources.

**Q: What about performance?**
A: The behaviour callbacks add ~1μs overhead. Use caching (ETS) for frequently accessed data.

## See Also

- `lib/yt_dlp/proxy_backend.ex` - Behaviour definition
- `lib/yt_dlp/proxy_manager.ex` - Default implementation
- `examples/custom_proxy_backend.exs` - Complete examples
- `PROXY_MANAGEMENT_STRATEGIES.md` - Architecture patterns
