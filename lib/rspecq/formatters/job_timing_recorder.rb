module RSpecQ
  module Formatters
    # Persists each job's timing (in seconds). Those timings are used when
    # determining the ordering in which jobs are scheduled (slower jobs will
    # be enqueued first).
    class JobTimingRecorder
      def initialize(queue, job)
        @queue = queue
        @job = job
      end

      def dump_summary(summary)
        if @job.include?("+")
          summary.examples.each do |example|
            @queue.record_build_timing(example.id, Float(example.execution_result.run_time))
          end
        else
          @queue.record_build_timing(@job, Float(summary.duration))
        end
      end
    end
  end
end
