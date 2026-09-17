require "redis"

module RSpecQ
  # Queue is the data store interface (Redis) and is used to manage the work
  # queue for a particular build. All Redis operations happen via Queue.
  #
  # A queue typically contains all the data needed for a particular build to
  # happen. These include (but are not limited to) the following:
  #
  # - the list of jobs (spec files and/or examples) to be executed
  # - the failed examples along with their backtrace
  # - the set of running jobs
  # - previous job timing statistics used to optimally schedule the jobs
  # - the set of executed jobs
  class Queue
    RESERVE_JOB = <<~LUA.freeze
      local queue = KEYS[1]
      local queue_running = KEYS[2]
      local worker_id = ARGV[1]

      local job = redis.call('lpop', queue)
      if job then
        redis.call('hset', queue_running, worker_id, job)
        return job
      else
        return nil
      end
    LUA

    # Scans for dead workers and puts their reserved jobs back to the queue.
    REQUEUE_LOST_JOB = <<~LUA.freeze
      local worker_heartbeats = KEYS[1]
      local queue_running = KEYS[2]
      local queue_unprocessed = KEYS[3]
      local queue_lost = KEYS[4]
      local time_now = ARGV[1]
      local timeout = ARGV[2]

      local dead_workers = redis.call('zrangebyscore', worker_heartbeats, 0, time_now - timeout)
      for _, worker in ipairs(dead_workers) do
        local job = redis.call('hget', queue_running, worker)
        if job then
          redis.call('lpush', queue_unprocessed, job)
          redis.call('hdel', queue_running, worker)
          redis.call('zincrby', queue_lost, 1, job)

          return {job, worker}
        end
      end

      return nil
    LUA

    REQUEUE_JOB = <<~LUA.freeze
      local key_queue_unprocessed = KEYS[1]
      local key_requeues = KEYS[2]
      local key_requeued_job_original_worker = KEYS[3]
      local key_job_location = KEYS[4]
      local job = ARGV[1]
      local max_requeues = ARGV[2]
      local original_worker = ARGV[3]
      local location = ARGV[4]

      local requeued_times = redis.call('hget', key_requeues, job)
      if requeued_times and tonumber(requeued_times) >= tonumber(max_requeues) then
        return nil
      end

      redis.call('lpush', key_queue_unprocessed, job)
      redis.call('hset', key_requeued_job_original_worker, job, original_worker)
      redis.call('hincrby', key_requeues, job, 1)
      redis.call('hset', key_job_location, job, location)

      return true
    LUA

    STATUS_INITIALIZING = "initializing".freeze
    STATUS_READY = "ready".freeze
    STATUS_SUCCESS = "success".freeze
    STATUS_FAILURE = "failure".freeze

    # Per-build timings are only needed until the reporter promotes them to the
    # global key; expire them so always-on recording can't grow Redis unbounded.
    # Interim measure until comprehensive key TTLs land (DE-1805).
    BUILD_TIMINGS_TTL_SEC = 86_400

    attr_reader :redis

    def initialize(build_id, worker_id, redis_opts, worker_liveness_sec)
      @build_id = build_id
      @worker_id = worker_id
      @redis = Redis.new(redis_opts.merge(id: worker_id))
      @worker_liveness_sec = worker_liveness_sec
    end

    # The build's final status once finished: STATUS_SUCCESS or STATUS_FAILURE
    # (or the lifecycle STATUS_INITIALIZING / STATUS_READY before then).
    def status
      @redis.get(key_queue_status)
    end

    # NOTE: jobs will be processed from head to tail (lpop)
    def publish(jobs, fail_fast = 0)
      time = current_time
      @redis.multi do |pipeline|
        pipeline.hset(key_queue_config, "fail_fast", fail_fast)
        pipeline.rpush(key_queue_unprocessed, jobs)
        pipeline.setnx(key_queue_ready_at, time)
        pipeline.set(key_queue_status, STATUS_READY)
      end

      jobs.size
    end

    # Records when a master worker was elected (start of the whole build).
    def mark_elected_master_at
      @redis.set(key_elected_master_at, current_time)
    end

    TRY_MARK_FINISHED = <<~LUA.freeze
      local key_queue_finished_at = KEYS[1]
      local key_queue_status = KEYS[2]
      local key_failures = KEYS[3]
      local key_errors = KEYS[4]
      local key_queue_unprocessed = KEYS[5]
      local key_queue_running = KEYS[6]
      local key_queue_config = KEYS[7]
      local status_success = ARGV[1]
      local status_failure = ARGV[2]

      local unprocessed_count = redis.call('llen', key_queue_unprocessed)
      local running_count = redis.call('hlen', key_queue_running)
      local failures_count = redis.call('hlen', key_failures)
      local errors_count = redis.call('hlen', key_errors)
      local fail_fast = tonumber(redis.call('hget', key_queue_config, 'fail_fast'))

      local is_fail_fast = fail_fast and fail_fast > 0 and failures_count + errors_count >= fail_fast
      local is_exhausted = unprocessed_count + running_count == 0

      if not is_fail_fast and not is_exhausted then
        return nil
      end

      local current_time = redis.call('time')[1]

      -- setnx acts as the lock: only the first caller marks the build finished
      local locked = redis.call('setnx', key_queue_finished_at, current_time)
      if locked == 0 then
        return nil
      end

      if is_fail_fast then
        redis.call('set', key_queue_status, status_failure)
      elseif failures_count + errors_count == 0 then
        redis.call('set', key_queue_status, status_success)
      else
        redis.call('set', key_queue_status, status_failure)
      end

      return true
    LUA

    # Marks the build finished (setnx lock, first caller wins) and stores the
    # final status (success/failure). Defensively re-checks the build is over.
    def try_mark_finished
      eval_script(
        TRY_MARK_FINISHED,
        keys: [
          key_queue_finished_at,
          key_queue_status,
          key_failures,
          key_errors,
          key_queue_unprocessed,
          key_queue_running,
          key_queue_config
        ],
        argv: [STATUS_SUCCESS, STATUS_FAILURE]
      )
    end

    # [seconds from master election, seconds from queue ready] to finish, or
    # nil if the build has not both started and finished.
    def took_times_secs
      elected_master_at = @redis.get(key_elected_master_at)
      ready_at = @redis.get(key_queue_ready_at)
      finished_at = @redis.get(key_queue_finished_at)

      return nil if elected_master_at.nil? || ready_at.nil? || finished_at.nil?

      [
        finished_at.to_i - elected_master_at.to_i,
        finished_at.to_i - ready_at.to_i
      ]
    end

    def reserve_job
      eval_script(
        RESERVE_JOB,
        keys: [
          key_queue_unprocessed,
          key_queue_running,
        ],
        argv: [@worker_id]
      )
    end

    # If this worker has a job in the running hash (from a previous crash),
    # put it back on the queue. This must be called before update_heartbeat
    # or reserve_job when a worker restarts with the same worker_id.
    def recover_own_job
      job = @redis.hget(key_queue_running, @worker_id)
      return nil unless job

      @redis.multi do |pipeline|
        pipeline.lpush(key_queue_unprocessed, job)
        pipeline.hdel(key_queue_running, @worker_id)
      end
      job
    end

    def requeue_lost_job
      eval_script(
        REQUEUE_LOST_JOB,
        keys: [
          key_worker_heartbeats,
          key_queue_running,
          key_queue_unprocessed,
          key_queue_lost
        ],
        argv: [
          current_time,
          @worker_liveness_sec
        ]
      )
    end

    # Number of unique jobs that were lost and requeued (e.g. by abnormal
    # worker termination). A job could be lost more than once (unlikely).
    def lost_jobs_count
      @redis.zcard(key_queue_lost)
    end

    # NOTE: The same job might happen to be acknowledged more than once, in
    # the case of requeues.
    def acknowledge_job(job)
      @redis.multi do |pipeline|
        pipeline.hdel(key_queue_running, @worker_id)
        pipeline.sadd(key_queue_processed, job)
        pipeline.rpush(key("queue", "jobs_per_worker", @worker_id), job)
      end
    end

    # Put job at the head of the queue to be re-processed right after, by
    # another worker. This is a mitigation measure against flaky tests.
    #
    # Returns nil if the job hit the requeue limit and therefore was not
    # requeued and should be considered a failure.
    def requeue_job(example, max_requeues, original_worker_id)
      return false if max_requeues.zero?

      job = example.id
      location = example.location_rerun_argument

      eval_script(
        REQUEUE_JOB,
        keys: [key_queue_unprocessed, key_requeues, key("requeued_job_original_worker"), key("job_location")],
        argv: [job, max_requeues, original_worker_id, location]
      )
    end

    def save_worker_seed(worker, seed)
      @redis.hset(key("worker_seed"), worker, seed)
    end

    def job_location(job)
      @redis.hget(key("job_location"), job)
    end

    def is_requeue(job)
      @redis.hget(key_requeues, job)
    end

    def failed_job_worker(job)
      redis.hget(key("requeued_job_original_worker"), job)
    end

    def job_rerun_command(job)
      worker = failed_job_worker(job)
      jobs = redis.lrange(key("queue", "jobs_per_worker", worker), 0, -1)
      # Get the job index or (||) the file index incase we queued the entire file
      # or get all the worker jobs incase something has gone VERY wrong
      job_index = jobs.find_index(job) || jobs.find_index(job.split("[")[0]) || -1
      seed = redis.hget(key("worker_seed"), worker)

      "DISABLE_SPRING=1 DISABLE_BOOTSNAP=1 bin/rspecq --build 1 " \
        "--worker foo --seed #{seed} --max-requeues 0 --fail-fast 1 " \
        "--reproduction #{jobs[0..job_index].join(' ')}"
    end

    def record_example_failure(example_id, message)
      @redis.hset(key_failures, example_id, message)
    end

    def record_flaky_failure(example_id, message)
      @redis.hset(key_flaky_failures, example_id, message)
    end

    # For errors occured outside of examples (e.g. while loading a spec file)
    def record_non_example_error(job, message)
      @redis.hset(key_errors, job, message)
    end

    # Records a job's timing into the per-build timings key (promoted to the
    # global key by the reporter when --update-timings is set). Also accumulates
    # total worker execution time for the build.
    def record_build_timing(job, duration)
      @redis.pipelined do |pipeline|
        pipeline.zadd(key_build_timings, duration, job)
        pipeline.incrby(key_build_execution_time_ms, (duration * 1000).to_i)
        pipeline.expire(key_build_timings, BUILD_TIMINGS_TTL_SEC)
        pipeline.expire(key_build_execution_time_ms, BUILD_TIMINGS_TTL_SEC)
      end
    end

    # This build's recorded duration for a single job (seconds), or nil.
    def job_build_timing(job)
      @redis.zscore(key_build_timings, job)
    end

    # Total worker execution time (sum of all job durations) for this build.
    def total_execution_time_ms
      Integer(@redis.get(key_build_execution_time_ms) || 0)
    end

    # Promotes this build's timings to the global (or a caller-specified) key.
    # PERSIST clears the TTL that COPY inherits from the build-scoped source
    # key; the global timings key is the durable scheduling basis and must not
    # expire between --update-timings builds.
    def update_global_timings(dst = key_timings)
      @redis.copy(key_build_timings, dst, replace: true)
      @redis.persist(dst)
    end

    def record_build_time(duration)
      @redis.multi do |pipeline|
        pipeline.lpush(key_build_times, Float(duration))
        pipeline.ltrim(key_build_times, 0, 99)
        pipeline.set(key_build_time, Integer(duration * 1000))
      end
    end

    def record_worker_heartbeat
      @redis.zadd(key_worker_heartbeats, current_time, @worker_id)
    end

    def increment_example_count(n)
      @redis.incrby(key_example_count, n)
    end

    def example_count
      @redis.get(key_example_count).to_i
    end

    def processed_jobs_count
      @redis.scard(key_queue_processed)
    end

    def processed_jobs
      @redis.smembers(key_queue_processed)
    end

    def requeued_jobs
      @redis.hgetall(key_requeues).transform_values(&:to_i)
    end

    def become_master
      @redis.setnx(key_queue_status, STATUS_INITIALIZING)
    end

    # Global timings for scheduling, ordered by execution time desc. Whole-file
    # timings are reconstructed from any per-example ("file[...]") entries so the
    # scheduler can still recognize a split file as slow and re-split it.
    def global_timings
      redis_timings = @redis.zrevrange(key_timings, 0, -1, withscores: true).to_h

      whole_file_timings = populate_splitted_file_timings(redis_timings)
      return redis_timings if whole_file_timings.empty?

      # Real (stored) timings win over reconstructed sums, so a genuine
      # whole-file run is not overridden by a partial (e.g. requeue) sum.
      whole_file_timings.merge!(redis_timings)
      whole_file_timings.sort_by { |_j, d| -d }.to_h
    end

    def example_failures
      @redis.hgetall(key_failures)
    end

    def flaky_failures
      @redis.hgetall(key_flaky_failures)
    end

    def non_example_errors
      @redis.hgetall(key_errors)
    end

    # True if the build is complete, false otherwise
    def exhausted?
      return false if !published?

      @redis.multi do |pipeline|
        pipeline.llen(key_queue_unprocessed)
        pipeline.hlen(key_queue_running)
      end.sum.zero?
    end

    def published?
      [STATUS_READY, STATUS_SUCCESS, STATUS_FAILURE].include?(@redis.get(key_queue_status))
    end

    def wait_until_published(timeout = 30)
      (timeout * 10).times do
        return if published?

        sleep 0.1
      end

      raise "Queue not yet published after #{timeout} seconds"
    end

    def build_successful?
      exhausted? && example_failures.empty? && non_example_errors.empty?
    end

    # The remaining jobs to be processed. Jobs at the head of the list will
    # be procesed first.
    def unprocessed_jobs
      @redis.lrange(key_queue_unprocessed, 0, -1)
    end

    # Returns the jobs considered flaky (i.e. initially failed but passed
    # after being retried). Must be called after the build is complete,
    # otherwise an exception will be raised.
    def flaky_jobs
      if !exhausted? && !build_failed_fast?
        raise "Queue is not yet exhausted"
      end

      requeued = @redis.hkeys(key_requeues)

      return [] if requeued.empty?

      requeued - @redis.hkeys(key_failures)
    end

    # Returns the number of failures that will trigger the build to fail-fast.
    # Returns 0 if this feature is disabled and nil if the Queue is not yet
    # published
    def fail_fast
      return nil unless published?

      @fail_fast ||= Integer(@redis.hget(key_queue_config, "fail_fast"))
    end

    # Returns true if the number of failed tests, has surpassed the threshold
    # to render the run unsuccessful and the build should be terminated.
    def build_failed_fast?
      if fail_fast.nil? || fail_fast.zero?
        return false
      end

      @redis.multi do |pipeline|
        pipeline.hlen(key_failures)
        pipeline.hlen(key_errors)
      end.sum >= fail_fast
    end

    # redis: STRING [STATUS_INITIALIZING, STATUS_READY, STATUS_SUCCESS, STATUS_FAILURE]
    def key_queue_status
      key("queue", "status")
    end

    # redis:  HASH<config_key => config_value>
    def key_queue_config
      key("queue", "config")
    end

    # redis: LIST<job>
    def key_queue_unprocessed
      key("queue", "unprocessed")
    end

    # redis: HASH<worker_id => job>
    def key_queue_running
      key("queue", "running")
    end

    # redis: SET<job>
    def key_queue_processed
      key("queue", "processed")
    end

    # redis: STRING<timestamp> — when a master worker was elected.
    def key_elected_master_at
      key("queue", "elected_master_at")
    end

    # redis: STRING<timestamp> — when the queue was published (ready).
    def key_queue_ready_at
      key("queue", "ready_at")
    end

    # redis: STRING<timestamp> — when the build finished (first worker to see
    # the queue exhausted, or fail-fast).
    def key_queue_finished_at
      key("queue", "finished_at")
    end

    # redis: ZSET<job => times_lost>
    def key_queue_lost
      key("queue", "lost")
    end

    # Contains regular RSpec example failures.
    #
    # redis: HASH<example_id => error message>
    def key_failures
      key("example_failures")
    end

    # Contains flaky RSpec example failures.
    #
    # redis: HASH<example_id => error message>
    def key_flaky_failures
      key("flaky_failures")
    end

    # Contains errors raised outside of RSpec examples
    # (e.g. a syntax error in spec_helper.rb).
    #
    # redis: HASH<job => error message>
    def key_errors
      key("errors")
    end

    # As a mitigation mechanism for flaky tests, we requeue example failures
    # to be retried by another worker, up to a certain number of times.
    #
    # redis: HASH<job => times_retried>
    def key_requeues
      key("requeues")
    end

    # The total number of examples, those that were requeued.
    #
    # redis: STRING<integer>
    def key_example_count
      key("example_count")
    end

    # redis: ZSET<worker_id => timestamp>
    #
    # Timestamp of the last example processed by each worker.
    def key_worker_heartbeats
      key("worker_heartbeats")
    end

    # redis: ZSET<job => duration>
    #
    # NOTE: This key is not scoped to a build (i.e. shared among all builds),
    # so be careful to only publish timings from a single branch (e.g. master).
    # Otherwise, timings won't be accurate.
    def key_timings
      "timings"
    end

    # redis: ZSET<job => duration>, scoped to this build. Promoted to the global
    # key_timings by the reporter when --update-timings is set.
    def key_build_timings
      key("timings")
    end

    # redis: STRING<ms> — total worker execution time for this build.
    def key_build_execution_time_ms
      key("build_execution_time_ms")
    end

    # redis: LIST<duration>
    #
    # Last build is at the head of the list.
    def key_build_times
      "build_times"
    end

    def key_build_time
      key("build_time")
    end

    private

    # Plain EVAL (not evalsha): canvas fronts Redis with a Twemproxy
    # compatibility guard that forbids SCRIPT LOAD (which evalsha requires),
    # while EVAL is allowed. EVAL also lets a shared/proxied Redis stay
    # scriptless-cache-agnostic.
    def eval_script(script, keys: [], argv: [])
      @redis.eval(script, keys: keys, argv: argv)
    end

    def key(*keys)
      [@build_id, keys].join(":")
    end

    # We don't use any Ruby `Time` methods because specs that use timecop in
    # before(:all) hooks will mess up our times.
    def current_time
      @redis.time[0]
    end

    # Reconstructs whole-file timings by summing the timings of a file's
    # individual per-example ("file[...]") entries.
    def populate_splitted_file_timings(timings)
      whole_file_timings = Hash.new(0)

      timings.each do |file, duration|
        next if !file.include?("[")

        base_file = file.split("[").first
        whole_file_timings[base_file] += duration
      end

      whole_file_timings
    end
  end
end
