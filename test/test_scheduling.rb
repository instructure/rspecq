require "test_helpers"

class TestScheduling < RSpecQTest
  def test_scheduling_with_timings_simple
    worker = new_worker("timings")
    worker.populate_timings = true
    silent { worker.work }

    assert_queue_well_formed(worker.queue)

    worker = new_worker("timings")
    # worker.populate_timings is false by default
    queue = worker.queue
    silent { worker.try_publish_queue!(queue) }

    assert_equal [
      "./test/sample_suites/timings/spec/very_slow_spec.rb",
      "./test/sample_suites/timings/spec/slow_spec.rb",
      "./test/sample_suites/timings/spec/medium_spec.rb",
      "./test/sample_suites/timings/spec/fast_spec.rb",
      "./test/sample_suites/timings/spec/very_fast_spec.rb"
    ], queue.unprocessed_jobs
  end

  def test_scheduling_with_timings_and_splitting
    worker = new_worker("scheduling")
    worker.populate_timings = true
    silent { worker.work }

    assert_queue_well_formed(worker.queue)

    # 1st run with timings, the slow file will be split
    # chunk_target_duration=0 keeps each example as its own job (no chunking)
    worker = new_worker("scheduling")
    worker.populate_timings = true
    worker.file_split_threshold = 0.2
    worker.chunk_target_duration = 0
    silent { worker.work }

    assert_queue_well_formed(worker.queue)

    assert_processed_jobs([
      "./test/sample_suites/scheduling/spec/bar_spec.rb",
      "./test/sample_suites/scheduling/spec/foo_spec.rb[1:1]",
      "./test/sample_suites/scheduling/spec/foo_spec.rb[1:2:1]",
    ], worker.queue)

    # 2nd run with timings; individual example jobs will also have timings now
    worker = new_worker("scheduling")
    worker.populate_timings = true
    worker.file_split_threshold = 0.2
    worker.chunk_target_duration = 0  # 0 disables chunking (each example is its own job)
    silent { worker.try_publish_queue!(worker.queue) }

    assert_equal [
      "./test/sample_suites/scheduling/spec/foo_spec.rb[1:2:1]",
      "./test/sample_suites/scheduling/spec/foo_spec.rb[1:1]",
      "./test/sample_suites/scheduling/spec/bar_spec.rb",
    ], worker.queue.unprocessed_jobs
  end

  def test_time_balanced_chunks
    # 1st run: no splitting, records file-level timing for foo_spec.rb (~0.3s)
    worker = new_worker("scheduling")
    worker.populate_timings = true
    silent { worker.work }

    assert_queue_well_formed(worker.queue)

    # 2nd run: split + chunk; target=1s groups both examples into one chunk
    worker = new_worker("scheduling")
    worker.populate_timings = true
    worker.file_split_threshold = 0.2
    worker.chunk_target_duration = 1
    silent { worker.work }

    assert_queue_well_formed(worker.queue)

    # Both examples from foo_spec.rb are combined into a single chunk job
    processed = worker.queue.processed_jobs
    assert_equal 2, processed.size, "Expected 2 jobs: 1 chunk + bar_spec.rb"
    assert processed.any? { |j| j.include?("+") }, "Expected at least one chunk job"
    assert processed.any? { |j| j == "./test/sample_suites/scheduling/spec/bar_spec.rb" }

    chunk_job = processed.find { |j| j.include?("+") }
    parts = chunk_job.split("+")
    assert_equal 2, parts.size, "Chunk should contain both examples from foo_spec.rb"
    assert parts.all? { |p| p.start_with?("./test/sample_suites/scheduling/spec/foo_spec.rb[") }

    # 3rd run: per-example timings now in Redis; verify ordering within chunk
    worker = new_worker("scheduling")
    worker.populate_timings = true
    worker.file_split_threshold = 0.2
    worker.chunk_target_duration = 1
    silent { worker.try_publish_queue!(worker.queue) }

    unprocessed = worker.queue.unprocessed_jobs
    assert_equal 2, unprocessed.size
    # The chunk (slowest total ~0.3s) should be scheduled before bar_spec.rb
    assert unprocessed.first.include?("+"), "Chunk job should be scheduled first"
    # Within the chunk, the slowest example [1:2:1] (~0.2s) should come first
    assert unprocessed.first.start_with?("./test/sample_suites/scheduling/spec/foo_spec.rb[1:2:1]")
  end

  def test_untimed_jobs_scheduled_in_the_middle
    worker = new_worker("scheduling_untimed/spec/foo")
    worker.populate_timings = true
    silent { worker.work }

    assert_queue_well_formed(worker.queue)
    assert worker.queue.build_successful?
    refute_empty worker.queue.timings

    worker = new_worker("scheduling_untimed")
    silent { worker.try_publish_queue!(worker.queue) }
    assert_equal [
      "./test/sample_suites/scheduling_untimed/spec/foo/bar_spec.rb",
      "./test/sample_suites/scheduling_untimed/spec/foo/foo_spec.rb",
      "./test/sample_suites/scheduling_untimed/spec/bar/untimed_spec.rb",
      "./test/sample_suites/scheduling_untimed/spec/foo/zxc_spec.rb",
      "./test/sample_suites/scheduling_untimed/spec/foo/baz_spec.rb",
    ], worker.queue.unprocessed_jobs
  end

  def test_splitting_with_deprecation_warning
    worker = new_worker("deprecation_warning")
    worker.populate_timings = true
    silent { worker.work }

    assert_queue_well_formed(worker.queue)
    assert worker.queue.build_successful?
    refute_empty worker.queue.timings

    worker = new_worker("deprecation_warning")
    worker.file_split_threshold = 0.2
    worker.chunk_target_duration = 0  # 0 disables chunking (each example is its own job)
    silent { worker.work }

    assert_queue_well_formed(worker.queue)
    assert worker.queue.build_successful?
    assert_processed_jobs([
      "./test/sample_suites/deprecation_warning/spec/foo_spec.rb[1:1]",
      "./test/sample_suites/deprecation_warning/spec/foo_spec.rb[1:2]",
    ], worker.queue)
  end
end
