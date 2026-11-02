# Daily reminder to staff about rentals that should be handed back but have not been verified:
# rentals still vacating after their end date, and rentals the member says they have vacated
# (awaiting_verification). It never changes a rental. Releasing a spot stays a human step, so a
# rental cannot be released unseen: staff check the space is empty and click Verify Vacated (or
# Mark Vacated for a vacating rental). Nothing is posted when nothing is waiting.
class RentalVacatingCheckJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current
    overdue = Rental.where(status: 'vacating', :expiration.lte => now.to_i * 1000).to_a
    waiting = Rental.where(status: 'awaiting_verification').to_a

    if overdue.any? || waiting.any?
      ::Service::SlackConnector.send_slack_message(message(overdue, waiting, now),
                                                   ::Service::SlackConnector.members_relations_channel)
    end
    SystemConfig.record_run('rental_vacating_check', success: true)
  rescue => e
    SystemConfig.record_run('rental_vacating_check', success: false)
    Service::ErrorReporter.notify('RentalVacatingCheckJob failed', context: { error: e.message })
    raise
  end

  private

  def message(overdue, waiting, now)
    lines = ["Rentals waiting on staff (#{overdue.size + waiting.size})"]
    if waiting.any?
      lines << ''
      lines << 'Member says they have vacated, awaiting verification:'
      waiting.sort_by { |rental| rental.vacated_reported_at || now }.each do |rental|
        lines << "• #{label(rental)} (#{waiting_for(rental, now)})"
      end
    end
    if overdue.any?
      lines << ''
      lines << 'Vacating, past the end date:'
      overdue.sort_by(&:expiration).each do |rental|
        ended = Time.at(rental.expiration / 1000).in_time_zone.to_date
        lines << "• #{label(rental)} (ended #{ended.strftime('%B %-d, %Y')}, #{(now.to_date - ended).to_i} days ago)"
      end
    end
    lines << ''
    lines << 'Check the space is empty, then click *Verify Vacated* (or *Mark Vacated*) on the member\'s Rentals tab.'
    lines.join("\n")
  end

  def label(rental)
    "#{rental.number} - #{rental.member&.fullname || 'unknown member'}"
  end

  def waiting_for(rental, now)
    return 'waiting since before this reminder existed' unless rental.vacated_reported_at

    days = ((now - rental.vacated_reported_at) / 1.day).floor
    days < 1 ? 'reported today' : "waiting #{days} #{'day'.pluralize(days)}"
  end
end
