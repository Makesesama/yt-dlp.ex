defmodule YtDlp.ProxyManager do
  @moduledoc """
  Default in-memory proxy manager implementation.

  This module provides intelligent proxy management with features like:
  - Multiple proxy support with rotation strategies
  - Health tracking per proxy (success/failure rates)
  - Automatic failover on proxy failures
  - Per-proxy timeout configuration
  - Support for HTTP/HTTPS/SOCKS proxies

  ## Configuration

  Proxies can be configured globally or per-download:

      config :yt_dlp,
        proxies: [
          %{url: "http://proxy1.example.com:8080", timeout: 30_000},
          %{url: "socks5://proxy2.example.com:1080", timeout: 45_000},
          "http://proxy3.example.com:3128"  # Uses default timeout
        ],
        proxy_rotation_strategy: :round_robin,  # or :random, :least_used, :healthiest
        proxy_failure_threshold: 3

  ## Custom Backends

  You can replace this default implementation with your own by implementing
  the `YtDlp.ProxyBackend` behaviour:

      config :yt_dlp,
        proxy_backend: MyApp.CustomProxyBackend,
        proxy_backend_opts: [...]

  See `YtDlp.ProxyBackend` for details.

  ## Usage

      # Start the proxy manager
      {:ok, pid} = YtDlp.ProxyManager.start_link()

      # Get next proxy
      {:ok, proxy} = YtDlp.ProxyManager.get_proxy()

      # Report proxy success/failure
      YtDlp.ProxyManager.report_success(proxy.url)
      YtDlp.ProxyManager.report_failure(proxy.url)

      # Get proxy statistics
      stats = YtDlp.ProxyManager.get_stats()
  """

  @behaviour YtDlp.ProxyBackend

  use GenServer
  require Logger

  @type proxy :: %{
          url: String.t(),
          timeout: pos_integer(),
          success_count: non_neg_integer(),
          failure_count: non_neg_integer(),
          last_used: DateTime.t() | nil,
          enabled: boolean()
        }

  @type rotation_strategy :: :round_robin | :random | :least_used | :healthiest

  @type config :: %{
          proxies: [proxy()],
          strategy: rotation_strategy(),
          failure_threshold: pos_integer(),
          default_timeout: pos_integer(),
          current_index: non_neg_integer()
        }

  # Client API

  @doc """
  Starts the ProxyManager GenServer.

  ## Options

    * `:proxies` - List of proxy configurations (URLs or maps)
    * `:strategy` - Rotation strategy (default: `:round_robin`)
    * `:failure_threshold` - Number of failures before disabling proxy (default: 3)
    * `:default_timeout` - Default timeout for proxies in ms (default: 30_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the next proxy based on the rotation strategy.

  Returns `{:ok, proxy}` if a healthy proxy is available, or `{:error, :no_proxies}`
  if no proxies are configured or all are disabled.
  """
  @spec get_proxy() :: {:ok, proxy()} | {:error, :no_proxies}
  def get_proxy do
    GenServer.call(__MODULE__, :get_proxy)
  end

  @doc """
  Gets a specific proxy by URL.
  """
  @spec get_proxy_by_url(String.t()) :: {:ok, proxy()} | {:error, :not_found}
  def get_proxy_by_url(url) do
    GenServer.call(__MODULE__, {:get_proxy_by_url, url})
  end

  @doc """
  Reports a successful download using the specified proxy.
  """
  @spec report_success(String.t()) :: :ok
  def report_success(proxy_url) do
    GenServer.cast(__MODULE__, {:report_success, proxy_url})
  end

  @doc """
  Reports a failed download using the specified proxy.

  If the failure count exceeds the threshold, the proxy will be disabled.
  """
  @spec report_failure(String.t()) :: :ok
  def report_failure(proxy_url) do
    GenServer.cast(__MODULE__, {:report_failure, proxy_url})
  end

  @doc """
  Gets statistics for all proxies.
  """
  @spec get_stats() :: [proxy()]
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Manually enables a disabled proxy.
  """
  @spec enable_proxy(String.t()) :: :ok | {:error, :not_found}
  def enable_proxy(proxy_url) do
    GenServer.call(__MODULE__, {:enable_proxy, proxy_url})
  end

  @doc """
  Manually disables a proxy.
  """
  @spec disable_proxy(String.t()) :: :ok | {:error, :not_found}
  def disable_proxy(proxy_url) do
    GenServer.call(__MODULE__, {:disable_proxy, proxy_url})
  end

  @doc """
  Resets statistics for all proxies.
  """
  @spec reset_stats() :: :ok
  def reset_stats do
    GenServer.cast(__MODULE__, :reset_stats)
  end

  @doc """
  Updates the rotation strategy.
  """
  @spec set_strategy(rotation_strategy()) :: :ok
  def set_strategy(strategy) when strategy in [:round_robin, :random, :least_used, :healthiest] do
    GenServer.cast(__MODULE__, {:set_strategy, strategy})
  end

  # Behaviour Implementations (for YtDlp.ProxyBackend compatibility)

  @doc """
  Behaviour callback implementation for getting a proxy.
  This is called when using a custom backend configuration.
  """
  @impl YtDlp.ProxyBackend
  def get_proxy(_opts), do: get_proxy()

  @doc """
  Behaviour callback implementation for reporting success.
  This is called when using a custom backend configuration.
  """
  @impl YtDlp.ProxyBackend
  def report_success(proxy_url, _opts), do: report_success(proxy_url)

  @doc """
  Behaviour callback implementation for reporting failure.
  This is called when using a custom backend configuration.
  """
  @impl YtDlp.ProxyBackend
  def report_failure(proxy_url, _opts), do: report_failure(proxy_url)

  @doc """
  Behaviour callback implementation for getting statistics.
  This is called when using a custom backend configuration.
  """
  @impl YtDlp.ProxyBackend
  def get_stats(_opts), do: {:ok, get_stats()}

  # Server Callbacks

  @impl true
  def init(opts) do
    proxy_configs = Keyword.get(opts, :proxies, Application.get_env(:yt_dlp, :proxies, []))

    strategy =
      Keyword.get(
        opts,
        :strategy,
        Application.get_env(:yt_dlp, :proxy_rotation_strategy, :round_robin)
      )

    failure_threshold =
      Keyword.get(
        opts,
        :failure_threshold,
        Application.get_env(:yt_dlp, :proxy_failure_threshold, 3)
      )

    default_timeout = Keyword.get(opts, :default_timeout, 30_000)

    proxies = Enum.map(proxy_configs, &normalize_proxy(&1, default_timeout))

    state = %{
      proxies: proxies,
      strategy: strategy,
      failure_threshold: failure_threshold,
      default_timeout: default_timeout,
      current_index: 0
    }

    Logger.info("ProxyManager started with #{length(proxies)} proxies using #{strategy} strategy")

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
  def handle_call({:get_proxy_by_url, url}, _from, state) do
    case Enum.find(state.proxies, fn p -> p.url == url end) do
      nil ->
        {:reply, {:error, :not_found}, state}

      proxy ->
        {:reply, {:ok, proxy}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.proxies, state}
  end

  @impl true
  def handle_call({:enable_proxy, proxy_url}, _from, state) do
    case update_proxy(state, proxy_url, fn proxy -> %{proxy | enabled: true} end) do
      {:ok, new_state} ->
        Logger.info("Enabled proxy: #{proxy_url}")
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:disable_proxy, proxy_url}, _from, state) do
    case update_proxy(state, proxy_url, fn proxy -> %{proxy | enabled: false} end) do
      {:ok, new_state} ->
        Logger.warning("Disabled proxy: #{proxy_url}")
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:report_success, proxy_url}, state) do
    case update_proxy(state, proxy_url, fn proxy ->
           %{proxy | success_count: proxy.success_count + 1}
         end) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:report_failure, proxy_url}, state) do
    update_fn = &update_proxy_failure(&1, proxy_url, state.failure_threshold)

    case update_proxy(state, proxy_url, update_fn) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:reset_stats, state) do
    proxies =
      Enum.map(state.proxies, fn proxy ->
        %{proxy | success_count: 0, failure_count: 0, enabled: true}
      end)

    Logger.info("Reset statistics for all proxies")
    {:noreply, %{state | proxies: proxies}}
  end

  @impl true
  def handle_cast({:set_strategy, strategy}, state) do
    Logger.info("Changed rotation strategy to: #{strategy}")
    {:noreply, %{state | strategy: strategy, current_index: 0}}
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
      success_count: Map.get(proxy, :success_count, 0),
      failure_count: Map.get(proxy, :failure_count, 0),
      last_used: Map.get(proxy, :last_used),
      enabled: Map.get(proxy, :enabled, true)
    }
  end

  defp select_proxy(%{proxies: []}) do
    {:error, :no_proxies}
  end

  defp select_proxy(state) do
    enabled_proxies = Enum.filter(state.proxies, & &1.enabled)

    if Enum.empty?(enabled_proxies) do
      {:error, :no_proxies}
    else
      case state.strategy do
        :round_robin ->
          select_round_robin(state, enabled_proxies)

        :random ->
          select_random(state, enabled_proxies)

        :least_used ->
          select_least_used(state, enabled_proxies)

        :healthiest ->
          select_healthiest(state, enabled_proxies)
      end
    end
  end

  defp select_round_robin(state, enabled_proxies) do
    proxy = Enum.at(enabled_proxies, rem(state.current_index, length(enabled_proxies)))
    updated_proxy = %{proxy | last_used: DateTime.utc_now()}

    new_state =
      state
      |> update_proxy_in_list(proxy.url, updated_proxy)
      |> Map.put(:current_index, state.current_index + 1)

    {:ok, updated_proxy, new_state}
  end

  defp select_random(state, enabled_proxies) do
    proxy = Enum.random(enabled_proxies)
    updated_proxy = %{proxy | last_used: DateTime.utc_now()}

    new_state = update_proxy_in_list(state, proxy.url, updated_proxy)

    {:ok, updated_proxy, new_state}
  end

  defp select_least_used(state, enabled_proxies) do
    proxy =
      enabled_proxies
      |> Enum.min_by(fn p ->
        case p.last_used do
          nil -> 0
          dt -> DateTime.to_unix(dt)
        end
      end)

    updated_proxy = %{proxy | last_used: DateTime.utc_now()}
    new_state = update_proxy_in_list(state, proxy.url, updated_proxy)

    {:ok, updated_proxy, new_state}
  end

  defp select_healthiest(state, enabled_proxies) do
    proxy =
      enabled_proxies
      |> Enum.max_by(fn p ->
        total = p.success_count + p.failure_count

        if total == 0 do
          1.0
        else
          p.success_count / total
        end
      end)

    updated_proxy = %{proxy | last_used: DateTime.utc_now()}
    new_state = update_proxy_in_list(state, proxy.url, updated_proxy)

    {:ok, updated_proxy, new_state}
  end

  defp update_proxy(state, proxy_url, update_fn) do
    case Enum.find_index(state.proxies, fn p -> p.url == proxy_url end) do
      nil ->
        {:error, :not_found}

      index ->
        proxy = Enum.at(state.proxies, index)
        updated_proxy = update_fn.(proxy)
        new_proxies = List.replace_at(state.proxies, index, updated_proxy)
        {:ok, %{state | proxies: new_proxies}}
    end
  end

  defp update_proxy_in_list(state, proxy_url, updated_proxy) do
    case Enum.find_index(state.proxies, fn p -> p.url == proxy_url end) do
      nil ->
        state

      index ->
        new_proxies = List.replace_at(state.proxies, index, updated_proxy)
        %{state | proxies: new_proxies}
    end
  end

  defp update_proxy_failure(proxy, proxy_url, failure_threshold) do
    new_failure_count = proxy.failure_count + 1
    enabled = new_failure_count < failure_threshold

    if not enabled and proxy.enabled do
      Logger.warning(
        "Proxy disabled due to failures: #{proxy_url} (#{new_failure_count} failures)"
      )
    end

    %{proxy | failure_count: new_failure_count, enabled: enabled}
  end
end
