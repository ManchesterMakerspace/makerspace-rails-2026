require "set"

class Admin::SpaceUsageController < AdminController
  def index
    granularity = params[:granularity] == "day" ? :day : :month
    start_time, end_time = requested_range(granularity)
    format = granularity == :day ? "%Y-%m-%d" : "%Y-%m"

    data = if AggregationRollout.enabled?("space_usage")
      aggregated_usage(start_time, end_time, format)
    else
      legacy_usage(start_time, end_time, granularity)
    end

    render plain: data.to_json, content_type: "application/json"
  end

  def date_range
    range = Mongoid.default_client[:checkins].aggregate([
      {
        "$set" => {
          "_rawTimestamp" => {
            "$convert" => {
              "input" => { "$ifNull" => ["$timeOf", "$time"] },
              "to" => "long",
              "onError" => nil,
              "onNull" => nil
            }
          }
        }
      },
      { "$match" => { "_rawTimestamp" => { "$ne" => nil } } },
      {
        "$set" => {
          "_timestampSeconds" => {
            "$cond" => [
              { "$gt" => ["$_rawTimestamp", CheckinTimeHelper::SECONDS_MS_THRESHOLD] },
              { "$divide" => ["$_rawTimestamp", 1000] },
              "$_rawTimestamp"
            ]
          }
        }
      },
      {
        "$group" => {
          "_id" => nil,
          "earliest" => { "$min" => "$_timestampSeconds" },
          "latest" => { "$max" => "$_timestampSeconds" }
        }
      }
    ]).first

    years = if range
      {
        earliest_year: Time.at(range["earliest"]).utc.year,
        latest_year: Time.at(range["latest"]).utc.year
      }
    else
      { earliest_year: Date.current.year, latest_year: Date.current.year }
    end

    render plain: years.to_json, content_type: "application/json"
  end

  private

  def aggregated_usage(start_time, end_time, format)
    Mongoid.default_client[:checkins].aggregate([
      { "$match" => { "$or" => CheckinTimeHelper.dual_unit_or_query(start_time, end_time) } },
      {
        "$set" => {
          "_rawTimestamp" => {
            "$convert" => {
              "input" => { "$ifNull" => ["$timeOf", "$time"] },
              "to" => "long",
              "onError" => nil,
              "onNull" => nil
            }
          }
        }
      },
      {
        "$set" => {
          "_timestampMs" => {
            "$cond" => [
              { "$gt" => ["$_rawTimestamp", CheckinTimeHelper::SECONDS_MS_THRESHOLD] },
              "$_rawTimestamp",
              { "$multiply" => ["$_rawTimestamp", 1000] }
            ]
          }
        }
      },
      { "$match" => { "_timestampMs" => { "$gte" => start_time, "$lte" => end_time } } },
      {
        "$lookup" => {
          "from" => Card.collection_name,
          "localField" => "uid",
          "foreignField" => "uid",
          "as" => "_card"
        }
      },
      { "$unwind" => "$_card" },
      {
        "$group" => {
          "_id" => {
            "date" => {
              "$dateToString" => {
                "format" => format,
                "date" => { "$convert" => { "input" => "$_timestampMs", "to" => "date" } },
                "timezone" => "UTC"
              }
            },
            "member_id" => "$_card.member_id"
          }
        }
      },
      { "$group" => { "_id" => "$_id.date", "unique_members" => { "$sum" => 1 } } },
      { "$sort" => { "_id" => 1 } },
      { "$project" => { "_id" => 0, "date" => "$_id", "unique_members" => 1 } }
    ], allow_disk_use: true).to_a
  end

  def legacy_usage(start_time, end_time, granularity)
    uid_to_member = Mongoid.default_client[:cards]
      .find({}, projection: { uid: 1, member_id: 1 })
      .each_with_object({}) do |document, lookup|
        if document["uid"].present? && document["member_id"].present?
          lookup[document["uid"].to_s] = document["member_id"].to_s
        end
      end

    seen = Hash.new { |hash, key| hash[key] = Set.new }
    Mongoid.default_client[:checkins]
      .find("$or" => CheckinTimeHelper.dual_unit_or_query(start_time, end_time))
      .projection(uid: 1, timeOf: 1, time: 1)
      .each do |document|
        member_id = uid_to_member[document["uid"].to_s]
        seconds = CheckinTimeHelper.normalize_to_seconds(
          document["timeOf"].presence || document["time"]
        )
        next if member_id.blank? || seconds.nil?

        date = Time.at(seconds).utc
        bucket = granularity == :day ? date.strftime("%Y-%m-%d") : date.strftime("%Y-%m")
        seen[bucket].add(member_id)
      end

    seen.map { |date, members| { date: date, unique_members: members.size } }
      .sort_by { |row| row[:date] }
  end

  def requested_range(granularity)
    if params[:rolling] == "30"
      [(Date.current - 30.days).to_time.to_i * 1000, Time.current.to_i * 1000]
    elsif params[:year].present?
      year = params[:year].to_i
      if granularity == :day && params[:month].present?
        start_date = Date.new(year, params[:month].to_i, 1)
        end_date = start_date.end_of_month
      else
        start_date = Date.new(year, 1, 1)
        end_date = Date.new(year, 12, 31)
      end
      [start_date.to_time.to_i * 1000, end_date.to_time.to_i * 1000 + 86_399_999]
    else
      [Date.new(Date.current.year, 1, 1).to_time.to_i * 1000, Time.current.to_i * 1000]
    end
  end
end
