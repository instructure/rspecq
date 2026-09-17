require "test_helpers"

# Pure unit tests for Configuration#redis_opts. These don't touch Redis, so
# we subclass Minitest::Test directly to skip RSpecQTest's flushdb setup.
class TestConfiguration < Minitest::Test
  def test_redis_opts_with_url_have_resilient_defaults
    config = RSpecQ::Configuration.new(["--build", "1", "--report", "--redis-url", "redis://example:6379"])

    assert_equal "redis://example:6379", config.redis_opts[:url]
    assert_resilient_redis_opts(config.redis_opts)
  end

  def test_redis_opts_with_host_have_resilient_defaults
    config = RSpecQ::Configuration.new(["--build", "1", "--worker", "foo", "--redis-host", "example"])

    assert_equal "example", config.redis_opts[:host]
    assert_resilient_redis_opts(config.redis_opts)
  end

  def test_redis_connection_opts_are_env_tunable
    with_env(
      "RSPECQ_REDIS_CONNECT_TIMEOUT" => "2.5",
      "RSPECQ_REDIS_READ_TIMEOUT" => "10",
      "RSPECQ_REDIS_WRITE_TIMEOUT" => "7.5",
      "RSPECQ_REDIS_RECONNECT_ATTEMPTS" => "0.1,0.2,0.4"
    ) do
      opts = RSpecQ::Configuration.new(["--build", "1", "--report", "--redis-url", "redis://x:6379"]).redis_opts

      assert_in_delta 2.5, opts[:connect_timeout]
      assert_in_delta 10.0, opts[:read_timeout]
      assert_in_delta 7.5, opts[:write_timeout]
      assert_equal [0.1, 0.2, 0.4], opts[:reconnect_attempts]
    end
  end

  def test_redis_connection_opts_are_cli_tunable
    opts = RSpecQ::Configuration.new([
      "--build", "1", "--report", "--redis-url", "redis://x:6379",
      "--redis-read-timeout", "9",
      "--redis-reconnect-attempts", "0.2,0.8"
    ]).redis_opts

    assert_in_delta 9.0, opts[:read_timeout]
    assert_equal [0.2, 0.8], opts[:reconnect_attempts]
    # untouched options keep their defaults
    assert_in_delta 1.0, opts[:connect_timeout]
  end

  def test_redis_reconnect_attempts_can_be_disabled
    with_env("RSPECQ_REDIS_RECONNECT_ATTEMPTS" => "") do
      opts = RSpecQ::Configuration.new(["--build", "1", "--report", "--redis-url", "redis://x:6379"]).redis_opts

      assert_equal false, opts[:reconnect_attempts]
    end
  end

  # Jenkins string parameters commonly default to "", which must fall back to
  # the shipped defaults rather than crashing on Float("").
  def test_blank_env_timeouts_fall_back_to_defaults
    with_env(
      "RSPECQ_REDIS_CONNECT_TIMEOUT" => "",
      "RSPECQ_REDIS_READ_TIMEOUT" => "  ",
      "RSPECQ_REDIS_WRITE_TIMEOUT" => ""
    ) do
      opts = RSpecQ::Configuration.new(["--build", "1", "--report", "--redis-url", "redis://x:6379"]).redis_opts

      assert_in_delta 1.0, opts[:connect_timeout]
      assert_in_delta 5.0, opts[:read_timeout]
      assert_in_delta 5.0, opts[:write_timeout]
    end
  end

  # Whitespace-only / blank entries disable reconnects instead of crashing.
  def test_blank_reconnect_attempts_disable_reconnects
    with_env("RSPECQ_REDIS_RECONNECT_ATTEMPTS" => "   ") do
      opts = RSpecQ::Configuration.new(["--build", "1", "--report", "--redis-url", "redis://x:6379"]).redis_opts

      assert_equal false, opts[:reconnect_attempts]
    end
  end

  # Empty entries within the list are ignored rather than crashing on Float("").
  def test_reconnect_attempts_ignores_empty_entries
    with_env("RSPECQ_REDIS_RECONNECT_ATTEMPTS" => "0.1,,0.2, ,0.3") do
      opts = RSpecQ::Configuration.new(["--build", "1", "--report", "--redis-url", "redis://x:6379"]).redis_opts

      assert_equal [0.1, 0.2, 0.3], opts[:reconnect_attempts]
    end
  end

  private

  # Sets the given ENV vars for the block, restoring prior values afterwards.
  def with_env(vars)
    original = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    original.each { |k, v| ENV[k] = v }
  end

  # The shared CI Redis is single-threaded and connections get reaped/dropped,
  # so we must not rely on redis-client's defaults (1.0s timeouts, no reconnect)
  # which turn a transient blip into a fatal CannotConnectError. These assert
  # the shipped defaults (used when the env overrides are unset).
  def assert_resilient_redis_opts(opts)
    assert_in_delta 1.0, opts[:connect_timeout]
    assert_in_delta 5.0, opts[:read_timeout]
    assert_in_delta 5.0, opts[:write_timeout]
    assert_equal [0.05, 0.1, 0.25, 0.5, 1.0], opts[:reconnect_attempts]
  end
end
