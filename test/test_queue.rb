require "test_helpers"

class TestQueue < RSpecQTest
  def test_flaky_jobs
    build_id = rand_id

    Process.wait(start_worker(build_id: build_id, suite: "flaky_job_detection"))

    queue = RSpecQ::Queue.new(build_id, "foo", REDIS_OPTS, 60)

    assert_queue_well_formed(queue)
    refute queue.build_successful?

    assert_equal ["./spec/flaky_spec.rb[1:1]", "./spec/flaky_spec.rb[1:3]"],
      queue.flaky_jobs.sort

    assert_processed_jobs(
      ["./spec/passing_spec.rb",
       "./spec/flaky_spec.rb",
       "./spec/flaky_spec.rb[1:1]",
       "./spec/flaky_spec.rb[1:3]",
       "./spec/legit_failure_spec.rb",
       "./spec/legit_failure_spec.rb[1:3]"], queue
    )

    assert_equal 3, queue.flaky_failures.size # legit failure + 2 flakes

    assert_equal [
      "./spec/flaky_spec.rb[1:1]",
      "./spec/flaky_spec.rb[1:3]",
      "./spec/legit_failure_spec.rb[1:3]"
      ],
      queue.flaky_failures.keys.sort

    assert_failures(["./spec/legit_failure_spec.rb[1:3]"], queue)
  end

  def test_publish_returns_jobs_size
    queue = RSpecQ::Queue.new(rand_id, rand_id, REDIS_OPTS, 60)

    assert_equal 2, queue.publish(["job1", "job2"])
  end

  def test_update_global_timings_clears_inherited_ttl
    dst = rand_id
    queue = RSpecQ::Queue.new(rand_id, "foo", REDIS_OPTS, 60)
    queue.record_build_timing("./spec/a_spec.rb", 1.0)
    queue.record_build_timing("./spec/b_spec.rb", 2.0)

    queue.update_global_timings(dst)

    redis = Redis.new(REDIS_OPTS)
    assert_equal 2, redis.zcard(dst)
    assert_equal(-1, redis.ttl(dst),
      "promoted global timings key must not inherit the build key's TTL")
  end
end
