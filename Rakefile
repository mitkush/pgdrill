require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib"
  t.test_files = FileList["test/*_test.rb"]
end

desc "Break backups on purpose and check pgdrill catches each (needs PGDRILL_SCENARIO_DB)"
task :scenarios do
  ruby "test/scenarios/run.rb"
end

task default: :test
