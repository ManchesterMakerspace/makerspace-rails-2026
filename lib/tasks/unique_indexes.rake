namespace :data do
  desc "Verify and create unique indexes for core identity fields"
  task ensure_unique_indexes: :environment do
    targets = [
      [Tool, :name],
      [Shop, :name],
      [Card, :uid],
      [Group, :groupName],
      [Member, :email]
    ]

    targets.each do |model, field|
      duplicates = model.collection.aggregate([
        {
          '$group' => {
            '_id' => "$#{field}",
            'count' => { '$sum' => 1 }
          }
        },
        { '$match' => { 'count' => { '$gt' => 1 } } }
      ]).to_a

      non_nil_duplicates = duplicates.reject { |entry| entry['_id'].nil? }
      if non_nil_duplicates.any?
        summary = non_nil_duplicates.map do |entry|
          "#{entry['_id'].inspect} (#{entry['count']} records)"
        end.join(', ')
        raise "Cannot create unique index on #{model.collection_name}.#{field}: #{summary}"
      end

      if duplicates.any?
        puts "#{model.collection_name}.#{field}: duplicate nil/missing values found; using the model's partial unique index"
      else
        puts "#{model.collection_name}.#{field}: no duplicate values found"
      end

      model.create_indexes
      puts "#{model.collection_name}.#{field}: unique index enabled"
    end
  end
end
