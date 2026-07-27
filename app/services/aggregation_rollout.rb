class AggregationRollout
  def self.enabled?(endpoint)
    return true unless Rails.env.production?

    ENV["MONGO_AGGREGATION_#{endpoint.to_s.upcase}_ENABLED"] == "true"
  end
end
