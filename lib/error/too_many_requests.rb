require_relative 'custom_error'
module Error
  class TooManyRequests < CustomError
    def initialize(message = 'Too many requests. Please wait a moment and try again.')
      super(:too_many_requests, 429, message)
    end
  end
end
