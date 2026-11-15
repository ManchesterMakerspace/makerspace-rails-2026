module Service
  module Analytics
    module Members
      # Compute all dashboard member counters in one pass over the collection.
      # All predicates share one timestamp, so the counters describe the same instant.
      def self.summary_counts(now: Time.now)
        base = query_not_landlord
        timeframe_start = now - 1.month
        now_ms = now.to_i * 1000
        active_status = { "status" => { "$in" => Member::ACTIVE_MEMBERSHIP_STATUSES } }

        facets = {
          "total_members" => count_facet(active_status.merge("expirationTime" => { "$gte" => now_ms })),
          "new_members" => count_facet(active_status.merge("startDate" => { "$gte" => timeframe_start })),
          # Count elapsed expirations regardless of current status. An early
          # revocation retaining a future paid-through date appears only once
          # that date passes, matching the monthly lost-members report.
          "lost_members" => [
            { "$match" => {
              "expirationTime" => { "$gte" => timeframe_start.to_i * 1000, "$lt" => now_ms }
            } },
            { "$count" => "count" }
          ],
          "subscribed_members" => count_facet(active_status.merge(
            "expirationTime" => { "$gte" => now_ms },
            "$or" => [{ "subscription_id" => { "$ne" => nil } }, { "subscription" => true }]
          ))
        }

        result = Member.collection.aggregate([
          { "$match" => base.selector },
          { "$facet" => facets }
        ]).first || {}

        facets.keys.to_h { |key| [key.to_sym, facet_count(result, key)] }
      end

      # merged_at: nil excludes soft-deleted ("ghost"/duplicate) accounts --
      # built with a raw Mongoid::Criteria rather than Member.all, so it
      # doesn't automatically inherit Member's default_scope.
      def self.query_not_landlord(base = Mongoid::Criteria.new(Member))
        base.where(:firstname.ne => "Landlord", :lastname.ne => "Fob", merged_at: nil)
      end

      # All members current and in good standing
      def self.query_total_members(base = query_good_standing_members)
        base.where(:expirationTime.gte => (Time.now.to_i * 1000))
      end

      # Members that are in good standing, do not have an expiration date, and have invoices pending settlement
      def self.query_membership_not_started(base = query_no_expiration)
        base.where({ :id.in => ::Service::Analytics::Invoices.query_settlement_pending.pluck(:member_id).uniq })
      end

      # Members that are in good standing, do not have an expiration date, and have no invoices pending settlement
      def self.query_no_membership(base = query_no_expiration)
        base.where({ :id.nin => ::Service::Analytics::Invoices.query_settlement_pending.pluck(:member_id).uniq })
      end
      
      # Members that do not have an expiration, regardless of whether they are waiting for orientation or haven't purchased anything
      def self.query_no_expiration(base = query_good_standing_members)
        base.in(expirationTime: ["", nil])
      end

      # Members that need to sign a member contract
      def self.query_no_member_contract(base = query_total_members)
        base.where(member_contract_signed_date: nil)
      end

      def self.query_paypal_members(base = query_total_members)
        base.where(subscription: true, :subscription_id => nil)
      end

      def self.query_braintree_members(base = query_total_members) # Controller
        base.where(
          :$or => [
            { :subscription_id.ne => nil },
            {  subscription: true }
          ])
      end

      def self.query_good_standing_members(base = query_not_landlord)
        base.where(:status.in => Member::ACTIVE_MEMBERSHIP_STATUSES)
      end

      # Counts memberships at each month-end boundary with one database round-trip.
      # Member#startDate is a BSON datetime, while expirationTime is Unix time in
      # milliseconds; keep both representations explicit throughout the pipeline.
      def self.active_members_by_month(start_date:, end_date:, base: Mongoid::Criteria.new(Member).where(merged_at: nil), statuses: nil, boundary: :end)
        months = month_boundaries(start_date, end_date, boundary)
        return [] if months.empty?

        overall_match = {
          "startDate" => { "$lte" => months.last[:time] },
          "expirationTime" => { "$gte" => months.first[:milliseconds] }
        }
        overall_match["status"] = { "$in" => statuses } if statuses.present?
        selector = base.selector
        overall_match = { "$and" => [selector, overall_match] } if selector.present?

        facets = months.to_h do |month|
          [month[:key], [
            { "$match" => {
              "startDate" => { "$lte" => month[:time] },
              "expirationTime" => { "$gte" => month[:milliseconds] }
            } },
            { "$count" => "count" }
          ]]
        end

        result = Member.collection.aggregate([
          { "$match" => overall_match },
          { "$facet" => facets }
        ]).first || {}

        months.map do |month|
          { date: month[:date], count: result.fetch(month[:key], []).first&.fetch("count", 0) || 0 }
        end
      end

      # Never generates a month whose start hasn't arrived yet (a wholly
      # future month, e.g. from selecting the current year), and for the
      # current, still-in-progress month, clamps an :end boundary to right
      # now rather than that month's not-yet-reached end_of_month -- otherwise
      # "active as of Sep 30" gets checked on Sep 12, wrongly excluding members
      # who are active today but happen to expire before month-end.
      # Members lost per calendar month, symmetric with New Members per Month
      # (the member_growth endpoint) but keyed off expirationTime
      # instead of startDate. Filters strictly on expirationTime < now (not
      # just "falls within the month"), so a member who hasn't actually
      # expired yet is never counted -- including for the current, still-in-
      # progress month -- since they might still renew before it happens.
      def self.lost_members_by_month(start_date:, end_date: Date.today, base: query_not_landlord)
        effective_end_ms = [end_date.to_date.end_of_month.to_time, Time.now].min.to_i * 1000
        start_ms = start_date.to_date.beginning_of_month.to_time.to_i * 1000
        return [] if start_ms >= effective_end_ms

        pipeline = [
          { "$match" => base.selector.merge(
            "expirationTime" => { "$gte" => start_ms, "$lt" => effective_end_ms }
          ) },
          { "$addFields" => { "expirationDate" => { "$toDate" => "$expirationTime" } } },
          { "$group" => {
            "_id" => { "year" => { "$year" => "$expirationDate" }, "month" => { "$month" => "$expirationDate" } },
            "count" => { "$sum" => 1 }
          } },
          { "$sort" => { "_id.year" => 1, "_id.month" => 1 } }
        ]

        Member.collection.aggregate(pipeline).map do |r|
          { month: format("%04d-%02d", r["_id"]["year"], r["_id"]["month"]), count: r["count"] }
        end
      end

      def self.month_boundaries(start_date, end_date, boundary)
        raise ArgumentError, "boundary must be :start or :end" unless %i[start end].include?(boundary)

        cursor = start_date.to_date.beginning_of_month
        last_month = [end_date.to_date, Date.today].min.beginning_of_month
        boundaries = []
        while cursor <= last_month
          natural_boundary = (boundary == :start ? cursor : cursor.end_of_month).to_time
          boundary_time = [natural_boundary, Time.now].min
          boundaries << {
            key: "month_#{cursor.strftime('%Y_%m')}",
            date: cursor.strftime("%Y-%m"),
            time: boundary_time,
            milliseconds: boundary_time.to_i * 1000
          }
          cursor = cursor.next_month
        end
        boundaries
      end

      def self.count_facet(match)
        [{ "$match" => match }, { "$count" => "count" }]
      end

      def self.facet_count(result, key)
        result.fetch(key, []).first&.fetch("count", 0) || 0
      end
      private_class_method :month_boundaries
      private_class_method :count_facet, :facet_count
    end

    module Rentals
      def self.query_no_rental_contract(base = query_total_rentals) # Member review
        base.where(contract_on_file: false)
      end

      def self.query_total_rentals(base = Mongoid::Criteria.new(Rental))
        base.where(:expiration.gte => (Time.now.to_i * 1000), :member_id.in => ::Service::Analytics::Members.query_good_standing_members.pluck(:id))
      end
    end

    module Invoices
      def self.summary_counts
        result = Invoice.collection.aggregate([
          { "$facet" => {
            "past_due_invoices" => [
              { "$match" => query_past_due_conditions },
              { "$lookup" => {
                "from" => Member.collection.name,
                "localField" => "member_id",
                "foreignField" => "_id",
                "as" => "member"
              } },
              { "$match" => {
                "member" => { "$elemMatch" => {
                  "firstname" => { "$ne" => "Landlord" },
                  "lastname" => { "$ne" => "Fob" },
                  "status" => { "$in" => Member::ACTIVE_MEMBERSHIP_STATUSES },
                  "expirationTime" => { "$gte" => Time.now.to_i * 1000 }
                } }
              } },
              { "$count" => "count" }
            ],
            "refunds_pending" => [
              { "$match" => query_refunds_pending.selector },
              { "$count" => "count" }
            ]
          } }
        ]).first || {}

        %w[past_due_invoices refunds_pending].to_h do |key|
          [key.to_sym, result.fetch(key, []).first&.fetch("count", 0) || 0]
        end
      end

      def self.query_past_due_conditions
        { "due_date" => { "$lt" => Time.now }, "settled_at" => nil, "transaction_id" => nil }
      end
      private_class_method :query_past_due_conditions

      def self.query_created(timeframe = 1.month, base = Mongoid::Criteria.new(Invoice)) #Invoice review
        base.where(:created_at.gt => Time.now - timeframe)
      end

      def self.query_earned(timeframe = 1.month, base = Mongoid::Criteria.new(Invoice)) #invoice review
        base.where(:settled_at.gt => Time.now - timeframe)
      end

      def self.query_past_due(base = Mongoid::Criteria.new(Invoice)) #invoice review and controller
        base.where(:due_date.lt => Time.now, settled_at: nil, transaction_id: nil, :member_id.in => ::Service::Analytics::Members.query_total_members.pluck(:id))
      end

      def self.query_refunds_pending(base = Mongoid::Criteria.new(Invoice)) #invoice review and controller
        base.where(refunded: false, :refund_requested.ne => nil)
      end

      def self.query_settlement_pending(base = Mongoid::Criteria.new(Invoice)) # invoice review
        base.where(settled_at: nil, :transaction_id.ne => nil)
      end
    end
  end
end
