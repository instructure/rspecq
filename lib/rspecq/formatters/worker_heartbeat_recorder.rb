module RSpecQ
  module Formatters
    # Updates the respective heartbeat key of the worker after each example.
    #
    # Refer to the documentation of the worker_liveness_sec configuration option for more info.
    class WorkerHeartbeatRecorder
      def initialize(worker)
        @worker = worker
      end

      def example_finished(*)
        @worker.update_heartbeat
      end
    end
  end
end
