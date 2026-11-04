module Service
  # Scheduled work runs in short-lived `rails runner` / rake processes that exit as soon as their script
  # finishes. With the default in-process Active Job queue, anything a job enqueues (deliver_later,
  # perform_later) is only queued on a thread pool, and the process can exit before it has run, so an
  # email or follow-up job is silently dropped. Waiting for the pool to finish before the process ends
  # keeps that work. It does nothing for any other queue adapter, and gives up after `timeout` seconds so
  # a stuck job cannot hold a process (or a dyno shutting down) forever.
  module JobDrain
    DEFAULT_TIMEOUT = 25

    def self.wait!(timeout: DEFAULT_TIMEOUT)
      adapter = ActiveJob::Base.queue_adapter
      return false unless adapter.is_a?(ActiveJob::QueueAdapters::AsyncAdapter)

      Timeout.timeout(timeout) { adapter.shutdown(wait: true) }
      true
    rescue Timeout::Error
      Rails.logger.warn("[JobDrain] queued jobs still running after #{timeout}s; exiting anyway")
      false
    rescue StandardError => e
      Rails.logger.error("[JobDrain] #{e.class}: #{e.message}")
      false
    end
  end
end
