class CachedPayload
  class << self
    def collection(key, criteria, serializer:, dependencies:, **serializer_options)
      MongoCache.fetch(key, dependencies: dependencies) do
        records = criteria.to_a
        ActiveModelSerializers::SerializableResource.new(
          records,
          {
            each_serializer: serializer,
            adapter: :attributes
          }.merge(serializer_options)
        ).as_json
      end
    end
  end
end
