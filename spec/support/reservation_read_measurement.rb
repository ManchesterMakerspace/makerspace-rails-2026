# Counts real driver commands, including cursor pagination; never stores payloads.
module ReservationReadMeasurement
  class Counter
    attr_reader :commands, :database_ms, :returned_bytes, :returned_documents

    def initialize
      @commands = []
      @database_ms = 0.0
      @returned_bytes = 0
      @returned_documents = 0
    end

    def started(event)
      return unless %w[find aggregate count distinct getMore].include?(event.command_name)

      collection = event.command_name == "getMore" ? event.command["collection"] : event.command[event.command_name]
      @commands << [event.command_name, collection.to_s]
    end

    def succeeded(event)
      return unless %w[find aggregate count distinct getMore].include?(event.command_name)

      @database_ms += event.duration * 1000
      @returned_bytes += event.reply.to_bson.to_s.bytesize
      cursor = event.reply['cursor'] || {}
      @returned_documents += Array(cursor['firstBatch'] || cursor['nextBatch']).length
    end

    def failed(_event); end
  end

  def measure_reservation_reads
    counter = Counter.new
    client = Mongoid.default_client
    client.subscribe(Mongo::Monitoring::COMMAND, counter)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    { result: result, commands: counter.commands, database_ms: counter.database_ms,
      returned_bytes: counter.returned_bytes, returned_documents: counter.returned_documents,
      elapsed_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000 }
  ensure
    client&.unsubscribe(Mongo::Monitoring::COMMAND, counter) if counter
  end
end
