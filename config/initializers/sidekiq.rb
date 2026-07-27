if defined?(Sidekiq)
  redis_config = {
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
    network_timeout: 2,
    pool_timeout: 2,
    ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_NONE }
  }

  Sidekiq.configure_server do |config|
    config.redis = redis_config.merge(size: 5)
  end

  Sidekiq.configure_client do |config|
    config.redis = redis_config.merge(size: 3)
  end
end
