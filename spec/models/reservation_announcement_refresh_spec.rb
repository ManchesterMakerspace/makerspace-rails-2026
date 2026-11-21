require 'rails_helper'

RSpec.describe 'Reservation announcement refreshes' do
  around do |example|
    travel_to(ReservationService::ZONE.local(2026, 11, 20, 22)) { example.run }
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
  end

  let(:shop) { create(:shop) }

  it 'refreshes the local day when empty announcements or the shop channel changes' do
    existing = shop
    expect { existing.update!(slack_announce_empty_reservations: true) }
      .to have_enqueued_job(ReservationSlackAnnouncementJob).with('2026-11-20')
    expect { existing.update!(slack_channel: 'updated-shop') }
      .to have_enqueued_job(ReservationSlackAnnouncementJob).with('2026-11-20')
  end

  it 'refreshes when a tool moves between users channels or becomes unavailable' do
    tool = create(:tool, shop: shop)
    expect { tool.update!(users_channel: 'updated-tool-users') }
      .to have_enqueued_job(ReservationSlackAnnouncementJob).with('2026-11-20')
    expect { tool.update!(out_of_service: true) }
      .to have_enqueued_job(ReservationSlackAnnouncementJob).with('2026-11-20')
  end

  it 'refreshes when a tool moves to another shop or clears its users channel' do
    tool = create(:tool, shop: shop, users_channel: 'old-tool-users')
    destination = create(:shop)
    expect { tool.update!(shop: destination) }
      .to have_enqueued_job(ReservationSlackAnnouncementJob).with('2026-11-20')
    expect { tool.update!(users_channel: nil) }
      .to have_enqueued_job(ReservationSlackAnnouncementJob).with('2026-11-20')
  end

  it 'refreshes when a resource or blackout is deleted' do
    tool = create(:tool, shop: shop)
    blackout = create(:reservation_blackout, shop: shop)
    expect { tool.destroy! }.to have_enqueued_job(ReservationSlackAnnouncementJob).with('2026-11-20')
    expect { blackout.destroy! }.to have_enqueued_job(ReservationSlackAnnouncementJob).with('2026-11-20')
    expect { Shop.find(shop.id).destroy! }.to have_enqueued_job(ReservationSlackAnnouncementJob).with('2026-11-20')
  end

  it 'refreshes when blackout intervals change' do
    blackout = create(:reservation_blackout, shop: shop)
    expect { blackout.update!(start_time: '09:00') }
      .to have_enqueued_job(ReservationSlackAnnouncementJob).with('2026-11-20')
  end

  it 'does not refresh for unrelated shop metadata changes' do
    existing = shop
    expect { existing.update!(gdrive_id: 'folder') }.not_to have_enqueued_job(ReservationSlackAnnouncementJob)
  end
end
