require_relative "pgdrill/version"

module Pgdrill
  class Error < StandardError; end

  autoload :Db, "pgdrill/db"
  autoload :Inspector, "pgdrill/inspector"
  autoload :Baseline, "pgdrill/baseline"
  autoload :BackupFile, "pgdrill/backup_file"
  autoload :Cluster, "pgdrill/cluster"
  autoload :Restorer, "pgdrill/restorer"
  autoload :Checks, "pgdrill/checks"
  autoload :Finding, "pgdrill/checks"
  autoload :Report, "pgdrill/report"
  autoload :Duration, "pgdrill/duration"
  autoload :CLI, "pgdrill/cli"
end

$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)
