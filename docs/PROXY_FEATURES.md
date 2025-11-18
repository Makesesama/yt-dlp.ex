# Proxy Support Features

This document describes the proxy functionality added to yt-dlp.ex, including proxy lists, automatic rotation, health tracking, and per-proxy timeout configuration.

## Features

### 1. Proxy Manager (`YtDlp.ProxyManager`)

A GenServer that manages a pool of proxies with the following capabilities:

- **Multiple Proxy Support**: Configure multiple HTTP/HTTPS/SOCKS proxies
- **Automatic Rotation**: Four rotation strategies available
- **Health Tracking**: Track success/failure rates for each proxy
- **Automatic Failover**: Proxies are disabled after exceeding failure threshold
- **Per-Proxy Timeouts**: Each proxy can have its own timeout configuration

### 2. Rotation Strategies

#### Round Robin (`:round_robin`)
Cycles through proxies in sequential order. Best for evenly distributing load.

```elixir
config :yt_dlp,
  proxy_rotation_strategy: :round_robin
```

#### Random (`:random`)
Randomly selects from available proxies. Best for unpredictable distribution.

```elixir
config :yt_dlp,
  proxy_rotation_strategy: :random
```

#### Least Used (`:least_used`)
Prefers proxies that haven't been used recently. Best for rotating between idle proxies.

```elixir
config :yt_dlp,
  proxy_rotation_strategy: :least_used
```

#### Healthiest (`:healthiest`)
Prefers proxies with the best success rate. Best for prioritizing reliable proxies.

```elixir
config :yt_dlp,
  proxy_rotation_strategy: :healthiest
```

### 3. Health Tracking

Each proxy maintains the following metrics:

- **Success Count**: Number of successful downloads
- **Failure Count**: Number of failed downloads
- **Last Used**: Timestamp of last use
- **Enabled Status**: Whether the proxy is currently active

Proxies are automatically disabled when they exceed the configured failure threshold.

### 4. Configuration Options

```elixir
config :yt_dlp,
  # List of proxies (can be strings or maps with timeout)
  proxies: [
    "http://proxy1.example.com:8080",
    %{url: "http://proxy2.example.com:8080", timeout: 45_000},
    "socks5://proxy3.example.com:1080"
  ],

  # Rotation strategy
  proxy_rotation_strategy: :round_robin,

  # Number of failures before disabling a proxy
  proxy_failure_threshold: 3,

  # Default timeout for proxies (milliseconds)
  proxy_default_timeout: 30_000
```

## Usage Examples

### Basic Proxy Usage

```elixir
# Download with a specific proxy
{:ok, download_id} = YtDlp.download(
  "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
  proxy: "http://proxy.example.com:8080"
)
```

### Automatic Proxy Rotation

```elixir
# Use ProxyManager for automatic rotation
{:ok, download_id} = YtDlp.download(
  "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
  use_proxy_manager: true
)
```

### Monitoring Proxy Health

```elixir
# Get statistics for all proxies
stats = YtDlp.ProxyManager.get_stats()

Enum.each(stats, fn proxy ->
  total = proxy.success_count + proxy.failure_count
  success_rate = if total > 0, do: proxy.success_count / total * 100, else: 0

  IO.puts("""
  #{proxy.url}:
    Success Rate: #{success_rate}%
    Total Requests: #{total}
    Enabled: #{proxy.enabled}
    Timeout: #{proxy.timeout}ms
  """)
end)
```

### Manual Proxy Management

```elixir
# Disable a problematic proxy
YtDlp.ProxyManager.disable_proxy("http://slow-proxy.example.com:8080")

# Re-enable a proxy
YtDlp.ProxyManager.enable_proxy("http://fixed-proxy.example.com:8080")

# Change rotation strategy at runtime
YtDlp.ProxyManager.set_strategy(:healthiest)

# Reset all statistics
YtDlp.ProxyManager.reset_stats()
```

## Architecture

```
YtDlp.download/2
    ↓
YtDlp.Downloader
    ↓
YtDlp.Command.download/3
    ↓
[Proxy Selection]
    ↓
ProxyManager.get_proxy()
    ├─→ Selects proxy based on strategy
    ├─→ Returns proxy with URL and timeout
    └─→ Updates last_used timestamp
    ↓
[Execute yt-dlp with --proxy flag]
    ↓
[Report Result]
    ↓
ProxyManager.report_success/failure()
    ├─→ Updates success/failure counters
    └─→ Disables proxy if threshold exceeded
```

## Benefits

1. **Reliability**: Automatic failover ensures downloads continue even if proxies fail
2. **Performance**: Per-proxy timeouts prevent slow proxies from blocking downloads
3. **Flexibility**: Multiple rotation strategies for different use cases
4. **Visibility**: Health tracking provides insights into proxy performance
5. **Control**: Manual enable/disable for maintenance or testing

## Implementation Details

### Files Added/Modified

1. **lib/yt_dlp/proxy_manager.ex** (NEW)
   - GenServer managing proxy pool
   - Health tracking and rotation logic

2. **lib/yt_dlp/command.ex** (MODIFIED)
   - Added proxy support to `run/2`
   - Integrated ProxyManager
   - Per-proxy timeout handling

3. **lib/yt_dlp/application.ex** (MODIFIED)
   - Added ProxyManager to supervision tree

4. **lib/yt_dlp.ex** (MODIFIED)
   - Updated documentation with proxy options

5. **test/yt_dlp/proxy_manager_test.exs** (NEW)
   - Comprehensive test coverage for proxy functionality

6. **examples/proxy_usage.exs** (NEW)
   - Complete examples demonstrating proxy features

### Supported Proxy Types

- **HTTP**: `http://proxy.example.com:8080`
- **HTTPS**: `https://proxy.example.com:8080`
- **SOCKS5**: `socks5://proxy.example.com:1080`

All proxy types supported by yt-dlp are supported by this library.

## Future Enhancements

Potential future improvements:

1. Proxy authentication support (username/password)
2. Proxy pool persistence across application restarts
3. Automatic proxy health checks (ping/test downloads)
4. Geolocation-based proxy selection
5. Bandwidth tracking per proxy
6. Proxy list import from external sources
