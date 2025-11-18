#!/usr/bin/env elixir

# Database-Backed Proxy Integration Example
#
# This example shows how to integrate database-backed proxy management
# with the yt-dlp.ex library.

Mix.install([
  {:yt_dlp, path: "."},
  {:ecto_sql, "~> 3.10"},
  {:postgrex, "~> 0.17"}
])

defmodule ProxyDBExample do
  @moduledoc """
  Example of database-backed proxy management for yt-dlp.ex
  """

  # Minimal Ecto setup for the example
  defmodule Repo do
    use Ecto.Repo,
      otp_app: :yt_dlp,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule Proxy do
    use Ecto.Schema
    import Ecto.Changeset

    schema "proxies" do
      field(:url, :string)
      field(:timeout, :integer, default: 30_000)
      field(:enabled, :boolean, default: true)
      field(:success_count, :integer, default: 0)
      field(:failure_count, :integer, default: 0)
      field(:last_used_at, :utc_datetime)
      field(:region, :string)

      timestamps()
    end

    def changeset(proxy, attrs) do
      proxy
      |> cast(attrs, [
        :url,
        :timeout,
        :enabled,
        :success_count,
        :failure_count,
        :last_used_at,
        :region
      ])
      |> validate_required([:url])
      |> unique_constraint(:url)
    end
  end

  defmodule ProxyManagerDB do
    @moduledoc """
    Database-backed proxy manager with ETS cache.

    This replaces YtDlp.ProxyManager when you need database persistence.
    """

    use GenServer
    require Logger
    import Ecto.Query

    @cache_table :proxy_cache_db
    @sync_interval :timer.minutes(5)

    # Client API

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    def get_proxy do
      GenServer.call(__MODULE__, :get_proxy)
    end

    def report_success(proxy_url) do
      GenServer.cast(__MODULE__, {:report_success, proxy_url})
    end

    def report_failure(proxy_url) do
      GenServer.cast(__MODULE__, {:report_failure, proxy_url})
    end

    def reload_from_db do
      GenServer.cast(__MODULE__, :reload)
    end

    # Server Callbacks

    @impl true
    def init(_opts) do
      :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
      load_proxies()
      schedule_sync()

      {:ok, %{current_index: 0, failure_threshold: 3}}
    end

    @impl true
    def handle_call(:get_proxy, _from, state) do
      enabled_proxies =
        :ets.tab2list(@cache_table)
        |> Enum.map(fn {_url, proxy} -> proxy end)
        |> Enum.filter(& &1.enabled)

      if Enum.empty?(enabled_proxies) do
        {:reply, {:error, :no_proxies}, state}
      else
        proxy = Enum.at(enabled_proxies, rem(state.current_index, length(enabled_proxies)))

        # Update last_used
        :ets.update_element(@cache_table, proxy.url, {5, DateTime.utc_now()})

        # Async DB update
        Task.start(fn -> update_last_used(proxy.url) end)

        {:reply, {:ok, proxy}, %{state | current_index: state.current_index + 1}}
      end
    end

    @impl true
    def handle_cast({:report_success, proxy_url}, state) do
      case :ets.lookup(@cache_table, proxy_url) do
        [{^proxy_url, proxy}] ->
          updated = %{proxy | success_count: proxy.success_count + 1}
          :ets.insert(@cache_table, {proxy_url, updated})

          # Async DB update
          Task.start(fn -> increment_success(proxy_url) end)

        [] ->
          Logger.warning("Proxy not found: #{proxy_url}")
      end

      {:noreply, state}
    end

    @impl true
    def handle_cast({:report_failure, proxy_url}, state) do
      case :ets.lookup(@cache_table, proxy_url) do
        [{^proxy_url, proxy}] ->
          new_failure_count = proxy.failure_count + 1
          enabled = new_failure_count < state.failure_threshold

          updated = %{
            proxy
            | failure_count: new_failure_count,
              enabled: enabled
          }

          :ets.insert(@cache_table, {proxy_url, updated})

          # Async DB update
          Task.start(fn -> increment_failure(proxy_url, enabled) end)

        [] ->
          Logger.warning("Proxy not found: #{proxy_url}")
      end

      {:noreply, state}
    end

    @impl true
    def handle_cast(:reload, state) do
      load_proxies()
      {:noreply, state}
    end

    @impl true
    def handle_info(:sync, state) do
      load_proxies()
      schedule_sync()
      {:noreply, state}
    end

    # Private Functions

    defp load_proxies do
      proxies =
        ProxyDBExample.Proxy
        |> where([p], p.enabled == true)
        |> ProxyDBExample.Repo.all()

      :ets.delete_all_objects(@cache_table)

      Enum.each(proxies, fn proxy ->
        cache_proxy = %{
          url: proxy.url,
          timeout: proxy.timeout,
          enabled: proxy.enabled,
          success_count: proxy.success_count,
          last_used_at: proxy.last_used_at
        }

        :ets.insert(@cache_table, {proxy.url, cache_proxy})
      end)

      Logger.info("Loaded #{length(proxies)} proxies from database")
    end

    defp schedule_sync do
      Process.send_after(self(), :sync, @sync_interval)
    end

    defp update_last_used(proxy_url) do
      ProxyDBExample.Proxy
      |> ProxyDBExample.Repo.get_by(url: proxy_url)
      |> case do
        nil ->
          :ok

        proxy ->
          proxy
          |> ProxyDBExample.Proxy.changeset(%{last_used_at: DateTime.utc_now()})
          |> ProxyDBExample.Repo.update()
      end
    end

    defp increment_success(proxy_url) do
      from(p in ProxyDBExample.Proxy, where: p.url == ^proxy_url)
      |> ProxyDBExample.Repo.update_all(inc: [success_count: 1])
    end

    defp increment_failure(proxy_url, enabled) do
      from(p in ProxyDBExample.Proxy, where: p.url == ^proxy_url)
      |> ProxyDBExample.Repo.update_all(inc: [failure_count: 1], set: [enabled: enabled])
    end
  end

  # Integration with YtDlp

  defmodule ProxyAdapter do
    @moduledoc """
    Adapter that makes DB-backed proxy manager compatible with YtDlp.
    """

    def get_proxy do
      case ProxyManagerDB.get_proxy() do
        {:ok, proxy} -> {:ok, proxy}
        {:error, reason} -> {:error, reason}
      end
    end

    def report_success(proxy_url) do
      ProxyManagerDB.report_success(proxy_url)
    end

    def report_failure(proxy_url) do
      ProxyManagerDB.report_failure(proxy_url)
    end
  end

  def run_example do
    IO.puts("""
    =====================================
    Database-Backed Proxy Example
    =====================================

    This example demonstrates:
    1. Loading proxies from database
    2. Caching in ETS for performance
    3. Async updates to database
    4. Integration with YtDlp

    Setup:
    - Create database: createdb yt_dlp_dev
    - Run migration (see below)
    - Seed proxies
    - Use with YtDlp.download/2
    """)

    print_migration()
    print_seed_data()
    print_usage()
  end

  defp print_migration do
    IO.puts("\n--- Migration ---\n")

    IO.puts("""
    defmodule MyApp.Repo.Migrations.CreateProxies do
      use Ecto.Migration

      def change do
        create table(:proxies) do
          add :url, :string, null: false
          add :timeout, :integer, default: 30_000
          add :enabled, :boolean, default: true
          add :success_count, :integer, default: 0
          add :failure_count, :integer, default: 0
          add :last_used_at, :utc_datetime
          add :region, :string

          timestamps()
        end

        create unique_index(:proxies, [:url])
        create index(:proxies, [:enabled])
      end
    end
    """)
  end

  defp print_seed_data do
    IO.puts("\n--- Seed Data ---\n")

    IO.puts("""
    # priv/repo/seeds.exs
    alias MyApp.{Repo, Proxy}

    proxies = [
      %{url: "http://proxy1.example.com:8080", timeout: 30_000, region: "us-east"},
      %{url: "http://proxy2.example.com:8080", timeout: 45_000, region: "us-west"},
      %{url: "socks5://proxy3.example.com:1080", timeout: 60_000, region: "eu-west"}
    ]

    Enum.each(proxies, fn attrs ->
      %Proxy{}
      |> Proxy.changeset(attrs)
      |> Repo.insert!()
    end)

    IO.puts("Seeded \#{length(proxies)} proxies")
    """)
  end

  defp print_usage do
    IO.puts("\n--- Usage ---\n")

    IO.puts("""
    # In your application supervisor
    def start(_type, _args) do
      children = [
        MyApp.Repo,
        ProxyDBExample.ProxyManagerDB,
        # ... rest of children
      ]

      Supervisor.start_link(children, strategy: :one_for_one)
    end

    # Override YtDlp.ProxyManager with DB version
    # In your YtDlp.Command module, replace:
    # YtDlp.ProxyManager.get_proxy()
    # with:
    # ProxyDBExample.ProxyManagerDB.get_proxy()

    # Or use custom option:
    {:ok, download_id} = YtDlp.download(
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      proxy_manager: ProxyDBExample.ProxyManagerDB
    )

    # Query proxies
    import Ecto.Query
    alias MyApp.{Repo, Proxy}

    # Get top performing proxies
    top_proxies =
      Proxy
      |> where([p], p.enabled == true)
      |> order_by([p], desc: p.success_count)
      |> limit(10)
      |> Repo.all()

    # Get proxies by region
    us_proxies =
      Proxy
      |> where([p], p.region == "us-east" and p.enabled == true)
      |> Repo.all()

    # Analytics
    stats =
      Proxy
      |> select([p], %{
        total: count(p.id),
        enabled: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", p.enabled)),
        total_successes: sum(p.success_count),
        total_failures: sum(p.failure_count)
      })
      |> Repo.one()

    # Add new proxy via admin interface
    %Proxy{}
    |> Proxy.changeset(%{
      url: "http://new-proxy.example.com:8080",
      timeout: 30_000,
      region: "ap-south"
    })
    |> Repo.insert()

    # Reload proxy manager cache after adding
    ProxyDBExample.ProxyManagerDB.reload_from_db()
    """)
  end

  def performance_comparison do
    IO.puts("""

    =====================================
    Performance Comparison
    =====================================

    Static Config (Current):
    - Read latency: ~1μs (in-memory)
    - Write latency: N/A
    - Memory usage: ~1KB per proxy

    Database-Backed (with ETS cache):
    - Read latency: ~5μs (ETS cache)
    - Write latency: ~1ms (async, batched)
    - Memory usage: ~1KB per proxy (ETS) + DB storage

    Registry-Based:
    - Read latency: ~2μs (process call)
    - Write latency: ~1μs (in-memory)
    - Memory usage: ~1KB per proxy per pool

    All approaches are fast enough for typical use cases.
    Choose based on persistence and multi-node requirements.
    """)
  end
end

# Run the example
ProxyDBExample.run_example()
ProxyDBExample.performance_comparison()
