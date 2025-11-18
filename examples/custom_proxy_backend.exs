#!/usr/bin/env elixir

# Custom Proxy Backend Examples
#
# This file shows example implementations of custom proxy backends
# that users can adapt for their own needs.

defmodule CustomProxyBackendExamples do
  @moduledoc """
  Example custom proxy backend implementations.
  """

  # Example 1: Database-Backed Proxy Backend
  defmodule DatabaseBackend do
    @moduledoc """
    Database-backed proxy backend using Ecto.

    This example shows how to integrate with a database for persistence.
    Users would adapt this with their own Repo and schema.
    """

    @behaviour YtDlp.ProxyBackend

    # Assuming you have a Proxy schema and Repo in your app
    # alias MyApp.{Repo, Proxy}
    # import Ecto.Query

    @impl true
    def get_proxy(opts) do
      strategy = Keyword.get(opts, :strategy, :round_robin)

      # Example implementation (adapt to your schema):
      # query =
      #   from p in Proxy,
      #     where: p.enabled == true,
      #     order_by: [desc: p.last_used_at],
      #     limit: 1
      #
      # case Repo.one(query) do
      #   nil ->
      #     {:error, :no_proxies}
      #
      #   proxy ->
      #     # Update last_used_at
      #     proxy
      #     |> Ecto.Changeset.change(last_used_at: DateTime.utc_now())
      #     |> Repo.update()
      #
      #     {:ok, %{url: proxy.url, timeout: proxy.timeout}}
      # end

      # Placeholder for example
      {:ok, %{url: "http://proxy.example.com:8080", timeout: 30_000}}
    end

    @impl true
    def report_success(proxy_url, _opts) do
      # Example implementation:
      # from(p in Proxy, where: p.url == ^proxy_url)
      # |> Repo.update_all(inc: [success_count: 1])

      :ok
    end

    @impl true
    def report_failure(proxy_url, opts) do
      # Example implementation:
      # threshold = Keyword.get(opts, :failure_threshold, 3)
      #
      # proxy = Repo.get_by!(Proxy, url: proxy_url)
      # new_failures = proxy.failure_count + 1
      #
      # proxy
      # |> Ecto.Changeset.change(%{
      #   failure_count: new_failures,
      #   enabled: new_failures < threshold
      # })
      # |> Repo.update()

      :ok
    end

    @impl true
    def get_stats(_opts) do
      # Example implementation:
      # proxies = Repo.all(Proxy)
      # {:ok, Enum.map(proxies, &Map.take(&1, [:url, :success_count, :failure_count, :enabled]))}

      {:ok, []}
    end
  end

  # Example 2: Redis-Backed Proxy Backend
  defmodule RedisBackend do
    @moduledoc """
    Redis-backed proxy backend for distributed proxy management.

    This allows multiple nodes to share proxy state via Redis.
    """

    @behaviour YtDlp.ProxyBackend

    # Assuming you have Redix in your app
    # @redis_pool MyApp.RedisPool

    @impl true
    def get_proxy(opts) do
      pool_name = Keyword.get(opts, :pool_name, "default")

      # Example using Redix:
      # case Redix.command(@redis_pool, ["LPOP", "proxies:#{pool_name}:available"]) do
      #   {:ok, nil} ->
      #     {:error, :no_proxies}
      #
      #   {:ok, proxy_json} ->
      #     proxy = Jason.decode!(proxy_json)
      #
      #     # Push back to end of queue (rotation)
      #     Redix.command(@redis_pool, ["RPUSH", "proxies:#{pool_name}:available", proxy_json])
      #
      #     # Track usage
      #     Redix.command(@redis_pool, ["HINCRBY", "proxies:#{pool_name}:usage", proxy["url"], 1])
      #
      #     {:ok, %{url: proxy["url"], timeout: proxy["timeout"]}}
      # end

      {:ok, %{url: "http://redis-proxy.example.com:8080", timeout: 30_000}}
    end

    @impl true
    def report_success(proxy_url, opts) do
      pool_name = Keyword.get(opts, :pool_name, "default")

      # Example:
      # Redix.command(@redis_pool, ["HINCRBY", "proxies:#{pool_name}:success", proxy_url, 1])

      :ok
    end

    @impl true
    def report_failure(proxy_url, opts) do
      pool_name = Keyword.get(opts, :pool_name, "default")
      threshold = Keyword.get(opts, :failure_threshold, 3)

      # Example:
      # {:ok, failures} = Redix.command(@redis_pool, ["HINCRBY", "proxies:#{pool_name}:failures", proxy_url, 1])
      # failures_int = String.to_integer(failures)
      #
      # if failures_int >= threshold do
      #   # Remove from available pool
      #   Redix.command(@redis_pool, ["LREM", "proxies:#{pool_name}:available", 0, proxy_json])
      # end

      :ok
    end
  end

  # Example 3: External API Proxy Backend
  defmodule APIBackend do
    @moduledoc """
    Proxy backend that fetches proxies from an external API.

    Useful when using third-party proxy services.
    """

    @behaviour YtDlp.ProxyBackend

    @impl true
    def get_proxy(opts) do
      api_key = Keyword.fetch!(opts, :api_key)
      api_url = Keyword.get(opts, :api_url, "https://api.proxyservice.example.com/v1/proxy")

      # Example using Req or HTTPoison:
      # case Req.get(api_url, headers: [{"authorization", "Bearer #{api_key}"}]) do
      #   {:ok, %{status: 200, body: %{"proxy" => proxy}}} ->
      #     {:ok, %{
      #       url: "http://#{proxy["host"]}:#{proxy["port"]}",
      #       timeout: proxy["timeout"] || 30_000
      #     }}
      #
      #   {:ok, %{status: 429}} ->
      #     {:error, :rate_limited}
      #
      #   {:error, reason} ->
      #     {:error, reason}
      # end

      {:ok, %{url: "http://api-proxy.example.com:8080", timeout: 30_000}}
    end

    @impl true
    def report_success(proxy_url, opts) do
      api_key = Keyword.fetch!(opts, :api_key)

      # Report back to API
      # Req.post("https://api.proxyservice.example.com/v1/report",
      #   headers: [{"authorization", "Bearer #{api_key}"}],
      #   json: %{proxy_url: proxy_url, status: "success"}
      # )

      :ok
    end

    @impl true
    def report_failure(proxy_url, opts) do
      api_key = Keyword.fetch!(opts, :api_key)

      # Report failure to API
      # Req.post("https://api.proxyservice.example.com/v1/report",
      #   headers: [{"authorization", "Bearer #{api_key}"}],
      #   json: %{proxy_url: proxy_url, status: "failure"}
      # )

      :ok
    end
  end

  # Example 4: ETS-Cached Database Backend
  defmodule CachedDatabaseBackend do
    @moduledoc """
    Hybrid backend that caches proxies from database in ETS for performance.

    Best of both worlds: database persistence with ETS performance.
    """

    @behaviour YtDlp.ProxyBackend

    use GenServer

    @cache_table :proxy_cache
    @sync_interval :timer.minutes(5)

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(_opts) do
      :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
      load_from_db()
      schedule_sync()
      {:ok, %{}}
    end

    @impl true
    def get_proxy(_opts) do
      case :ets.tab2list(@cache_table) do
        [] ->
          {:error, :no_proxies}

        proxies ->
          [{_url, proxy} | _] = proxies
          {:ok, proxy}
      end
    end

    @impl true
    def report_success(proxy_url, _opts) do
      # Update ETS cache
      case :ets.lookup(@cache_table, proxy_url) do
        [{^proxy_url, proxy}] ->
          updated = Map.update(proxy, :success_count, 1, &(&1 + 1))
          :ets.insert(@cache_table, {proxy_url, updated})
      end

      # Async DB update
      Task.start(fn ->
        nil
        # from(p in Proxy, where: p.url == ^proxy_url)
        # |> Repo.update_all(inc: [success_count: 1])
      end)

      :ok
    end

    @impl true
    def report_failure(proxy_url, _opts) do
      # Similar to report_success
      :ok
    end

    @impl GenServer
    def handle_info(:sync, state) do
      load_from_db()
      schedule_sync()
      {:noreply, state}
    end

    defp load_from_db do
      # proxies = Repo.all(from p in Proxy, where: p.enabled == true)
      # :ets.delete_all_objects(@cache_table)
      # Enum.each(proxies, fn proxy ->
      #   :ets.insert(@cache_table, {proxy.url, %{url: proxy.url, timeout: proxy.timeout}})
      # end)
    end

    defp schedule_sync do
      Process.send_after(self(), :sync, @sync_interval)
    end
  end

  # Example 5: Multi-Region Proxy Backend
  defmodule MultiRegionBackend do
    @moduledoc """
    Proxy backend that selects proxies based on geographic region.

    Useful for region-specific content or compliance requirements.
    """

    @behaviour YtDlp.ProxyBackend

    @impl true
    def get_proxy(opts) do
      region = Keyword.get(opts, :region, "us-east")

      # Get proxies for specific region from your data source
      # proxies = from(p in Proxy,
      #   where: p.region == ^region and p.enabled == true,
      #   order_by: [desc: p.success_count],
      #   limit: 1
      # )
      # |> Repo.one()
      #
      # case proxies do
      #   nil -> {:error, :no_proxies}
      #   proxy -> {:ok, %{url: proxy.url, timeout: proxy.timeout}}
      # end

      {:ok, %{url: "http://#{region}-proxy.example.com:8080", timeout: 30_000}}
    end

    @impl true
    def report_success(proxy_url, _opts), do: :ok

    @impl true
    def report_failure(proxy_url, _opts), do: :ok
  end

  def print_usage_examples do
    IO.puts("""
    =====================================
    Custom Proxy Backend Usage
    =====================================

    ## 1. Database-Backed Backend

    config :yt_dlp,
      proxy_backend: CustomProxyBackendExamples.DatabaseBackend,
      proxy_backend_opts: [
        strategy: :round_robin,
        failure_threshold: 3
      ]

    ## 2. Redis-Backed Backend

    config :yt_dlp,
      proxy_backend: CustomProxyBackendExamples.RedisBackend,
      proxy_backend_opts: [
        pool_name: "downloads",
        failure_threshold: 5
      ]

    ## 3. External API Backend

    config :yt_dlp,
      proxy_backend: CustomProxyBackendExamples.APIBackend,
      proxy_backend_opts: [
        api_key: System.get_env("PROXY_API_KEY"),
        api_url: "https://api.proxyservice.example.com/v1/proxy"
      ]

    ## 4. ETS-Cached Database Backend

    # Add to your application supervisor
    children = [
      MyApp.Repo,
      CustomProxyBackendExamples.CachedDatabaseBackend,
      # ...
    ]

    config :yt_dlp,
      proxy_backend: CustomProxyBackendExamples.CachedDatabaseBackend

    ## 5. Multi-Region Backend

    # Pass region at download time
    YtDlp.download(url,
      use_proxy_manager: true,
      proxy_backend_opts: [region: "eu-west"]
    )

    =====================================
    Minimal Implementation Example
    =====================================

    defmodule MyApp.SimpleProxyBackend do
      @behaviour YtDlp.ProxyBackend

      # Read from environment variable
      @proxies String.split(System.get_env("PROXY_LIST", ""), ",")

      @impl true
      def get_proxy(_opts) do
        case Enum.random(@proxies) do
          "" -> {:error, :no_proxies}
          url -> {:ok, %{url: url, timeout: 30_000}}
        end
      end

      @impl true
      def report_success(_proxy_url, _opts), do: :ok

      @impl true
      def report_failure(_proxy_url, _opts), do: :ok
    end

    # Usage:
    # export PROXY_LIST="http://proxy1.com:8080,http://proxy2.com:8080"

    config :yt_dlp,
      proxy_backend: MyApp.SimpleProxyBackend

    =====================================
    Testing Your Backend
    =====================================

    # Test your backend directly
    {:ok, proxy} = MyApp.CustomBackend.get_proxy([])
    IO.inspect(proxy)  # Should return %{url: ..., timeout: ...}

    MyApp.CustomBackend.report_success(proxy.url, [])
    MyApp.CustomBackend.report_failure(proxy.url, [])

    # Test with YtDlp
    {:ok, download_id} = YtDlp.download(
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      use_proxy_manager: true
    )

    # Your backend methods will be called automatically!
    """)
  end
end

CustomProxyBackendExamples.print_usage_examples()
