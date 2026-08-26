require "optparse"

module RSpecQ
  class Parser
    DEFAULT_REDIS_HOST = "127.0.0.1".freeze
    DEFAULT_REPORT_TIMEOUT = 3600 # 1 hour
    DEFAULT_MAX_REQUEUES = 3
    DEFAULT_QUEUE_WAIT_TIMEOUT = 30
    DEFAULT_FAIL_FAST = 0
    DEFAULT_WORKER_LIVENESS_SEC = 60
    DEFAULT_REDIS_CONNECT_TIMEOUT = 1.0
    DEFAULT_REDIS_READ_TIMEOUT = 5.0
    DEFAULT_REDIS_WRITE_TIMEOUT = 5.0
    # Comma-separated backoff (seconds) before each reconnect attempt. An empty
    # value disables reconnects. See Configuration for how this is parsed.
    DEFAULT_REDIS_RECONNECT_ATTEMPTS = "0.05,0.1,0.25,0.5,1.0".freeze

    def self.parse!(args)
      new(args).parse!
    end

    attr_reader :args, :opts

    def initialize(args)
      @args = args
      @opts = {}
    end

    # This method mutates `args` in order to allow both rspecq and
    # rspec options to be passed to rspecq. ["--build", "foo",
    # "--", "--pattern", "bar"] will set `build: "foo"` for rspecq
    # options and leave ["--pattern", "bar"] to be passed to rspec
    def parse!
      parse_args!
      parse_env

      # rubocop:disable Style/RaiseArgs, Layout/EmptyLineAfterGuardClause
      raise OptionParser::MissingArgument.new(:build) if opts[:build].nil?
      raise OptionParser::MissingArgument.new(:worker) if !opts[:report] && opts[:worker].nil?
      # rubocop:enable Style/RaiseArgs, Layout/EmptyLineAfterGuardClause

      opts
    end

    private

    def parse_args!
      OptionParser.new do |o|
        name = File.basename($PROGRAM_NAME)

        o.banner = <<~BANNER
          NAME:
              #{name} - Optimally distribute and run RSpec suites among parallel workers

          USAGE:
              #{name} [<options>] [spec files or directories]
        BANNER

        o.separator ""
        o.separator "OPTIONS:"

        o.on("-b", "--build ID", "A unique identifier for the build. Should be " \
                                 "common among workers participating in the same build.") do |v|
          opts[:build] = v
        end

        o.on("-w", "--worker ID", "An identifier for the worker. Workers " \
                                  "participating in the same build should have distinct IDs.") do |v|
          opts[:worker] = v
        end

        o.on("--seed SEED", "The RSpec seed. Passing the seed can be helpful in " \
                            "many ways i.e reproduction and testing.") do |v|
          opts[:seed] = v
        end

        o.on("-r", "--redis HOST", "Redis host to connect to " \
                                   "(default: #{DEFAULT_REDIS_HOST}).") do |v|
          puts "--redis is deprecated. Use --redis-host or --redis-url instead"
          opts[:redis_host] = v
        end

        o.on("--redis-host HOST", "Redis host to connect to " \
                                  "(default: #{DEFAULT_REDIS_HOST}).") do |v|
          opts[:redis_host] = v
        end

        o.on("--redis-url URL", "The URL of the Redis host to connect to " \
                                "(e.g.: redis://127.0.0.1:6379/0).") do |v|
          opts[:redis_url] = v
        end

        o.on("--redis-connect-timeout N", Float, "Seconds to wait when establishing " \
                                                 "a Redis connection (default: #{DEFAULT_REDIS_CONNECT_TIMEOUT}).") do |v|
          opts[:redis_connect_timeout] = v
        end

        o.on("--redis-read-timeout N", Float, "Seconds to wait for a Redis read " \
                                              "(default: #{DEFAULT_REDIS_READ_TIMEOUT}).") do |v|
          opts[:redis_read_timeout] = v
        end

        o.on("--redis-write-timeout N", Float, "Seconds to wait for a Redis write " \
                                               "(default: #{DEFAULT_REDIS_WRITE_TIMEOUT}).") do |v|
          opts[:redis_write_timeout] = v
        end

        o.on("--redis-reconnect-attempts LIST", "Comma-separated backoff (seconds) " \
                                                "before each Redis reconnect attempt, e.g. " \
                                                "\"#{DEFAULT_REDIS_RECONNECT_ATTEMPTS}\". " \
                                                "Empty disables reconnects.") do |v|
          opts[:redis_reconnect_attempts] = v
        end

        o.on("--update-timings", "Update the global job timings key with the " \
                                 "timings of this build. Note: This key is used as the basis for job " \
                                 "scheduling.") do |v|
          opts[:timings] = v
        end

        o.on("--timings-key KEY", "Promote timings to KEY instead of the default " \
                                  "global timings key (requires --update-timings).") do |v|
          opts[:timings_key] = v
        end

        o.on("--file-split-threshold N", Integer, "Split spec files slower than N " \
                                                  "seconds and schedule them as individual examples.") do |v|
          opts[:file_split_threshold] = v
        end

        o.on("--chunk-target-duration N", Integer, "Target duration in seconds for " \
                                                   "time-balanced example chunks when splitting slow files " \
                                                   "(default: 30). Groups examples into chunks of approximately " \
                                                   "this duration to reduce Kernel.load overhead.") do |v|
          opts[:chunk_target_duration] = v
        end

        o.on("--report", "Enable reporter mode: do not pull tests off the queue; " \
                         "instead print build progress and exit when it's " \
                         "finished.\n#{o.summary_indent * 9} " \
                         "Exits with a non-zero status code if there were any " \
                         "failures.") do |v|
          opts[:report] = v
        end

        o.on("--report-timeout N", Integer, "Fail if build is not finished after " \
                                            "N seconds. Only applicable if --report is enabled " \
                                            "(default: #{DEFAULT_REPORT_TIMEOUT}).") do |v|
          opts[:report_timeout] = v
        end

        o.on("--max-requeues N", Integer, "Retry failed examples up to N times " \
                                          "before considering them legit failures " \
                                          "(default: #{DEFAULT_MAX_REQUEUES}).") do |v|
          opts[:max_requeues] = v
        end

        o.on("--queue-wait-timeout N", Integer, "Time to wait for a queue to be " \
                                                "ready before considering it failed " \
                                                "(default: #{DEFAULT_QUEUE_WAIT_TIMEOUT}).") do |v|
          opts[:queue_wait_timeout] = v
        end

        o.on("--fail-fast N", Integer, "Abort build with a non-zero status code " \
                                       "after N failed examples.") do |v|
          opts[:fail_fast] = v
        end

        o.on("--reproduction", "Enable reproduction mode: run rspec on the given files " \
                               "and examples in the exact order they are given. Incompatible with " \
                               "--timings.") do |v|
          opts[:reproduction] = v
        end

        o.on("--tag TAG", "Run examples with the specified tag, or exclude examples " \
                          "by prefixing the tag with ~ (e.g. ~slow). Repeatable. " \
                          "TAG is passed through to rspec.") do |tag|
          (opts[:tags] ||= []) << tag
        end

        o.on("--junit-output filepath", String, "Output junit formatted xml " \
                                                "for CI suites to the defined file path. Substitution parameters " \
                                                "{{TEST_ENV_NUMBER}} - parallel gem proc number. " \
                                                "{{JOB_INDEX}} - increments with each suite that is run.") do |v|
          opts[:junit_output] = v
        end

        o.on("--include-pattern PATTERN", "Run tests matching the regex") do |v|
          opts[:include_pattern] = /#{v}/
        end

        o.on("--exclude-pattern PATTERN", "Regex of tests to exclude from run.") do |v|
          opts[:exclude_pattern] = /#{v}/
        end

        o.on("--worker-liveness-sec N", Integer, "Seconds before a worker is considered dead " \
                                                 "(default: #{DEFAULT_WORKER_LIVENESS_SEC})") do |v|
          opts[:worker_liveness_sec] = v
        end

        o.on_tail("-h", "--help", "Show this message.") do
          puts o
          exit
        end

        o.on_tail("-v", "--version", "Print the version and exit.") do
          puts "#{name} #{RSpecQ::VERSION}"
          exit
        end
      end.parse!(args)
    end

    def parse_env
      opts[:build] ||= ENV["RSPECQ_BUILD"]
      opts[:worker] ||= ENV["RSPECQ_WORKER"]
      opts[:seed] ||= ENV["RSPECQ_SEED"]
      opts[:redis_host] ||= ENV["RSPECQ_REDIS"] || DEFAULT_REDIS_HOST
      opts[:timings] = opts.fetch(:timings, env_set?("RSPECQ_UPDATE_TIMINGS"))
      opts[:timings_key] ||= ENV.fetch("RSPECQ_TIMINGS_KEY", nil)
      opts[:file_split_threshold] ||= Integer(ENV["RSPECQ_FILE_SPLIT_THRESHOLD"] || 9_999_999)
      opts[:report] = opts.fetch(:report, env_set?("RSPECQ_REPORT"))
      opts[:report_timeout] ||= Integer(ENV["RSPECQ_REPORT_TIMEOUT"] || DEFAULT_REPORT_TIMEOUT)
      opts[:max_requeues] ||= Integer(ENV["RSPECQ_MAX_REQUEUES"] || DEFAULT_MAX_REQUEUES)
      opts[:queue_wait_timeout] ||= Integer(ENV["RSPECQ_QUEUE_WAIT_TIMEOUT"] || DEFAULT_QUEUE_WAIT_TIMEOUT)
      opts[:redis_url] ||= ENV["RSPECQ_REDIS_URL"]
      opts[:redis_connect_timeout] ||= env_float("RSPECQ_REDIS_CONNECT_TIMEOUT", DEFAULT_REDIS_CONNECT_TIMEOUT)
      opts[:redis_read_timeout] ||= env_float("RSPECQ_REDIS_READ_TIMEOUT", DEFAULT_REDIS_READ_TIMEOUT)
      opts[:redis_write_timeout] ||= env_float("RSPECQ_REDIS_WRITE_TIMEOUT", DEFAULT_REDIS_WRITE_TIMEOUT)
      opts[:redis_reconnect_attempts] ||= ENV["RSPECQ_REDIS_RECONNECT_ATTEMPTS"] || DEFAULT_REDIS_RECONNECT_ATTEMPTS
      opts[:fail_fast] ||= Integer(ENV["RSPECQ_FAIL_FAST"] || DEFAULT_FAIL_FAST)
      opts[:reproduction] ||= env_set?("RSPECQ_REPRODUCTION")
      opts[:tags] ||= []
      opts[:junit_output] ||= ENV["RSPECQ_JUNIT_OUTPUT"]
      opts[:include_pattern] ||= ENV["INCLUDE_PATTERN"]
      opts[:exclude_pattern] ||= ENV["EXCLUDE_PATTERN"]
      opts[:worker_liveness_sec] ||= Integer(ENV["RSPECQ_WORKER_LIVENESS_SEC"] || DEFAULT_WORKER_LIVENESS_SEC)
      opts[:chunk_target_duration] ||= Integer(ENV["RSPECQ_CHUNK_TARGET_DURATION"] || 30)
    end

    def env_set?(var)
      ["1", "true"].include?(ENV[var])
    end

    # A Float from `var`, treating a blank value (unset or empty/whitespace) as
    # absent and falling back to `default`. Jenkins string parameters commonly
    # default to "", which would otherwise crash Float("").
    def env_float(var, default)
      value = ENV[var]
      value.nil? || value.strip.empty? ? default : Float(value)
    end
  end
end
