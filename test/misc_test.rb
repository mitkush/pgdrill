require_relative "test_helper"

class DurationTest < Minitest::Test
  def test_parse
    assert_equal 90, Pgdrill::Duration.parse("90s")
    assert_equal 26 * 3600, Pgdrill::Duration.parse("26h")
    assert_equal 2 * 86_400, Pgdrill::Duration.parse("2d")
    assert_raises(Pgdrill::Error) { Pgdrill::Duration.parse("soon") }
  end

  def test_human
    assert_equal "0.2s", Pgdrill::Duration.human(0.2)
    assert_equal "45s", Pgdrill::Duration.human(45)
    assert_equal "3.1h", Pgdrill::Duration.human(3.1 * 3600)
  end
end

class DbTest < Minitest::Test
  def test_credentials_go_to_env_not_argv
    env = Pgdrill::Db.env_for("postgresql://app%40x:s%3Acret@db.example.com:6543/my%20db?sslmode=require")
    assert_equal "app@x", env["PGUSER"]
    assert_equal "s:cret", env["PGPASSWORD"]
    assert_equal "db.example.com", env["PGHOST"]
    assert_equal "6543", env["PGPORT"]
    assert_equal "my db", env["PGDATABASE"]
    assert_equal "require", env["PGSSLMODE"]
    assert_equal "UTC", env["PGTZ"]
  end

  def test_rejects_other_schemes
    assert_raises(Pgdrill::Error) { Pgdrill::Db.env_for("mysql://x/y") }
  end
end
