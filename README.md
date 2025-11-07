# YtDlp.ex

An Elixir wrapper for [yt-dlp](https://github.com/yt-dlp/yt-dlp) with GenServer-based download management.

## Features

- 🚀 **Asynchronous Downloads**: Non-blocking video downloads with status tracking
- 🔄 **Concurrent Management**: Control multiple simultaneous downloads
- 📊 **Progress Tracking**: Monitor download status in real-time
- 🎯 **Simple API**: Clean, idiomatic Elixir interface
- 🛡️ **Supervised**: Built with OTP supervision for reliability
- 📦 **NixOS Ready**: Designed to work seamlessly with Nix flakes
- 🔍 **Metadata Extraction**: Get video info without downloading

## Installation

Add `yt_dlp` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:yt_dlp, "~> 0.1.0"}
  ]
end
```

### NixOS Setup

This project includes a Nix flake for development. The `yt-dlp` binary is automatically available in the dev shell:

```bash
# Enter the development environment
nix develop

# Or use direnv (if .envrc is configured)
direnv allow
```

The flake includes:
- Elixir 1.18 with Erlang 27
- yt-dlp binary from nixpkgs
- Development tools (elixir-ls, credo, dialyzer)

## Usage

### Basic Download (Async)

```elixir
# Queue a download
{:ok, download_id} = YtDlp.download("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

# Check status
{:ok, status} = YtDlp.get_status(download_id)
IO.puts("Status: #{status.status}")  # :pending, :downloading, :completed, or :failed

# When completed
if status.status == :completed do
  IO.puts("Downloaded to: #{status.result.path}")
end
```

### Synchronous Download

```elixir
# Download and wait for completion
{:ok, result} = YtDlp.download_sync("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
IO.puts("Downloaded to: #{result.path}")
```

### Custom Download Options

```elixir
{:ok, download_id} = YtDlp.download(
  "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
  format: "bestvideo+bestaudio",
  output_dir: "/tmp/videos",
  filename_template: "%(uploader)s/%(title)s.%(ext)s",
  timeout: 3_600_000  # 1 hour
)
```

### Get Video Information

```elixir
# Fetch metadata without downloading
{:ok, info} = YtDlp.get_info("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

IO.puts("Title: #{info["title"]}")
IO.puts("Duration: #{info["duration"]} seconds")
IO.puts("Uploader: #{info["uploader"]}")
IO.puts("Views: #{info["view_count"]}")
```

### List All Downloads

```elixir
downloads = YtDlp.list_downloads()

Enum.each(downloads, fn download ->
  IO.puts("#{download.url} - #{download.status}")

  if download.status == :completed do
    IO.puts("  → #{download.result.path}")
  end
end)
```

### Cancel a Download

```elixir
{:ok, download_id} = YtDlp.download("https://example.com/video")

# Cancel if still pending
:ok = YtDlp.cancel(download_id)
```

### Check Installation

```elixir
case YtDlp.check_installation() do
  {:ok, version} -> IO.puts("yt-dlp version: #{version}")
  {:error, reason} -> IO.puts("yt-dlp not found: #{reason}")
end
```

## Configuration

Configure the application in `config/config.exs`:

```elixir
config :yt_dlp,
  # Maximum number of concurrent downloads
  max_concurrent_downloads: 3,

  # Default output directory for downloads
  output_dir: "./downloads"
```

You can also set the yt-dlp binary path via environment variable:

```bash
export YT_DLP_PATH=/custom/path/to/yt-dlp
```

## Architecture

The library uses Elixir's OTP principles for reliability:

```
YtDlp.Application (Supervisor)
    │
    └─→ YtDlp.Downloader (GenServer)
            │
            ├─→ Manages download queue
            ├─→ Tracks download status
            └─→ Spawns download tasks
                    │
                    └─→ YtDlp.Command (yt-dlp wrapper)
```

### Components

- **YtDlp**: Public API module - Main interface for users
- **YtDlp.Application**: OTP Application with supervision tree
- **YtDlp.Downloader**: GenServer managing download lifecycle and concurrency
- **YtDlp.Command**: Low-level module for executing yt-dlp commands

## Development

### Setup Development Environment

```bash
# Using Nix (recommended)
nix develop

# Install dependencies
mix deps.get

# Run tests
mix test

# Run type checking
mix dialyzer

# Run linting
mix credo
```

### Running Tests

```bash
# Run all tests
mix test

# Run without external network tests
mix test --exclude external

# Run with coverage
mix test --cover
```

### Building Documentation

```bash
mix docs
open doc/index.html
```

## NixOS Packaging

When packaging your application with Nix, make sure yt-dlp is available:

```nix
{
  buildInputs = [ pkgs.yt-dlp ];

  # Or set the path explicitly
  makeWrapperArgs = [
    "--set YT_DLP_PATH ${pkgs.yt-dlp}/bin/yt-dlp"
  ];
}
```

## Examples

### Download Multiple Videos

```elixir
urls = [
  "https://www.youtube.com/watch?v=video1",
  "https://www.youtube.com/watch?v=video2",
  "https://www.youtube.com/watch?v=video3"
]

# Queue all downloads
download_ids =
  Enum.map(urls, fn url ->
    {:ok, id} = YtDlp.download(url)
    id
  end)

# Wait for all to complete
results =
  Enum.map(download_ids, fn id ->
    # Poll until complete
    wait_for_download(id)
  end)

defp wait_for_download(id) do
  {:ok, status} = YtDlp.get_status(id)

  case status.status do
    :completed -> {:ok, status.result}
    :failed -> {:error, status.error}
    _ ->
      Process.sleep(1000)
      wait_for_download(id)
  end
end
```

### Download with Progress Monitoring

```elixir
{:ok, download_id} = YtDlp.download("https://example.com/video")

# Monitor progress
Task.start(fn ->
  monitor_download(download_id)
end)

defp monitor_download(download_id) do
  {:ok, status} = YtDlp.get_status(download_id)

  IO.puts("Status: #{status.status}")

  case status.status do
    :completed ->
      IO.puts("✓ Download complete: #{status.result.path}")

    :failed ->
      IO.puts("✗ Download failed: #{status.error}")

    _ ->
      Process.sleep(2000)
      monitor_download(download_id)
  end
end
```

## Troubleshooting

### yt-dlp not found

Ensure yt-dlp is installed and in your PATH:

```bash
# Check installation
which yt-dlp
yt-dlp --version

# Using Nix
nix develop
```

### Downloads failing

Check yt-dlp can access the URL:

```bash
yt-dlp --dump-json --skip-download "YOUR_URL"
```

### Permission errors

Ensure the output directory is writable:

```elixir
config :yt_dlp,
  output_dir: "/path/with/write/permissions"
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - See LICENSE file for details

## Credits

This library is a wrapper around [yt-dlp](https://github.com/yt-dlp/yt-dlp), which does all the heavy lifting for video downloading.
