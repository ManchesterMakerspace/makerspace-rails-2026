module Service
  class ErrorReporter
    def self.notify(error, context: {})
      Rails.logger.error(log_message(error, context))
      return unless defined?(Honeybadger)

      context.empty? ? Honeybadger.notify(error) : Honeybadger.notify(error, context: context)
    end

    def self.log_message(error, context)
      error_details = if error.respond_to?(:message)
        "#{error.class}: #{error.message}"
      else
        error.to_s
      end

      message = "[ErrorReporter] #{error_details}"
      message += " | context: #{context.inspect}" unless context.empty?
      message
    end
    private_class_method :log_message
  end
end
