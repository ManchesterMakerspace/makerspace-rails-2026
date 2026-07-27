class CachedPayload
  class << self
    def collection(key, criteria, serializer:, dependencies:, **serializer_options)
      MongoCache.fetch(key, dependencies: dependencies) do
        criteria.to_a.map do |record|
          ActiveModelSerializers::SerializableResource.new(
            record,
            {
              serializer: serializer,
              adapter: :attributes
            }.merge(serializer_options)
          ).as_json
        end
      end
    end
  end
end
