module RSpecQ
  # Use the RSpec parser to parse any command line args intended
  # for rspec such as `-- --format JUnit -o foo.xml` so that we can
  # pass these args to rspec while removing the
  # files_or_dirs_to_run since we want to pull those from the
  # queue. The RSpecQ::Parser will mutate args, removing any rspecq
  # args so that RSpec::Core::Parser only sees the args intended
  # for rspec.
  Configuration = Struct.new(
    :build,
    :chunk_target_duration,
    :exclude_pattern,
    :fail_fast,
    :files_or_dirs_to_run,
    :file_split_threshold,
    :include_pattern,
    :junit_output,
    :max_requeues,
    :queue_wait_timeout,
    :redis_host,
    :redis_url,
    :redis_opts,
    :report,
    :report_timeout,
    :reproduction,
    :rspec_args,
    :seed,
    :timings,
    :worker,
    :worker_liveness_sec,
    keyword_init: true
  ) do
    def initialize(args)
      super(**RSpecQ::Parser.parse!(args))

      self.files_or_dirs_to_run = RSpec::Core::Parser.new(args).parse[:files_or_directories_to_run]
      l = files_or_dirs_to_run.length
      if l.zero?
        self.files_or_dirs_to_run = nil
        self.rspec_args = args
      else
        self.rspec_args = args[0...-l]
      end

      if include_pattern || exclude_pattern
        self.files_or_dirs_to_run = filter_tests(files_or_dirs_to_run, self)
      end

      self.redis_opts = if redis_url
                          { url: redis_url }
                        else
                          { host: redis_host }
                        end

      # The queue lives on a Redis instance that is shared across all CI
      # builds. Redis is single-threaded, so a long O(N) command from another
      # build (or an idle-connection reap / failover on the shared node) can
      # briefly stall or drop our connection. redis-client's defaults
      # (1.0s timeouts, reconnect_attempts: 0) turn any such blip into a fatal
      # CannotConnectError. Use more forgiving timeouts and retry the dropped-
      # connection case with backoff so a transient hiccup is a non-event.
      self.redis_opts = redis_opts.merge(
        connect_timeout: 1.0,
        read_timeout: 5.0,
        write_timeout: 5.0,
        reconnect_attempts: [0.05, 0.1, 0.25, 0.5, 1.0]
      )
    end

    def report?
      !!report
    end

    def filter_tests(tests, options = {})
      suffix_pattern = /_spec\.rb$/
      include_pattern = options[:include_pattern] || //
      exclude_pattern = options[:exclude_pattern]
      pattern = "**{,/*/**}/*"

      (tests || []).flat_map do |file_or_folder|
        if File.directory?(file_or_folder)
          files = Dir[File.join(file_or_folder, pattern)].uniq.sort
          files = files.grep(suffix_pattern).grep(include_pattern)
          files -= files.grep(exclude_pattern) if exclude_pattern
          files
        else
          file_or_folder
        end
      end.uniq
    end
  end
end
