require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Serve static files from public/ via Passenger/Apache.
  config.public_file_server.enabled = true

  # No TLS termination configured yet -> plain HTTP.
  config.force_ssl = false

  # Secret key base from ENV or a server-side file (never committed to git).
  secret_key_file = "/etc/adruby/secret_key"
  config.secret_key_base =
    if ENV["SECRET_KEY_BASE"].present?
      ENV["SECRET_KEY_BASE"]
    elsif File.exist?(secret_key_file)
      File.read(secret_key_file).strip
    else
      raise "SECRET_KEY_BASE is not configured"
    end

  # Compress / assets
  config.assets.compile = false

  # Log to file (Passenger).
  config.logger = ActiveSupport::Logger.new(Rails.root.join("log/production.log"))
                   .then { |l| ActiveSupport::TaggedLogging.new(l) }
  config.log_tags = [:request_id]
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # No database, cache is in-memory (set in config/initializers/session_store.rb).

  config.i18n.fallbacks = true
  config.active_support.report_deprecations = false

  # Allow access by IP and hostname (internal tool, no DNS-rebinding protection).
  config.host_authorization = { exclude: ->(_request) { true } }
  config.hosts.clear

  # Cache store (in-memory, server-side sessions rely on it).
  config.cache_store = :memory_store, { size: 32.megabytes }
end
