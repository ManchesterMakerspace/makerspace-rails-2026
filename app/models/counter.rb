class Counter
  include Mongoid::Document

  INT32_MAX = 2_147_483_647

  store_in collection: "counter"

  field :seq, type: Integer

  def self.next_sequence_id(sequence_name)
    counter = where(_id: sequence_name, :seq.lt => INT32_MAX).find_one_and_update(
      { "$inc" => { seq: 1 } },
      upsert: true,
      return_document: :after
    )

    counter.seq.to_i
  rescue Mongo::Error::OperationFailure => error
    raise unless error.code == 11_000 && where(_id: sequence_name, :seq.gte => INT32_MAX).exists?

    Rails.logger.warn("Counter sequence #{sequence_name.inspect} has reached the Int32 maximum")
    nil
  end
end
