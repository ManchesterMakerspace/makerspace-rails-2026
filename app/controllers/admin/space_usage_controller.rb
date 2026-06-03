require "set"

class Admin::SpaceUsageController < AdminController

  # GET /api/admin/space_usage
  #
  # Unique member door checkins per day or per calendar month.
  # One checkin per card UID per day is counted (deduped by uid+date).
  # Card UIDs are joined to member IDs via the cards collection.
  #
  # Params:
  #   granularity  'day' | 'month' (default: 'month')
  #   year         integer — required for granularity=day; optional for month
  #   month        integer 1-12 — combined with year for daily view
  #   rolling      '30' — return last 30 days regardless of year/month params
  #
  # Response: [{ date: "2024-01" | "2024-01-15", unique_members: 42 }, ...]
  def index
    granularity = params[:granularity] == 'day' ? :day : :month

    # Build time range
    if params[:rolling] == '30'
      start_time = (Date.today - 30.days).to_time.to_i * 1000
      end_time   = Time.now.to_i * 1000
    elsif params[:year].present?
      year = params[:year].to_i
      if granularity == :day && params[:month].present?
        month      = params[:month].to_i
        start_date = Date.new(year, month, 1)
        end_date   = start_date.end_of_month
      else
        start_date = Date.new(year, 1, 1)
        end_date   = Date.new(year, 12, 31)
      end
      start_time = start_date.to_time.to_i * 1000
      end_time   = end_date.to_time.to_i * 1000 + 86_399_999 # end of day
    else
      # Default: current year
      start_time = Date.new(Date.today.year, 1, 1).to_time.to_i * 1000
      end_time   = Time.now.to_i * 1000
    end

    checkins_col = Mongoid.default_client[:checkins]
    cards_col    = Mongoid.default_client[:cards]

    # Build a uid → member_id lookup from the cards collection
    uid_to_member = {}
    cards_col.find({}, projection: { uid: 1, member_id: 1 }).each do |doc|
      uid_to_member[doc['uid'].to_s] = doc['member_id'].to_s if doc['uid'].present? && doc['member_id'].present?
    end

    # Fetch raw checkins in range
    raw = checkins_col.find(
      timeOf: { '$gte' => start_time, '$lte' => end_time }
    ).projection(uid: 1, timeOf: 1).to_a

    # Deduplicate: one entry per (member_id, date_bucket)
    # timeOf is stored as milliseconds since epoch
    seen = {}
    raw.each do |doc|
      uid       = doc['uid'].to_s
      member_id = uid_to_member[uid]
      next if member_id.blank?

      ts   = Time.at(doc['timeOf'].to_i / 1000.0).utc
      date = ts.to_date
      key  = granularity == :day ? date.strftime('%Y-%m-%d') : date.strftime('%Y-%m')

      seen[key] ||= Set.new
      seen[key].add(member_id)
    end

    # Build sorted result
    data = seen.map { |date_key, members| { date: date_key, unique_members: members.size } }
               .sort_by { |d| d[:date] }

    render json: data
  end

  # GET /api/admin/space_usage/date_range
  # Returns the earliest and latest checkin timestamps so the UI
  # can populate the year/month selectors accurately.
  def date_range
    checkins_col = Mongoid.default_client[:checkins]

    earliest = checkins_col.find.sort(timeOf: 1).limit(1).first
    latest   = checkins_col.find.sort(timeOf: -1).limit(1).first

    if earliest.nil?
      render json: { earliest_year: Date.today.year, latest_year: Date.today.year } and return
    end

    earliest_year = Time.at(earliest['timeOf'].to_i / 1000.0).utc.year
    latest_year   = Time.at(latest['timeOf'].to_i / 1000.0).utc.year

    render json: { earliest_year: earliest_year, latest_year: latest_year }
  end
end
