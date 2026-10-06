# frozen_string_literal: true

# Load the central infrastructure configuration (domain, IP addresses, Exchange)
# from config/infrastructure.yml so that the application and its services read
# network/infrastructure values from a single source of truth instead of
# hardcoding them.
#
# Access it from anywhere in the app as:
#   Rails.application.config.infrastructure[:ad][:host]
require "yaml"

base            = File.expand_path("../infrastructure.yml", __dir__)
infrastructure  = File.exist?(base) ? YAML.load_file(base, aliases: true) : {}

Rails.application.config.infrastructure = (infrastructure || {}).deep_symbolize_keys
