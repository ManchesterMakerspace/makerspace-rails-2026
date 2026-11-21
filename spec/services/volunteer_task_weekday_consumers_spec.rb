require 'rails_helper'

RSpec.describe 'Volunteer weekday consumers' do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop, name: 'Woodshop') }
  let!(:matching) do
    VolunteerTask.create!(title: 'Thursday cleanup', description: 'Organize supplies', status: 'repeatable',
      shop_id: shop.id, day_of_week: 4)
  end
  let!(:other) do
    VolunteerTask.create!(title: 'Friday cleanup', description: 'Organize supplies', status: 'repeatable',
      shop_id: shop.id, day_of_week: 5)
  end

  around do |example|
    travel_to(Time.utc(2026, 11, 20, 1)) { example.run }
  end

  it 'uses the same weekday restriction in workshop opportunities and Slack canvases' do
    projected = WorkshopSerializer.new(shop, scope: member).volunteer_tasks
    expect(projected.map { |row| row[:id] }).to eq([matching.id.to_s])
    canvas_tasks = Service::VolunteerSlackCanvas.send(:available_tasks, shop)
    expect(canvas_tasks.map(&:id)).to eq([matching.id])
  end

  it 'hides off-day tasks from Slack lists and rejects direct Slack claim references' do
    job = SlackVolunteerJob.new
    expect(job).to receive(:post_response) do |_, _, text|
      expect(text).to include(matching.title)
      expect(text).not_to include(other.title)
    end
    job.send(:handle_tasks, 'https://example.test/slack', member)

    expect(job).to receive(:post_response).with('https://example.test/slack', :ephemeral,
      a_string_including('not available to claim'))
    job.send(:handle_claim, 'https://example.test/slack', member, other.task_number.to_s)
    expect(VolunteerTask.where(parent_task_id: other.id)).to be_empty
  end
end
