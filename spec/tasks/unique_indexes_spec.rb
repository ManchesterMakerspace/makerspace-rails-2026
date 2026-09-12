require 'rails_helper'
require 'rake'

RSpec.describe 'data:ensure_unique_indexes' do
  let(:task) { Rake::Task['data:ensure_unique_indexes'] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('data:ensure_unique_indexes')
    task.reenable
    Service::DatabaseSafety.ensure_safe_mlab_uri!(operation: 'SlackUser test collection drop')

    begin
      SlackUser.collection.drop
    rescue Mongo::Error::OperationFailure => error
      raise unless error.code == 26
    end
  end

  after do
    task.reenable
  end

  [nil, :partial, :sparse].each do |existing_kind|
    it "creates full shortcode indexes from #{existing_kind || 'a clean collection'}" do
      Shortcode.collection.drop
      if existing_kind
        %w[code target_url].each do |field|
          options = { unique: true }
          options[:partial_filter_expression] = { field => { '$type' => 'string' } } if existing_kind == :partial
          options[:sparse] = true if existing_kind == :sparse
          Shortcode.collection.indexes.create_one({ field => 1 }, options)
        end
      end
      task.invoke
      %w[code target_url].each do |field|
        index = Shortcode.collection.indexes.to_a.find { |entry| entry['key'] == { field => 1 } }
        expect(index['unique']).to eq(true)
        expect(index).not_to have_key('partialFilterExpression')
        expect(index['sparse']).not_to eq(true)
      end
      ShortUrl.instance_variable_set(:@indexes_verified, false)
      expect { ShortUrl.verify_indexes! }.not_to raise_error
      # Re-running the release task recognizes and retains the full indexes.
      task.reenable
      expect { task.invoke }.not_to raise_error
    end
  end

  it 'creates the unique index when the target collection does not exist' do
    expect(SlackUser.collection.database.collection_names).not_to include(SlackUser.collection_name)

    expect { task.invoke }.not_to raise_error

    slack_id_index = SlackUser.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['slack_id']
    end
    expect(slack_id_index).to include('unique' => true)

    %w[member_id slack_email].each do |field|
      index = SlackUser.collection.indexes.to_a.find do |candidate|
        candidate.fetch('key', {}).keys == [field]
      end
      expect(index).to include('unique' => true)
    end
    member_id_index = SlackUser.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['member_id']
    end
    expect(member_id_index.fetch('partialFilterExpression')).to eq(
      'member_id' => { '$type' => 'objectId' },
      'invalidated_at' => nil
    )
    slack_email_index = SlackUser.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['slack_email']
    end
    expect(slack_email_index.fetch('partialFilterExpression')).to eq(
      'slack_email' => { '$type' => 'string' },
      'invalidated_at' => nil
    )

    transaction_id_index = Invoice.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['transaction_id']
    end
    expect(transaction_id_index).to include('unique' => true)
    expect(transaction_id_index.fetch('partialFilterExpression')).to eq(
      'transaction_id' => { '$type' => 'string' }
    )
  end

  it 'creates non-unique member indexes on member-owned collections' do
    expect { task.invoke }.not_to raise_error

    %w[
      permissions earned_memberships invoices notes rentals payments cards
      mailtrap_messages volunteer_credits tool_checkouts
    ].each do |collection_name|
      index = Mongoid.default_client[collection_name].indexes.to_a.find do |candidate|
        candidate.fetch('key', {}).keys == ['member_id']
      end

      expect(index).to be_present
      expect(index['unique']).not_to be(true)
    end
  end

  it 'creates and recognizes a case-insensitive unique tool-name index scoped per shop' do
    Tool.delete_all
    shop_a_id = BSON::ObjectId.new
    shop_b_id = BSON::ObjectId.new

    expect { task.invoke }.not_to raise_error

    tool_name_index = Tool.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['shop_id', 'name']
    end
    expect(tool_name_index).to include('unique' => true)
    expect(tool_name_index.fetch('collation')).to include('locale' => 'en', 'strength' => 2)

    Tool.collection.insert_one(shop_id: shop_a_id, name: 'Hand Tools')

    # Same name, different shop -- allowed, this is the whole point of the change
    expect do
      Tool.collection.insert_one(shop_id: shop_b_id, name: 'Hand Tools')
    end.not_to raise_error

    # Same name, same shop, different case -- still rejected
    expect do
      Tool.collection.insert_one(shop_id: shop_a_id, name: 'hand tools')
    end.to raise_error(Mongo::Error::OperationFailure, /duplicate key/i)
  end

  it 'rejects tool names that differ only by case within the same shop before creating the index' do
    Tool.delete_all
    Tool.collection.indexes.to_a.each do |index|
      keys = index.fetch('key', {}).keys
      next unless keys == ['name'] || keys == ['shop_id', 'name']

      Tool.collection.indexes.drop_one(index.fetch('name'))
    end
    shop_id = BSON::ObjectId.new
    Tool.collection.insert_many([{ shop_id: shop_id, name: 'Lathe' }, { shop_id: shop_id, name: 'lathe' }])

    expect { task.invoke }.to raise_error(
      RuntimeError,
      /Cannot create unique index on tools\.\(shop_id, name\).*Lathe.*records/i
    )
  ensure
    Tool.collection.delete_many({})
    task.reenable
    task.invoke
  end

  it 'creates a case-insensitive unique shop-name index' do
    Shop.delete_all

    expect { task.invoke }.not_to raise_error

    shop_name_index = Shop.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['name']
    end
    expect(shop_name_index).to include('unique' => true)
    expect(shop_name_index.fetch('collation')).to include('locale' => 'en', 'strength' => 2)

    Shop.collection.insert_one(name: 'Woodshop')
    expect do
      Shop.collection.insert_one(name: 'woodshop')
    end.to raise_error(Mongo::Error::OperationFailure, /duplicate key/i)
  end

  it 'creates a partial unique member customer-id index that permits nil values' do
    expect { task.invoke }.not_to raise_error

    customer_id_index = Member.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['customer_id']
    end
    expect(customer_id_index).to include('unique' => true)
    expect(customer_id_index.fetch('partialFilterExpression')).to eq(
      'customer_id' => { '$type' => 'string' }
    )

    inserted_ids = Member.collection.insert_many([
      { customer_id: nil },
      { customer_id: nil }
    ]).inserted_ids
    expect(inserted_ids.length).to eq(2)
  ensure
    Member.collection.delete_many('_id' => { '$in' => inserted_ids }) if inserted_ids.present?
  end
end
