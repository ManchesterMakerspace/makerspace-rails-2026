module Service
  module DatabaseSafety
    SAFE_MLAB_URI_SUBSTRINGS = [
      '127.0.0.1',
      '://mongo:2701',
      'localhost',
      '/rspec',
      'dev',
      'test'
    ].freeze

    module_function

    def ensure_safe_mlab_uri!(operation: 'destructive database operation', mlab_uri: ENV['MLAB_URI'])
      mlab_uri = mlab_uri.to_s
      safe = mlab_uri.present? && SAFE_MLAB_URI_SUBSTRINGS.any? do |safe_value|
        mlab_uri.include?(safe_value)
      end
      return true if safe

      requirement = SAFE_MLAB_URI_SUBSTRINGS.join(', ')
      message = if mlab_uri.present?
        "Refusing to run #{operation}: MLAB_URI must contain one of #{requirement}."
      else
        "Refusing to run #{operation}: MLAB_URI is not set; set it to contain one of #{requirement}."
      end

      Rails.logger.error(message) if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      warn(message)
      raise message
    end
  end
end
