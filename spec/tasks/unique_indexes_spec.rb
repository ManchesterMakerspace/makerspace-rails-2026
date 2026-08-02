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

  it 'creates the unique index when the target collection does not exist' do
    expect(SlackUser.collection.database.collection_names).not_to include(SlackUser.collection_name)

    expect { task.invoke }.not_to raise_error

    slack_id_index = SlackUser.collection.indexes.to_a.find do |index|
      index.fetch('key', {}).keys == ['slack_id']
    end
    expect(slack_id_index).to include('unique' => true)
  end
end
