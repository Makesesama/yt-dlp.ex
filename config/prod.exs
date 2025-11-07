import Config

# Production configuration
config :yt_dlp,
  max_concurrent_downloads: 5,
  output_dir: "/var/lib/yt_dlp/downloads"
