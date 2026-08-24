require_relative "lib/rspecq/version"

Gem::Specification.new do |s|
  s.name        = "rspecq"
  s.version     = RSpecQ::VERSION
  s.summary     = "Optimally distribute and run RSpec suites among parallel " \
                  "workers; for faster CI builds"
  s.authors     = "Agis Anastasopoulos"
  s.email       = "agis.anast@gmail.com"
  s.files       = Dir["lib/**/*", "CHANGELOG.md", "LICENSE", "Rakefile", "README.md"]
  s.executables << "rspecq"
  s.homepage    = "https://github.com/skroutz/rspecq"
  s.license     = "MIT"

  # redis-rb 6.0 requires Ruby 3.2+.
  s.required_ruby_version = ">= 3.2"

  if ENV["CI"] && ENV["RSPEC_CORE"]
    s.add_dependency "rspec-core", ENV["RSPEC_CORE"]
  else
    s.add_dependency "rspec-core"
  end

  # In CI, REDIS_GEM pins a specific redis-rb version for the matrix (mirrors
  # RSPEC_CORE above), since Gemfile.lock is gitignored and resolves fresh.
  if ENV["CI"] && ENV["REDIS_GEM"]
    s.add_dependency "redis", ENV["REDIS_GEM"]
  else
    s.add_dependency "redis", ">= 5.0", "< 7.0"
  end
  s.add_dependency "sentry-ruby"
  s.add_dependency "rspec_junit_formatter"
  s.add_dependency "logger" # sentry-ruby dependency in ruby 3.5 (should be fixed upstream)

  s.add_development_dependency "minitest"
  s.add_development_dependency "pry-byebug"
  s.add_development_dependency "rake"
  s.add_development_dependency "rspec"
  s.add_development_dependency "rubocop", "~> 0.93.0"
end
