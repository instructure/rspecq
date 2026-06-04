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

  private

  # The shared CI Redis is single-threaded and connections get reaped/dropped,
  # so we must not rely on redis-client's defaults (1.0s timeouts, no reconnect)
  # which turn a transient blip into a fatal CannotConnectError.
  def assert_resilient_redis_opts(opts)
    assert_operator opts[:read_timeout], :>, 1.0,
      "read_timeout must be more forgiving than the 1.0s default"
    assert_operator opts[:write_timeout], :>, 1.0,
      "write_timeout must be more forgiving than the 1.0s default"
    assert_kind_of Array, opts[:reconnect_attempts],
      "reconnect_attempts must retry the dropped-connection case"
    refute_empty opts[:reconnect_attempts]
  end
end
