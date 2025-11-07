defmodule YtDlp.Port do
  @moduledoc """
  Manages Port communication with yt-dlp for streaming progress updates.

  This module handles real-time communication with the yt-dlp process using
  Elixir Ports, enabling progress tracking, cancellation, and streaming output.
  """

  use GenServer
  require Logger

  @type progress :: %{
          percent: float() | nil,
          downloaded: String.t() | nil,
          total_size: String.t() | nil,
          speed: String.t() | nil,
          eta: String.t() | nil
        }

  @type port_result :: {:ok, String.t()} | {:error, String.t()}

  defmodule State do
    @moduledoc false
    defstruct [
      :port,
      :caller,
      :binary,
      :args,
      :progress_callback,
      buffer: "",
      stdout_lines: [],
      stderr_lines: [],
      exit_code: nil,
      last_progress: nil
    ]
  end

  # Client API

  @doc """
  Executes a yt-dlp command with streaming progress support.

  ## Options

    * `:progress_callback` - Function called with progress updates: `(progress :: map()) -> any()`
    * `:timeout` - Command timeout in milliseconds (default: 300_000)

  ## Returns

    * `{:ok, output}` - Command succeeded
    * `{:error, reason}` - Command failed
  """
  @spec run(String.t(), [String.t()], keyword()) :: port_result()
  def run(binary, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    progress_callback = Keyword.get(opts, :progress_callback)

    {:ok, pid} = GenServer.start_link(__MODULE__, {binary, args, progress_callback})

    try do
      GenServer.call(pid, :wait_for_completion, timeout)
    catch
      :exit, {:timeout, _} ->
        GenServer.stop(pid, :kill)
        {:error, "Command timed out after #{timeout}ms"}

      :exit, reason ->
        {:error, "Process exited: #{inspect(reason)}"}
    end
  end

  @doc """
  Cancels a running port process.

  This will send a kill signal to the yt-dlp process and clean up the port.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) do
    GenServer.stop(pid, :normal)
  end

  # Server Callbacks

  @impl true
  def init({binary, args, progress_callback}) do
    # Use Port.open with :binary and :exit_status for proper streaming
    port =
      Port.open({:spawn_executable, System.find_executable(binary)}, [
        {:args, args},
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:line, 10000}
      ])

    state = %State{
      port: port,
      binary: binary,
      args: args,
      progress_callback: progress_callback
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:wait_for_completion, from, state) do
    # Store the caller so we can reply later when the port exits
    {:noreply, %{state | caller: from}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %State{port: port} = state) do
    line_str = IO.chardata_to_string(line)

    # Parse progress if this is a progress line
    new_state =
      if String.contains?(line_str, "[download]") do
        case parse_progress(line_str) do
          {:ok, progress} ->
            # Call progress callback if provided
            if state.progress_callback do
              try do
                state.progress_callback.(progress)
              rescue
                error ->
                  Logger.error("Progress callback error: #{inspect(error)}")
              end
            end

            %{state | last_progress: progress, stderr_lines: [line_str | state.stderr_lines]}

          :error ->
            %{state | stderr_lines: [line_str | state.stderr_lines]}
        end
      else
        # Regular output line
        %{state | stdout_lines: [line_str | state.stdout_lines]}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %State{port: port} = state) when is_binary(data) do
    # Handle binary data (shouldn't happen with :line mode, but just in case)
    {:noreply, %{state | buffer: state.buffer <> data}}
  end

  @impl true
  def handle_info({port, {:exit_status, exit_code}}, %State{port: port} = state) do
    Logger.debug("Port exited with code #{exit_code}")

    # Combine output
    stdout = state.stdout_lines |> Enum.reverse() |> Enum.join("\n")
    stderr = state.stderr_lines |> Enum.reverse() |> Enum.join("\n")
    output = if stdout != "", do: stdout, else: stderr

    # Reply to waiting caller
    if state.caller do
      reply =
        if exit_code == 0 do
          {:ok, output}
        else
          {:error, "Command failed with exit code #{exit_code}: #{String.trim(output)}"}
        end

      GenServer.reply(state.caller, reply)
    end

    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %State{port: port} = state) do
    Logger.warning("Port process exited: #{inspect(reason)}")

    if state.caller do
      GenServer.reply(state.caller, {:error, "Port process died: #{inspect(reason)}"})
    end

    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Close the port if it's still open
    if state.port && Port.info(state.port) do
      Port.close(state.port)
    end

    :ok
  end

  # Private Functions

  @doc false
  @spec parse_progress(String.t()) :: {:ok, progress()} | :error
  def parse_progress(line) do
    # Example line: "[download]  45.2% of 10.5MiB at  1.2MiB/s ETA 00:05"
    # Also: "[download] 100% of 10.5MiB in 00:08"
    # Also: "[download] Destination: /path/to/file.mp4"

    cond do
      # Progress line with percentage
      String.match?(line, ~r/\[download\]\s+[\d.]+%/) ->
        parse_progress_line(line)

      # Destination line (useful for tracking output file)
      String.contains?(line, "Destination:") ->
        :error

      # Other download messages
      true ->
        :error
    end
  end

  defp parse_progress_line(line) do
    # Parse: "[download]  45.2% of 10.5MiB at  1.2MiB/s ETA 00:05"
    regex =
      ~r/\[download\]\s+([\d.]+)%(?:\s+of\s+([\d.]+\w+))?(?:\s+at\s+([\d.]+\w+\/s))?(?:\s+ETA\s+([\d:]+))?/

    case Regex.run(regex, line) do
      [_full, percent | rest] ->
        [total_size, speed, eta] =
          case rest do
            [ts, sp, et] -> [ts, sp, et]
            [ts, sp] -> [ts, sp, nil]
            [ts] -> [ts, nil, nil]
            [] -> [nil, nil, nil]
          end

        progress = %{
          percent: parse_float(percent),
          total_size: total_size,
          downloaded: calculate_downloaded(percent, total_size),
          speed: speed,
          eta: eta
        }

        {:ok, progress}

      nil ->
        :error
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {float, _} -> float
      :error -> nil
    end
  end

  defp calculate_downloaded(percent_str, total_size) when is_binary(total_size) do
    with {percent, _} <- Float.parse(percent_str),
         {size, unit} <- parse_size(total_size),
         downloaded <- size * (percent / 100) do
      format_size(downloaded, unit)
    else
      _ -> nil
    end
  end

  defp calculate_downloaded(_, _), do: nil

  defp parse_size(size_str) do
    # Parse "10.5MiB" -> {10.5, "MiB"}
    case Regex.run(~r/([\d.]+)(\w+)/, size_str) do
      [_, num, unit] ->
        case Float.parse(num) do
          {float, _} -> {float, unit}
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp format_size(size, unit) do
    "#{Float.round(size, 2)}#{unit}"
  end
end
