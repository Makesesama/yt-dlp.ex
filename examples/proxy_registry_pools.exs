#!/usr/bin/env elixir

# Registry-Based Proxy Pools Example
#
# This example demonstrates using multiple isolated proxy pools
# with Registry for high-performance, service-specific proxy management.

Mix.install([
  {:yt_dlp, path: "."}
])

defmodule ProxyRegistryExample do
  @moduledoc """
  Example of Registry-based proxy pools for yt-dlp.ex

  Use cases:
  - Different proxy pools for different video sources
  - Separate proxies for downloads vs metadata fetching
  - Per-user or per-tenant proxy isolation
  """

  defmodule ProxyPool do
    @moduledoc """
    Individual proxy pool GenServer.
    Can be started dynamically with different configurations.
    """

    use GenServer
    require Logger

    # Client API

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def get_proxy(pool_pid) when is_pid(pool_pid) do
      GenServer.call(pool_pid, :get_proxy)
    end

    def report_success(pool_pid, proxy_url) when is_pid(pool_pid) do
      GenServer.cast(pool_pid, {:report_success, proxy_url})
    end

    def report_failure(pool_pid, proxy_url) when is_pid(pool_pid) do
      GenServer.cast(pool_pid, {:report_failure, proxy_url})
    end

    def add_proxy(pool_pid, proxy_config) when is_pid(pool_pid) do
      GenServer.call(pool_pid, {:add_proxy, proxy_config})
    end

    def remove_proxy(pool_pid, proxy_url) when is_pid(pool_pid) do
      GenServer.call(pool_pid, {:remove_proxy, proxy_url})
    end

    def get_stats(pool_pid) when is_pid(pool_pid) do
      GenServer.call(pool_pid, :get_stats)
    end

    # Server Callbacks

    @impl true
    def init(opts) do
      proxies = Keyword.get(opts, :proxies, [])
      strategy = Keyword.get(opts, :strategy, :round_robin)
      failure_threshold = Keyword.get(opts, :failure_threshold, 3)
      default_timeout = Keyword.get(opts, :default_timeout, 30_000)

      normalized_proxies = Enum.map(proxies, &normalize_proxy(&1, default_timeout))

      state = %{
        proxies: normalized_proxies,
        strategy: strategy,
        failure_threshold: failure_threshold,
        current_index: 0,
        pool_name: Keyword.get(opts, :pool_name, :default)
      }

      Logger.info(
        "ProxyPool #{state.pool_name} started with #{length(normalized_proxies)} proxies"
      )

      {:ok, state}
    end

    @impl true
    def handle_call(:get_proxy, _from, state) do
      case select_proxy(state) do
        {:ok, proxy, new_state} ->
          {:reply, {:ok, proxy}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end

    @impl true
    def handle_call({:add_proxy, proxy_config}, _from, state) do
      proxy = normalize_proxy(proxy_config, 30_000)

      # Check if proxy already exists
      if Enum.any?(state.proxies, &(&1.url == proxy.url)) do
        {:reply, {:error, :already_exists}, state}
      else
        new_proxies = [proxy | state.proxies]
        Logger.info("Added proxy to pool #{state.pool_name}: #{proxy.url}")
        {:reply, :ok, %{state | proxies: new_proxies}}
      end
    end

    @impl true
    def handle_call({:remove_proxy, proxy_url}, _from, state) do
      new_proxies = Enum.reject(state.proxies, &(&1.url == proxy_url))

      if length(new_proxies) == length(state.proxies) do
        {:reply, {:error, :not_found}, state}
      else
        Logger.info("Removed proxy from pool #{state.pool_name}: #{proxy_url}")
        {:reply, :ok, %{state | proxies: new_proxies}}
      end
    end

    @impl true
    def handle_call(:get_stats, _from, state) do
      {:reply, state.proxies, state}
    end

    @impl true
    def handle_cast({:report_success, proxy_url}, state) do
      new_proxies =
        Enum.map(state.proxies, fn proxy ->
          if proxy.url == proxy_url do
            %{proxy | success_count: proxy.success_count + 1}
          else
            proxy
          end
        end)

      {:noreply, %{state | proxies: new_proxies}}
    end

    @impl true
    def handle_cast({:report_failure, proxy_url}, state) do
      new_proxies = Enum.map(state.proxies, &update_failure(&1, proxy_url, state))
      {:noreply, %{state | proxies: new_proxies}}
    end

    # Private Functions

    defp normalize_proxy(proxy, default_timeout) when is_binary(proxy) do
      %{
        url: proxy,
        timeout: default_timeout,
        success_count: 0,
        failure_count: 0,
        last_used: nil,
        enabled: true
      }
    end

    defp normalize_proxy(%{url: url} = proxy, default_timeout) do
      %{
        url: url,
        timeout: Map.get(proxy, :timeout, default_timeout),
        success_count: 0,
        failure_count: 0,
        last_used: nil,
        enabled: true
      }
    end

    defp select_proxy(%{proxies: []} = state), do: {:error, :no_proxies}

    defp select_proxy(state) do
      enabled = Enum.filter(state.proxies, & &1.enabled)

      if Enum.empty?(enabled) do
        {:error, :no_proxies}
      else
        case state.strategy do
          :round_robin ->
            proxy = Enum.at(enabled, rem(state.current_index, length(enabled)))
            updated = %{proxy | last_used: DateTime.utc_now()}
            new_proxies = update_proxy_in_list(state.proxies, proxy.url, updated)

            {:ok, updated,
             %{state | proxies: new_proxies, current_index: state.current_index + 1}}

          :random ->
            proxy = Enum.random(enabled)
            updated = %{proxy | last_used: DateTime.utc_now()}
            new_proxies = update_proxy_in_list(state.proxies, proxy.url, updated)
            {:ok, updated, %{state | proxies: new_proxies}}

          _ ->
            proxy = Enum.at(enabled, 0)
            {:ok, proxy, state}
        end
      end
    end

    defp update_proxy_in_list(proxies, proxy_url, updated_proxy) do
      Enum.map(proxies, fn proxy ->
        if proxy.url == proxy_url, do: updated_proxy, else: proxy
      end)
    end

    defp update_failure(proxy, proxy_url, state) do
      if proxy.url == proxy_url do
        new_failure_count = proxy.failure_count + 1
        enabled = new_failure_count < state.failure_threshold

        if not enabled and proxy.enabled do
          Logger.warning(
            "Proxy disabled in pool #{state.pool_name}: #{proxy_url} (#{new_failure_count} failures)"
          )
        end

        %{proxy | failure_count: new_failure_count, enabled: enabled}
      else
        proxy
      end
    end
  end

  defmodule ProxyPoolSupervisor do
    @moduledoc """
    Dynamic supervisor for proxy pools using Registry.
    """

    use DynamicSupervisor

    def start_link(opts) do
      DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(_opts) do
      DynamicSupervisor.init(strategy: :one_for_one)
    end

    def start_pool(pool_name, pool_opts) do
      child_spec = %{
        id: {ProxyPool, pool_name},
        start: {
          ProxyPool,
          :start_link,
          [
            Keyword.merge(pool_opts,
              name: {:via, Registry, {ProxyPoolRegistry, pool_name}},
              pool_name: pool_name
            )
          ]
        },
        restart: :transient
      }

      DynamicSupervisor.start_child(__MODULE__, child_spec)
    end

    def stop_pool(pool_name) do
      case Registry.lookup(ProxyPoolRegistry, pool_name) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(__MODULE__, pid)

        [] ->
          {:error, :not_found}
      end
    end

    def get_pool(pool_name) do
      case Registry.lookup(ProxyPoolRegistry, pool_name) do
        [{pid, _}] -> {:ok, pid}
        [] -> {:error, :not_found}
      end
    end
  end

  # Helper module for easier access

  defmodule ProxyPools do
    @moduledoc """
    Convenience functions for working with proxy pools.
    """

    def get_proxy(pool_name) do
      with {:ok, pid} <- ProxyPoolSupervisor.get_pool(pool_name) do
        ProxyPool.get_proxy(pid)
      end
    end

    def report_success(pool_name, proxy_url) do
      with {:ok, pid} <- ProxyPoolSupervisor.get_pool(pool_name) do
        ProxyPool.report_success(pid, proxy_url)
      end
    end

    def report_failure(pool_name, proxy_url) do
      with {:ok, pid} <- ProxyPoolSupervisor.get_pool(pool_name) do
        ProxyPool.report_failure(pid, proxy_url)
      end
    end

    def add_proxy(pool_name, proxy_config) do
      with {:ok, pid} <- ProxyPoolSupervisor.get_pool(pool_name) do
        ProxyPool.add_proxy(pid, proxy_config)
      end
    end

    def get_stats(pool_name) do
      with {:ok, pid} <- ProxyPoolSupervisor.get_pool(pool_name) do
        ProxyPool.get_stats(pid)
      end
    end
  end

  # Demo

  def run_demo do
    IO.puts("""
    =====================================
    Registry-Based Proxy Pools Demo
    =====================================

    Starting Registry and Dynamic Supervisor...
    """)

    # Start infrastructure
    {:ok, _} = Registry.start_link(keys: :unique, name: ProxyPoolRegistry)
    {:ok, _} = ProxyPoolSupervisor.start_link([])

    IO.puts("✓ Registry and Supervisor started\n")

    # Create different pools for different use cases
    create_pools()

    # Demonstrate usage
    demonstrate_usage()

    # Show pool isolation
    demonstrate_isolation()

    # Dynamic pool management
    demonstrate_dynamic_pools()
  end

  defp create_pools do
    IO.puts("Creating specialized proxy pools...\n")

    # Pool for YouTube downloads
    {:ok, _} =
      ProxyPoolSupervisor.start_pool(:youtube,
        proxies: [
          "http://youtube-proxy1.example.com:8080",
          "http://youtube-proxy2.example.com:8080"
        ],
        strategy: :round_robin
      )

    IO.puts("✓ Created :youtube pool with 2 proxies")

    # Pool for metadata fetching (different proxies)
    {:ok, _} =
      ProxyPoolSupervisor.start_pool(:metadata,
        proxies: [
          "http://meta-proxy1.example.com:8080",
          "http://meta-proxy2.example.com:8080",
          "http://meta-proxy3.example.com:8080"
        ],
        strategy: :random
      )

    IO.puts("✓ Created :metadata pool with 3 proxies")

    # Pool for premium users (better proxies, higher limits)
    {:ok, _} =
      ProxyPoolSupervisor.start_pool(:premium,
        proxies: [
          %{url: "http://premium-proxy1.example.com:8080", timeout: 60_000},
          %{url: "http://premium-proxy2.example.com:8080", timeout: 60_000}
        ],
        strategy: :healthiest,
        failure_threshold: 5
      )

    IO.puts("✓ Created :premium pool with 2 high-performance proxies\n")
  end

  defp demonstrate_usage do
    IO.puts("Demonstrating usage patterns...\n")

    # Get proxy from YouTube pool
    {:ok, proxy} = ProxyPools.get_proxy(:youtube)
    IO.puts("Got proxy from :youtube pool: #{proxy.url}")

    # Simulate success
    ProxyPools.report_success(:youtube, proxy.url)
    IO.puts("Reported success for YouTube download")

    # Get proxy from metadata pool
    {:ok, proxy} = ProxyPools.get_proxy(:metadata)
    IO.puts("Got proxy from :metadata pool: #{proxy.url}")

    # Get premium proxy
    {:ok, proxy} = ProxyPools.get_proxy(:premium)
    IO.puts("Got proxy from :premium pool: #{proxy.url}\n")
  end

  defp demonstrate_isolation do
    IO.puts("Demonstrating pool isolation...\n")

    # Fail a proxy in youtube pool
    {:ok, proxy} = ProxyPools.get_proxy(:youtube)
    ProxyPools.report_failure(:youtube, proxy.url)
    ProxyPools.report_failure(:youtube, proxy.url)
    ProxyPools.report_failure(:youtube, proxy.url)

    IO.puts("Failed proxy 3 times in :youtube pool: #{proxy.url}")

    # Check that other pools are unaffected
    youtube_stats = ProxyPools.get_stats(:youtube)
    metadata_stats = ProxyPools.get_stats(:metadata)

    IO.puts("\n:youtube pool stats:")

    Enum.each(youtube_stats, fn p ->
      IO.puts("  #{p.url}: #{p.failure_count} failures, enabled: #{p.enabled}")
    end)

    IO.puts("\n:metadata pool stats (unaffected):")

    Enum.each(metadata_stats, fn p ->
      IO.puts("  #{p.url}: #{p.failure_count} failures, enabled: #{p.enabled}")
    end)

    IO.puts("")
  end

  defp demonstrate_dynamic_pools do
    IO.puts("Demonstrating dynamic pool management...\n")

    # Create a temporary pool for a specific user
    user_id = "user_123"
    pool_name = String.to_atom("user_#{user_id}")

    {:ok, _} =
      ProxyPoolSupervisor.start_pool(pool_name,
        proxies: ["http://user-proxy.example.com:8080"],
        strategy: :round_robin
      )

    IO.puts("✓ Created temporary pool for user: #{user_id}")

    # Use the user-specific pool
    {:ok, proxy} = ProxyPools.get_proxy(pool_name)
    IO.puts("Got proxy from user pool: #{proxy.url}")

    # Add a proxy at runtime
    ProxyPools.add_proxy(pool_name, "http://additional-proxy.example.com:8080")
    IO.puts("✓ Added proxy to user pool at runtime")

    # Stop the pool when done
    ProxyPoolSupervisor.stop_pool(pool_name)
    IO.puts("✓ Stopped user pool\n")
  end

  def integration_example do
    IO.puts("""

    =====================================
    Integration with YtDlp
    =====================================

    # In your application.ex
    def start(_type, _args) do
      children = [
        # Registry for proxy pools
        {Registry, keys: :unique, name: ProxyPoolRegistry},

        # Dynamic supervisor
        ProxyRegistryExample.ProxyPoolSupervisor,

        # Start default pools
        # ... other children
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
    end

    # In a separate module, start your pools
    defmodule MyApp.ProxySetup do
      def setup_pools do
        # YouTube-specific proxies
        ProxyPoolSupervisor.start_pool(:youtube, [
          proxies: Application.get_env(:my_app, :youtube_proxies),
          strategy: :round_robin
        ])

        # Vimeo-specific proxies
        ProxyPoolSupervisor.start_pool(:vimeo, [
          proxies: Application.get_env(:my_app, :vimeo_proxies),
          strategy: :healthiest
        ])
      end
    end

    # Usage in your download logic
    defmodule MyApp.Downloader do
      def download(url) do
        pool = determine_pool(url)

        {:ok, proxy} = ProxyPools.get_proxy(pool)

        result = YtDlp.download(url,
          proxy: proxy.url,
          timeout: proxy.timeout
        )

        case result do
          {:ok, _} -> ProxyPools.report_success(pool, proxy.url)
          {:error, _} -> ProxyPools.report_failure(pool, proxy.url)
        end

        result
      end

      defp determine_pool(url) do
        cond do
          String.contains?(url, "youtube.com") -> :youtube
          String.contains?(url, "vimeo.com") -> :vimeo
          true -> :default
        end
      end
    end

    # Per-tenant isolation
    defmodule MyApp.TenantDownloader do
      def download(tenant_id, url) do
        pool_name = :"tenant_\#{tenant_id}"

        # Ensure tenant has a pool
        ensure_pool_exists(tenant_id, pool_name)

        {:ok, proxy} = ProxyPools.get_proxy(pool_name)

        YtDlp.download(url, proxy: proxy.url)
      end

      defp ensure_pool_exists(tenant_id, pool_name) do
        case ProxyPoolSupervisor.get_pool(pool_name) do
          {:ok, _} -> :ok
          {:error, :not_found} ->
            proxies = load_tenant_proxies(tenant_id)
            ProxyPoolSupervisor.start_pool(pool_name, proxies: proxies)
        end
      end
    end
    """)
  end

  def performance_notes do
    IO.puts("""

    =====================================
    Performance Characteristics
    =====================================

    Registry-based pools are extremely fast:
    - Lookup: ~1-2 microseconds
    - GenServer call: ~2-3 microseconds
    - Total latency: ~5 microseconds

    Benefits:
    ✓ No database overhead
    ✓ Perfect for single-node apps
    ✓ Isolated failure domains
    ✓ Dynamic pool creation/destruction
    ✓ Zero configuration

    Tradeoffs:
    ✗ State lost on restart (can be mitigated with persistence)
    ✗ Not shared across nodes (can use :pg for coordination)
    ✗ Memory usage scales with pools * proxies

    Best for:
    • Microservices with service-specific proxies
    • Multi-tenant applications
    • High-performance requirements
    • Single-node deployments
    """)
  end
end

# Run the demo
ProxyRegistryExample.run_demo()
ProxyRegistryExample.integration_example()
ProxyRegistryExample.performance_notes()
