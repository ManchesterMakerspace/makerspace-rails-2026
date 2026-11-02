require 'rails_helper'

RSpec.describe ReaderReservationService do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:member) { create(:member, :current) }
  let(:reader_id) { BSON::ObjectId.new }
  let(:checkin_id) { BSON::ObjectId.new }
  let(:start) { Time.utc(2026,11,2,18) }
  let(:reservation) { Reservation.create!(title:'Bench', shop:shop, member:member, reservation_scope:'tools',
    tool_ids:[tool.id.to_s], start_at:start, end_at:start+1.hour, status:'approved') }
  def db(name) = Mongoid.default_client[name]
  def ms(time) = (time.to_f*1000).to_i
  def operation(kind, **extra)
    { 'kind'=>kind, 'reservationId'=>reservation.id.to_s, 'revision'=>reservation.reload.reader_revision }.merge(extra.stringify_keys)
  end
  def sync(op, id: reader_id)
    described_class.sync!('deviceId'=>id.to_s,'operations'=>[op])[:results].first
  end
  def insert_checkin(at=start)
    db('checkins').insert_one(_id:checkin_id,deviceId:reader_id,memberId:member.id.to_s,toolId:tool.id.to_s,timeOf:at,validity:'activeMember')
  end
  before do
    travel_to(start-1.hour)
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    ActiveJob::Base.queue_adapter=:test
    db('nfc_readers').insert_one(_id:reader_id,enabled:true,role:'tool',toolId:tool.id,reservationEnabled:true)
  end
  after { travel_back }

  it 'claims at the inclusive late boundary and acknowledges exact retries' do
    insert_checkin(start+15.minutes)
    travel_to(start+15.minutes)
    op=operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current))
    expect(sync(op)[:outcome]).to eq('accepted')
    expect(reservation.reload.arrived_at).to eq(Time.current)
    expect(sync(op).with_indifferent_access[:outcome]).to eq('accepted')
    expect { sync(op.merge('observedAt'=>ms(Time.current)-1)) }.to raise_error(described_class::Conflict)
  end

  it 'rejects arrival before one hour and after fifteen minutes' do
    insert_checkin(start-2.hours)
    [start-1.hour-1.second,start+15.minutes+1.second].each do |time|
      travel_to(time)
      expect { sync(operation('claim',checkinId:checkin_id.to_s,observedAt:ms(time))) }.to raise_error(ArgumentError,/window/)
    end
  end

  it 'waits for every frozen participant and preserves fees on abandonment' do
    second=BSON::ObjectId.new
    db('nfc_readers').insert_one(_id:second,enabled:true,role:'tool',toolId:tool.id,reservationEnabled:true)
    reservation.set(invoice:'historical-paid-invoice',fee_snapshot:[{'amount'=>25}])
    sync(operation('monitor'))
    travel_to(start+15.minutes+1.second)
    checkpoint=operation('checkpoint',coveredFrom:ms(start-1.hour),through:ms(Time.current),uncertain:false)
    sync(checkpoint)
    expect(reservation.reload.status).to eq('approved')
    sync(checkpoint,id:second)
    expect(reservation.reload.status).to eq('abandoned')
    expect(reservation).not_to be_blocking
    expect(reservation.invoice).to eq('historical-paid-invoice')
    expect(reservation.fee_snapshot).to eq([{'amount'=>25}])
    expect(ReservationCalendarSyncJob).to have_been_enqueued
  end

  it 'does not abandon at the inclusive boundary or with uncertain coverage' do
    sync(operation('monitor'))
    travel_to(start+15.minutes)
    sync(operation('checkpoint',coveredFrom:ms(start-1.hour),through:ms(Time.current),uncertain:false))
    expect(reservation.reload.status).to eq('approved')
    travel_to(start+16.minutes)
    sync(operation('checkpoint',coveredFrom:ms(start-1.hour),through:ms(Time.current),uncertain:true))
    expect(reservation.reload.status).to eq('approved')
  end

  it 'does not retroactively monitor a historical booking' do
    travel_to(start+2.hours)
    expect(sync(operation('monitor'))).to include(monitored: false, arrivedAt: nil)
    sync(operation('checkpoint',coveredFrom:ms(start-1.hour),through:ms(Time.current),uncertain:false))
    expect(reservation.reload.status).to eq('approved')
    expect(reservation.reader_monitors).to be_empty
  end

  it 'finds an offline arrival even when that reader had not yet learned the booking' do
    expect(sync(operation('monitor'))).to include(monitored: true, arrivedAt: nil)
    insert_checkin(start+5.minutes)
    travel_to(start+16.minutes)
    expect(sync(operation('checkpoint',coveredFrom:ms(start-1.hour),through:ms(Time.current),uncertain:false))).to include(monitored: true, arrivedAt: ms(start+5.minutes))
    expect(reservation.reload.status).to eq('approved')
    expect(reservation.arrived_at).to eq(start+5.minutes)
  end

  it 'releases an offline qualifying session that voluntarily ended before reconnect' do
    sync(operation('monitor'))
    insert_checkin(start+5.minutes)
    db('checkend').insert_one(_id:BSON::ObjectId.new,deviceId:reader_id,checkinId:checkin_id.to_s,
      reason:'logoff',kicked:false,timeOf:start+10.minutes)
    travel_to(start+16.minutes)
    sync(operation('checkpoint',coveredFrom:ms(start-1.hour),through:ms(Time.current),uncertain:false))
    expect(reservation.reload.status).to eq('cancelled')
    expect(reservation.decision_note).to eq('released_on_logoff')
  end

  it 'retains an arrival through end-time edits, but revalidates start changes' do
    insert_checkin(start-1.hour)
    sync(operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current)))
    reservation.reload.update!(end_at:start+2.hours)
    expect(reservation.arrived_at).to be_present
    expect(reservation.reader_revision).to eq(1)
    reservation.update!(start_at:start+30.minutes)
    expect(reservation.arrived_at).to be_nil
    expect(reservation.reader_revision).to eq(2)
  end

  it 'releases the whole booking only for voluntary logoff and retries sync enqueue failures' do
    insert_checkin(start-1.hour)
    sync(operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current)))
    ending=BSON::ObjectId.new
    db('checkend').insert_one(_id:ending,deviceId:reader_id,checkinId:checkin_id.to_s,toolId:tool.id.to_s,
      memberId:member.id.to_s,timeOf:start,reason:'logoff',kicked:false)
    travel_to(start)
    op=operation('release',checkendId:ending.to_s)
    allow(ReservationCalendarSyncJob).to receive(:perform_later).and_raise('queue unavailable')
    expect { sync(op) }.to raise_error('queue unavailable')
    expect(reservation.reload.status).to eq('cancelled')
    expect(reservation.reader_sync_pending).to be(true)
    allow(ReservationCalendarSyncJob).to receive(:perform_later).and_call_original
    expect(sync(op).with_indifferent_access[:outcome]).to eq('accepted')
    expect(reservation.reload.reader_sync_pending).to be(false)
    expect(reservation.decision_note).to eq('released_on_logoff')
  end

  it 'rejects cross-tool claims and defers an unsynchronized session event' do
    expect { sync(operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current))) }.to raise_error(described_class::Conflict)
    insert_checkin(start-1.hour)
    db('checkins').find(_id:checkin_id).update_one('$set'=>{'toolId'=>BSON::ObjectId.new.to_s})
    expect { sync(operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current))) }.to raise_error(ArgumentError,/scope/)
  end

  it 'does not restore old coverage after participant configuration changes' do
    sync(operation('monitor'))
    travel_to(start+16.minutes)
    db('nfc_readers').find(_id:reader_id).update_one('$inc'=>{'reservationCoverageRevision'=>2})
    sync(operation('checkpoint',coveredFrom:ms(start-1.hour),through:ms(Time.current),uncertain:false))
    expect(reservation.reload.status).to eq('approved')
  end

  it 'defers a carried session whose reboot ending has no trusted timestamp' do
    sync(operation('monitor'))
    insert_checkin(start-2.hours)
    db('checkend').insert_one(_id:BSON::ObjectId.new,deviceId:reader_id,checkinId:checkin_id.to_s,
      reason:'reboot',kicked:false,timeOf:nil)
    travel_to(start+16.minutes)
    sync(operation('checkpoint',coveredFrom:ms(start-1.hour),through:ms(Time.current),uncertain:false))
    expect(reservation.reload.status).to eq('approved')
    expect(reservation.arrived_at).to be_nil
  end

  it 'claims the whole shop from an equipped tool and fences delayed claims after rescheduling' do
    reservation.update!(reservation_scope:'shop',tool_ids:[])
    insert_checkin(start-1.hour)
    op=operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current))
    reservation.update!(start_at:start+30.minutes)
    expect(sync(op)[:outcome]).to eq('stale')
    expect(reservation.reload.arrived_at).to be_nil
    travel_to(start)
    expect(sync(operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current)))[:outcome]).to eq('accepted')
    expect(reservation.reload.arrival_tool_id).to eq(tool.id.to_s)
  end

  it 'waits for an earlier applicable booking before associating an existing owner' do
    reservation
    blocker=Reservation.create!(title:'Earlier',shop:shop,member:member,reservation_scope:'tools',
      tool_ids:[tool.id.to_s],start_at:start-30.minutes,end_at:start+5.minutes,status:'approved')
    insert_checkin(start-1.hour)
    expect(sync(operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current)))[:outcome]).to eq('blocked')
    travel_to(blocker.end_at)
    expect(sync(operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current)))[:outcome]).to eq('accepted')
  end

  it 'never treats a kick as voluntary release' do
    insert_checkin(start-1.hour)
    sync(operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current)))
    ending=BSON::ObjectId.new
    db('checkend').insert_one(_id:ending,deviceId:reader_id,checkinId:checkin_id.to_s,toolId:tool.id.to_s,
      memberId:member.id.to_s,timeOf:start,reason:'kicked',kicked:true)
    travel_to(start)
    expect { sync(operation('release',checkendId:ending.to_s)) }.to raise_error(ArgumentError,/Voluntary/)
    expect(reservation.reload.status).to eq('approved')
  end

  it 'retires stale work after a booking moves to another tool without mutating it' do
    insert_checkin(start-1.hour)
    op=operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current))
    replacement=create(:tool,shop:shop)
    reservation.update!(tool_ids:[replacement.id.to_s])
    expect(sync(op)[:outcome]).to eq('stale')
    expect(reservation.reload.arrived_at).to be_nil
  end

  it 'records positive offline evidence without waiting for every other participant' do
    db('nfc_readers').insert_one(_id:BSON::ObjectId.new,enabled:true,role:'tool',toolId:tool.id,reservationEnabled:true)
    sync(operation('monitor'))
    insert_checkin(start)
    travel_to(start+16.minutes)
    sync(operation('checkpoint',coveredFrom:ms(start-1.hour),through:ms(Time.current),uncertain:false))
    expect(reservation.reload.arrived_at).to eq(start)
    expect(reservation.status).to eq('approved')
  end

  it 'does not use a session ended before a reschedule to release the revised booking' do
    reservation
    insert_checkin(start)
    db('checkend').insert_one(_id:BSON::ObjectId.new,deviceId:reader_id,checkinId:checkin_id.to_s,
      reason:'logoff',kicked:false,timeOf:start+5.minutes)
    travel_to(start+10.minutes)
    reservation.update!(start_at:start+15.minutes)
    sync(operation('monitor'))
    travel_to(start+31.minutes)
    sync(operation('checkpoint',coveredFrom:ms(start-1.hour),through:ms(Time.current),uncertain:false))
    expect(reservation.reload.status).to eq('abandoned')
    expect(reservation.arrived_at).to be_nil
  end

  it 'fences concurrent reader writes even if both pass an expired shop lock' do
    insert_checkin(start-1.hour)
    second=BSON::ObjectId.new
    other_event=BSON::ObjectId.new
    db('nfc_readers').insert_one(_id:second,enabled:true,role:'tool',toolId:tool.id,reservationEnabled:true)
    db('checkins').insert_one(_id:other_event,deviceId:second,memberId:member.id.to_s,
      toolId:tool.id.to_s,timeOf:start-1.hour,validity:'activeMember')
    first_op=operation('claim',checkinId:checkin_id.to_s,observedAt:ms(Time.current))
    other_op=first_op.merge('checkinId'=>other_event.to_s)
    ready=Queue.new
    gate=Queue.new
    allow(described_class).to receive(:commit).and_wrap_original do |method, *args|
      ready << true
      gate.pop
      method.call(*args)
    end
    workers=[[first_op,reader_id],[other_op,second]].map do |op,id|
      Thread.new do
        sync(op,id:id)
      rescue described_class::Conflict => error
        error
      end
    end
    Timeout.timeout(15) { 2.times { ready.pop } }
    2.times { gate << true }
    results=workers.map(&:value)
    expect(results.count { |result| result.is_a?(described_class::Conflict) }).to eq(1)
    allow(described_class).to receive(:commit).and_call_original
    expect(sync(first_op).with_indifferent_access[:outcome]).to eq('accepted')
    expect(sync(other_op,id:second).with_indifferent_access[:outcome]).to eq('accepted')
    expect(reservation.reload.reader_receipts.size).to eq(2)
  ensure
    workers&.each { |worker| worker.kill if worker.alive? }
  end
end
