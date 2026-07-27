namespace :performance do
  desc "Create Mongoid and externally-owned collection indexes"
  task prepare: [:invoice_option_indexes, "mongoid:create_indexes", :external_indexes]

  desc "Replace the legacy sparse plan_id index with a null-safe partial index"
  task invoice_option_indexes: :environment do
    indexes = InvoiceOption.collection.indexes
    existing = indexes.to_a.find { |index| index["name"] == "plan_id_1" }
    expected_filter = { "plan_id" => { "$type" => "string" } }
    existing_filter = existing&.dig("partialFilterExpression")&.to_h

    if existing && existing_filter != expected_filter
      indexes.drop_one("plan_id_1")
    end

    indexes.create_one(
      { plan_id: 1 },
      name: "plan_id_1",
      unique: true,
      partial_filter_expression: expected_filter
    )
  end

  desc "Create indexes for checkins/rejections without caching those collections"
  task external_indexes: :environment do
    checkins = Mongoid.default_client[:checkins]
    checkins.indexes.create_one(
      { uid: 1, timeOf: -1 },
      name: "uid_timeOf"
    )
    checkins.indexes.create_one(
      { uid: 1, time: -1 },
      name: "uid_time"
    )

    rejections = Mongoid.default_client[:rejections]
    rejections.indexes.create_one(
      { uid: 1, timeOf: -1 },
      name: "uid_timeOf"
    )
  end
end
