defmodule YtDlp.Command do
  @moduledoc """
  Executes yt-dlp commands using Elixir ports.

  This module provides a low-level interface for running yt-dlp commands
  and handling their output. It uses System.cmd/3 for simple command execution.
  """

  require Logger

  @type command_result :: {:ok, map()} | {:error, String.t()}

  @doc """
  Gets the path to the yt-dlp binary.

  Returns the value of YT_DLP_PATH environment variable if set,
  otherwise defaults to "yt-dlp" (assuming it's in PATH via Nix).
  """
  @spec binary_path() :: String.t()
  def binary_path do
    System.get_env("YT_DLP_PATH", "yt-dlp")
  end

  @doc """
  Executes a yt-dlp command with the given arguments.

  ## Parameters

    * `args` - List of command-line arguments to pass to yt-dlp
    * `opts` - Keyword list of options (default: [])
      * `:timeout` - Command timeout in milliseconds (default: 300_000 - 5 minutes)

  ## Returns

    * `{:ok, output}` - Command succeeded with stdout output
    * `{:error, reason}` - Command failed with error message

  ## Examples

      iex> YtDlp.Command.run(["--version"])
      {:ok, "2024.10.07\\n"}

      iex> YtDlp.Command.run(["--help"])
      {:ok, "Usage: yt-dlp [OPTIONS] URL [URL...]\\n..."}
  """
  @spec run([String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    binary = binary_path()

    Logger.debug("Running yt-dlp command: #{binary} #{Enum.join(args, " ")}")

    case System.cmd(binary, args, stderr_to_stdout: true, timeout: timeout) do
      {output, 0} ->
        {:ok, output}

      {output, exit_code} ->
        Logger.error("yt-dlp command failed (exit code #{exit_code}): #{output}")
        {:error, "Command failed with exit code #{exit_code}: #{String.trim(output)}"}
    end
  catch
    :exit, {:timeout, _} ->
      {:error, "Command timed out after #{timeout}ms"}
  end

  @doc """
  Executes a yt-dlp command and returns parsed JSON output.

  This is useful for commands that output JSON (using --dump-json or --print-json flags).

  ## Parameters

    * `args` - List of command-line arguments (should include JSON output flags)
    * `opts` - Keyword list of options (passed to run/2)

  ## Returns

    * `{:ok, decoded_json}` - Successfully parsed JSON output
    * `{:error, reason}` - Command failed or JSON parsing failed

  ## Examples

      iex> YtDlp.Command.run_json(["--dump-json", "--playlist-items", "1", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
      {:ok, %{"id" => "dQw4w9WgXcQ", "title" => "Rick Astley - Never Gonna Give You Up", ...}}
  """
  @spec run_json([String.t()], keyword()) :: {:ok, map() | list()} | {:error, String.t()}
  def run_json(args, opts \\ []) do
    case run(args, opts) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, json} -> {:ok, json}
          {:error, error} -> {:error, "Failed to parse JSON: #{inspect(error)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets video information without downloading.

  ## Parameters

    * `url` - Video URL
    * `opts` - Additional options

  ## Returns

    * `{:ok, video_info}` - Map containing video metadata
    * `{:error, reason}` - Failed to get video info
  """
  @spec get_info(String.t(), keyword()) :: command_result()
  def get_info(url, opts \\ []) do
    args = [
      "--dump-json",
      "--no-playlist",
      "--skip-download",
      url
    ]

    run_json(args, opts)
  end

  @doc """
  Downloads a video to the specified directory.

  ## Parameters

    * `url` - Video URL
    * `output_dir` - Directory to save the video (default: current directory)
    * `opts` - Additional options
      * `:format` - Video format (default: "best")
      * `:filename_template` - Output filename template (default: "%(title)s.%(ext)s")
      * `:progress_callback` - Function to call with progress updates (not yet implemented)

  ## Returns

    * `{:ok, %{path: video_path, info: video_info}}` - Download succeeded
    * `{:error, reason}` - Download failed
  """
  @spec download(String.t(), String.t(), keyword()) :: command_result()
  def download(url, output_dir \\ ".", opts \\ []) do
    format = Keyword.get(opts, :format, "best")
    filename_template = Keyword.get(opts, :filename_template, "%(title)s.%(ext)s")
    timeout = Keyword.get(opts, :timeout, 1_800_000)

    output_path = Path.join(output_dir, filename_template)

    args = [
      "--format",
      format,
      "--output",
      output_path,
      "--no-playlist",
      "--print",
      "after_move:filepath",
      url
    ]

    case run(args, timeout: timeout) do
      {:ok, output} ->
        # The last line should contain the actual file path
        filepath =
          output
          |> String.trim()
          |> String.split("\n")
          |> List.last()

        {:ok, %{path: filepath, url: url}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
