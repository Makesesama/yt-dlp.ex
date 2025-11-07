import Config

# Test configuration
config :yt_dlp,
  max_concurrent_downloads: 1,
  output_dir: "/tmp/yt_dlp_test"

# Reduce logging in tests
config :logger, level: :warning
