require_relative "lib/pgdrill/version"

Gem::Specification.new do |s|
  s.name = "pgdrill"
  s.version = Pgdrill::VERSION
  s.summary = "Prove your Postgres backups actually restore: complete, correct and fresh"
  s.description = "pgdrill restores a pg_dump backup into a throwaway Postgres server and verifies it against " \
                  "production: schema, row counts, data freshness, sequence positions and index integrity (amcheck)."
  s.authors = ["mitkush"]
  s.homepage = "https://github.com/mitkush/pgdrill"
  s.license = "MIT"
  s.required_ruby_version = ">= 3.0"
  s.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE"]
  s.bindir = "exe"
  s.executables = ["pgdrill"]
  s.metadata = {
    "source_code_uri" => s.homepage,
    "bug_tracker_uri" => "#{s.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
end
