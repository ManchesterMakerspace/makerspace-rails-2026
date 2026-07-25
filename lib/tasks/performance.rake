namespace :performance do
  desc "Create Mongoid and externally-owned collection indexes"
  task prepare: ["mongoid:create_indexes", :external_indexes]

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
