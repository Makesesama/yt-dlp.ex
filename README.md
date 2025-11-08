# YtDlp.ex

An Elixir wrapper for [yt-dlp](https://github.com/yt-dlp/yt-dlp) with GenServer-based download management.

## Features

- 🚀 **Asynchronous Downloads**: Non-blocking video downloads with status tracking
- 🔄 **Concurrent Management**: Control multiple simultaneous downloads
- 📊 **Real-Time Progress Tracking**: Streaming progress updates via Elixir Ports (%, speed, ETA)
- ✅ **Cancellation Support**: Cancel active downloads mid-download
- 🎬 **FFmpeg Integration**: Extract audio, merge streams, generate thumbnails, embed subtitles
- 🎞️ **Membrane Support**: Advanced video processing with Elixir Membrane framework (optional)
- 🎯 **Simple API**: Clean, idiomatic Elixir interface
- 🛡️ **Supervised**: Built with OTP supervision for reliability
- 📦 **NixOS Ready**: Designed to work seamlessly with Nix flakes
- 🔍 **Metadata Extraction**: Get video info without downloading
- 🔌 **Port-Based Communication**: Uses Elixir Ports for streaming yt-dlp output

## Installation

Add `yt_dlp` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:yt_dlp, github: "Makesesama/yt-dlp.ex", branch: "main"}
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

### Real-Time Progress Tracking

```elixir
# Download with live progress updates
{:ok, download_id} = YtDlp.download(
  "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
  progress_callback: fn progress ->
    IO.write("\rDownloading: #{progress.percent}% of #{progress.total_size} at #{progress.speed} - ETA: #{progress.eta}")
  end
)

# Or check progress periodically
{:ok, download_id} = YtDlp.download("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

Task.start(fn ->
  monitor_progress(download_id)
end)

defp monitor_progress(download_id) do
  {:ok, status} = YtDlp.get_status(download_id)

  if status.progress do
    IO.puts("Progress: #{status.progress.percent}% - #{status.progress.speed}")
  end

  case status.status do
    :completed -> IO.puts("\n✓ Download complete!")
    :failed -> IO.puts("\n✗ Download failed: #{status.error}")
    _ ->
      Process.sleep(1000)
      monitor_progress(download_id)
  end
end
```

### Cancel Active Download

```elixir
{:ok, download_id} = YtDlp.download("https://www.youtube.com/watch?v=dQw4w9WgXcQ")

# Cancel it (even if actively downloading)
:ok = YtDlp.cancel(download_id)
```

### Post-Processing with FFmpeg

Extract audio, generate thumbnails, and more using yt-dlp's built-in ffmpeg integration:

```elixir
# Extract audio as MP3
{:ok, audio_path} = YtDlp.PostProcessor.extract_audio(
  url,
  format: :mp3,
  quality: "320K"
)

# Download best video + audio and merge
{:ok, result} = YtDlp.PostProcessor.download_and_merge(
  url,
  video_format: "bestvideo[height<=1080]",
  audio_format: "bestaudio",
  output_format: :mp4
)

# Extract thumbnail
{:ok, thumb_path} = YtDlp.PostProcessor.extract_thumbnail(url)

# Download with embedded subtitles
{:ok, video_path} = YtDlp.PostProcessor.download_with_subtitles(
  url,
  langs: ["en", "es"],
  auto_subs: true
)

# Use format helpers
YtDlp.download(url, format: YtDlp.PostProcessor.video_quality(1080))
YtDlp.download(url, format: YtDlp.PostProcessor.audio_only(:mp3, "192K"))
```

### Advanced Processing with Membrane

For Elixir-native video processing (requires ffmpeg + optional Membrane deps):

```elixir
# Generate thumbnail at specific timestamp
{:ok, thumb} = YtDlp.Membrane.generate_thumbnail(
  video_path,
  timestamp: 5.0,
  width: 1920,
  height: 1080
)

# Extract audio track
{:ok, audio} = YtDlp.Membrane.extract_audio_track(
  video_path,
  format: :mp3,
  bitrate: "320k"
)

# Create preview clip
{:ok, preview} = YtDlp.Membrane.create_preview(
  video_path,
  start_at: 10.0,
  duration: 30.0
)

# Transcode to different format
{:ok, transcoded} = YtDlp.Membrane.transcode(
  video_path,
  output_format: :webm,
  video_codec: "vp9",
  resolution: {1280, 720}
)

# Convenience: Download with auto-generated thumbnail
{:ok, %{video: video_path, thumbnail: thumb_path}} =
  YtDlp.Membrane.download_with_thumbnail(url, thumbnail_at: 5.0)
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

The library uses Elixir's OTP principles with Port-based communication for reliability and real-time updates:

```
YtDlp.Application (Supervisor)
    │
    └─→ YtDlp.Downloader (GenServer)
            │
            ├─→ Manages download queue
            ├─→ Tracks download status & progress
            ├─→ Stores Port PIDs for cancellation
            └─→ Spawns download tasks
                    │
                    └─→ YtDlp.Command (yt-dlp wrapper)
                            │
                            └─→ YtDlp.Port (GenServer)
                                    │
                                    └─→ Port (yt-dlp process)
                                            ├─→ Streams progress output
                                            ├─→ Can be killed for cancellation
                                            └─→ Returns file path on completion
```

### Components

- **YtDlp**: Public API module - Main interface for users
- **YtDlp.Application**: OTP Application with supervision tree
- **YtDlp.Downloader**: GenServer managing download lifecycle, concurrency, and progress
- **YtDlp.Command**: Low-level module for executing yt-dlp commands
- **YtDlp.Port**: GenServer for Port communication with streaming output parsing

### File Path for Waffle/S3 Integration

When a download completes, the result contains the absolute file path:

```elixir
{:ok, result} = YtDlp.download_sync("https://example.com/video")
# result = %{path: "/absolute/path/to/video.mp4", url: "https://example.com/video"}

# Perfect for uploading with Waffle:
MyApp.VideoUploader.store({result.path, scope})
```

The file path is guaranteed to:
- Be an absolute path
- Exist on disk when status is `:completed`
- Be verified before returning

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
