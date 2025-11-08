defmodule YtDlp.Error do
  @moduledoc """
  Error types for YtDlp operations.

  This module provides structured error types that can be pattern matched
  for better error handling in your application.

  ## Error Types

  - `CommandError` - yt-dlp command execution failed
  - `TimeoutError` - Operation timed out
  - `NotFoundError` - Resource not found (download ID, file, etc.)
  - `NetworkError` - Network/connectivity issues
  - `ParseError` - Failed to parse yt-dlp output
  - `ValidationError` - Invalid input/options
  - `DependencyError` - Missing required dependency (yt-dlp, ffmpeg, etc.)

  ## Examples

      # Pattern match on error type
      case YtDlp.download(url) do
        {:ok, download_id} -> {:ok, download_id}
        {:error, %YtDlp.Error.NetworkError{} = error} ->
          Logger.warning("Network issue: \#{error.message}")
          retry_later()
        {:error, %YtDlp.Error.ValidationError{} = error} ->
          {:error, "Invalid input: \#{error.message}"}
        {:error, error} ->
          {:error, "Unexpected error: \#{inspect(error)}"}
      end

      # Check error type
      {:error, error} = YtDlp.get_status("invalid-id")
      YtDlp.Error.not_found?(error)  # => true
  """

  @type error ::
          __MODULE__.CommandError.t()
          | __MODULE__.TimeoutError.t()
          | __MODULE__.NotFoundError.t()
          | __MODULE__.NetworkError.t()
          | __MODULE__.ParseError.t()
          | __MODULE__.ValidationError.t()
          | __MODULE__.DependencyError.t()

  defmodule CommandError do
    @moduledoc """
    Error returned when yt-dlp command execution fails.

    ## Fields

    - `message` - Human-readable error message
    - `exit_code` - yt-dlp exit code
    - `output` - Command output (stderr/stdout)
    - `command` - The command that was executed
    """
    defexception [:message, :exit_code, :output, :command]

    @type t :: %__MODULE__{
            message: String.t(),
            exit_code: integer() | nil,
            output: String.t() | nil,
            command: String.t() | nil
          }

    @impl true
    def message(%__MODULE__{message: msg, exit_code: code}) when is_integer(code) do
      "yt-dlp command failed (exit #{code}): #{msg}"
    end

    def message(%__MODULE__{message: msg}) do
      "yt-dlp command failed: #{msg}"
    end
  end

  defmodule TimeoutError do
    @moduledoc """
    Error returned when an operation times out.

    ## Fields

    - `message` - Human-readable error message
    - `timeout` - The timeout value in milliseconds
    - `operation` - The operation that timed out
    """
    defexception [:message, :timeout, :operation]

    @type t :: %__MODULE__{
            message: String.t(),
            timeout: integer() | nil,
            operation: atom() | String.t() | nil
          }

    @impl true
    def message(%__MODULE__{message: msg, timeout: timeout}) when is_integer(timeout) do
      "Operation timed out after #{timeout}ms: #{msg}"
    end

    def message(%__MODULE__{message: msg}) do
      "Operation timed out: #{msg}"
    end
  end

  defmodule NotFoundError do
    @moduledoc """
    Error returned when a resource is not found.

    ## Fields

    - `message` - Human-readable error message
    - `resource` - The resource that was not found
    - `identifier` - The ID/path that was searched for
    """
    defexception [:message, :resource, :identifier]

    @type t :: %__MODULE__{
            message: String.t(),
            resource: atom() | String.t() | nil,
            identifier: String.t() | nil
          }

    @impl true
    def message(%__MODULE__{resource: resource, identifier: id}) when not is_nil(resource) do
      "#{resource} not found: #{id}"
    end

    def message(%__MODULE__{message: msg}) do
      msg
    end
  end

  defmodule NetworkError do
    @moduledoc """
    Error returned when network/connectivity issues occur.

    ## Fields

    - `message` - Human-readable error message
    - `url` - The URL that failed
    - `reason` - Underlying network error reason
    """
    defexception [:message, :url, :reason]

    @type t :: %__MODULE__{
            message: String.t(),
            url: String.t() | nil,
            reason: String.t() | nil
          }

    @impl true
    def message(%__MODULE__{message: msg, url: url}) when not is_nil(url) do
      "Network error for #{url}: #{msg}"
    end

    def message(%__MODULE__{message: msg}) do
      "Network error: #{msg}"
    end
  end

  defmodule ParseError do
    @moduledoc """
    Error returned when parsing yt-dlp output fails.

    ## Fields

    - `message` - Human-readable error message
    - `input` - The input that failed to parse
    - `expected` - What format was expected
    """
    defexception [:message, :input, :expected]

    @type t :: %__MODULE__{
            message: String.t(),
            input: String.t() | nil,
            expected: String.t() | nil
          }

    @impl true
    def message(%__MODULE__{message: msg}) do
      "Parse error: #{msg}"
    end
  end

  defmodule ValidationError do
    @moduledoc """
    Error returned when input validation fails.

    ## Fields

    - `message` - Human-readable error message
    - `field` - The field that failed validation
    - `value` - The invalid value
    """
    defexception [:message, :field, :value]

    @type t :: %__MODULE__{
            message: String.t(),
            field: atom() | String.t() | nil,
            value: term() | nil
          }

    @impl true
    def message(%__MODULE__{message: msg, field: field}) when not is_nil(field) do
      "Validation error for #{field}: #{msg}"
    end

    def message(%__MODULE__{message: msg}) do
      "Validation error: #{msg}"
    end
  end

  defmodule DependencyError do
    @moduledoc """
    Error returned when a required dependency is missing.

    ## Fields

    - `message` - Human-readable error message
    - `dependency` - The missing dependency name
    - `required_for` - What operation requires this dependency
    """
    defexception [:message, :dependency, :required_for]

    @type t :: %__MODULE__{
            message: String.t(),
            dependency: String.t() | nil,
            required_for: String.t() | nil
          }

    @impl true
    def message(%__MODULE__{dependency: dep}) when not is_nil(dep) do
      "Missing dependency: #{dep}"
    end

    def message(%__MODULE__{message: msg}) do
      msg
    end
  end

  # Helper functions for creating errors

  @doc """
  Creates a CommandError from yt-dlp output.
  """
  @spec command_error(String.t(), keyword()) :: CommandError.t()
  def command_error(message, opts \\ []) do
    %CommandError{
      message: message,
      exit_code: Keyword.get(opts, :exit_code),
      output: Keyword.get(opts, :output),
      command: Keyword.get(opts, :command)
    }
  end

  @doc """
  Creates a TimeoutError.
  """
  @spec timeout_error(String.t(), keyword()) :: TimeoutError.t()
  def timeout_error(message, opts \\ []) do
    %TimeoutError{
      message: message,
      timeout: Keyword.get(opts, :timeout),
      operation: Keyword.get(opts, :operation)
    }
  end

  @doc """
  Creates a NotFoundError.
  """
  @spec not_found_error(String.t(), keyword()) :: NotFoundError.t()
  def not_found_error(message, opts \\ []) do
    %NotFoundError{
      message: message,
      resource: Keyword.get(opts, :resource),
      identifier: Keyword.get(opts, :identifier)
    }
  end

  @doc """
  Creates a NetworkError.
  """
  @spec network_error(String.t(), keyword()) :: NetworkError.t()
  def network_error(message, opts \\ []) do
    %NetworkError{
      message: message,
      url: Keyword.get(opts, :url),
      reason: Keyword.get(opts, :reason)
    }
  end

  @doc """
  Creates a ParseError.
  """
  @spec parse_error(String.t(), keyword()) :: ParseError.t()
  def parse_error(message, opts \\ []) do
    %ParseError{
      message: message,
      input: Keyword.get(opts, :input),
      expected: Keyword.get(opts, :expected)
    }
  end

  @doc """
  Creates a ValidationError.
  """
  @spec validation_error(String.t(), keyword()) :: ValidationError.t()
  def validation_error(message, opts \\ []) do
    %ValidationError{
      message: message,
      field: Keyword.get(opts, :field),
      value: Keyword.get(opts, :value)
    }
  end

  @doc """
  Creates a DependencyError.
  """
  @spec dependency_error(String.t(), keyword()) :: DependencyError.t()
  def dependency_error(message, opts \\ []) do
    %DependencyError{
      message: message,
      dependency: Keyword.get(opts, :dependency),
      required_for: Keyword.get(opts, :required_for)
    }
  end

  # Type checking helpers

  @doc """
  Checks if an error is a CommandError.
  """
  @spec command_error?(term()) :: boolean()
  def command_error?(%CommandError{}), do: true
  def command_error?(_), do: false

  @doc """
  Checks if an error is a TimeoutError.
  """
  @spec timeout_error?(term()) :: boolean()
  def timeout_error?(%TimeoutError{}), do: true
  def timeout_error?(_), do: false

  @doc """
  Checks if an error is a NotFoundError.
  """
  @spec not_found_error?(term()) :: boolean()
  def not_found_error?(%NotFoundError{}), do: true
  def not_found_error?(_), do: false

  @doc """
  Checks if an error is a NetworkError.
  """
  @spec network_error?(term()) :: boolean()
  def network_error?(%NetworkError{}), do: true
  def network_error?(_), do: false

  @doc """
  Checks if an error is a ParseError.
  """
  @spec parse_error?(term()) :: boolean()
  def parse_error?(%ParseError{}), do: true
  def parse_error?(_), do: false

  @doc """
  Checks if an error is a ValidationError.
  """
  @spec validation_error?(term()) :: boolean()
  def validation_error?(%ValidationError{}), do: true
  def validation_error?(_), do: false

  @doc """
  Checks if an error is a DependencyError.
  """
  @spec dependency_error?(term()) :: boolean()
  def dependency_error?(%DependencyError{}), do: true
  def dependency_error?(_), do: false

  @doc """
  Checks if an error is retryable (network or timeout errors).
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(%NetworkError{}), do: true
  def retryable?(%TimeoutError{}), do: true
  def retryable?(_), do: false

  @doc """
  Converts a generic error string/tuple to a structured error.

  This is useful for backwards compatibility or when integrating
  with code that returns string errors.
  """
  @spec from_string(String.t() | atom()) :: error()
  def from_string(:not_found) do
    not_found_error("Resource not found", resource: :download)
  end

  def from_string(error_string) when is_binary(error_string) do
    cond do
      timeout_string?(error_string) ->
        timeout_error(error_string)

      not_found_string?(error_string) ->
        not_found_error(error_string)

      network_string?(error_string) ->
        network_error(error_string)

      parse_string?(error_string) ->
        parse_error(error_string)

      dependency_string?(error_string) ->
        dependency_error(error_string)

      exit_code_string?(error_string) ->
        extract_and_build_command_error(error_string)

      true ->
        command_error(error_string)
    end
  end

  def from_string(other), do: command_error(inspect(other))

  defp timeout_string?(error_string) do
    String.contains?(error_string, "timed out")
  end

  defp not_found_string?(error_string) do
    String.contains?(error_string, "not found") or
      String.contains?(error_string, "Not Found")
  end

  defp network_string?(error_string) do
    String.contains?(error_string, "Network") or
      String.contains?(error_string, "HTTP Error")
  end

  defp parse_string?(error_string) do
    String.contains?(error_string, "Failed to parse")
  end

  defp dependency_string?(error_string) do
    String.contains?(error_string, "Binary not found") or
      String.contains?(error_string, "not installed")
  end

  defp exit_code_string?(error_string) do
    String.contains?(error_string, "exit code")
  end

  defp extract_and_build_command_error(error_string) do
    case Regex.run(~r/exit code (\d+)/, error_string) do
      [_, code_str] ->
        {code, _} = Integer.parse(code_str)
        command_error(error_string, exit_code: code)

      _ ->
        command_error(error_string)
    end
  end
end
