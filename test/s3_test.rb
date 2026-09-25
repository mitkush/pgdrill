require_relative "test_helper"

class S3Test < Minitest::Test
  # Example credentials and expected signatures from AWS's S3 SigV4 documentation
  # ("Authenticating Requests: Using the Authorization Header", single-chunk payload examples).
  AK = "AKIAIOSFODNN7EXAMPLE"
  SK = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  AWS_CLOCK = -> { Time.utc(2013, 5, 24) }

  def client(**kw) = Pgdrill::S3.new(access_key: AK, secret_key: SK, region: "us-east-1", clock: AWS_CLOCK, **kw)

  def signature(headers) = headers["authorization"][/Signature=(\h+)/, 1]

  def test_get_object_matches_aws_example
    uri = URI("https://examplebucket.s3.amazonaws.com/test.txt")
    h = client.signed_headers("GET", uri, { "Range" => "bytes=0-9" })
    assert_equal "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", signature(h)
    assert_includes h["authorization"], "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date"
  end

  def test_list_objects_matches_aws_example
    uri = URI("https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")
    assert_equal "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7", signature(client.signed_headers("GET", uri))
  end

  def test_session_token_is_signed
    h = client(session_token: "tok").signed_headers("GET", URI("https://b.s3.amazonaws.com/k"))
    assert_equal "tok", h["x-amz-security-token"]
    assert_includes h["authorization"], "x-amz-security-token"
  end

  def test_uri_styles
    assert_equal "https://nightly.s3.eu-west-1.amazonaws.com/db/2026%2009.dump",
                 Pgdrill::S3.new(access_key: AK, secret_key: SK, region: "eu-west-1").object_uri("nightly", "db/2026 09.dump").to_s
    assert_equal "https://s3.us-east-1.amazonaws.com/my.bucket/a.dump", client.object_uri("my.bucket", "a.dump").to_s
    assert_equal "http://127.0.0.1:9000/b/x/y.dump?list-type=2&prefix=x%2F",
                 client(endpoint: "http://127.0.0.1:9000").object_uri("b", "x/y.dump", { "list-type" => "2", "prefix" => "x/" }).to_s
  end

  def test_host_header_includes_non_default_port
    h = client(endpoint: "http://127.0.0.1:9000").signed_headers("GET", URI("http://127.0.0.1:9000/b/k"))
    assert_equal "127.0.0.1:9000", h["host"]
  end

  def test_from_env_requires_keys
    err = assert_raises(Pgdrill::Error) { Pgdrill::S3.from_env({}) }
    assert_includes err.message, "presign"
  end
end

class SourceTest < Minitest::Test
  def test_redact_strips_presigned_signature_and_userinfo
    url = "https://user:pw@bucket.s3.amazonaws.com/db.dump?X-Amz-Credential=AKIA%2F&X-Amz-Signature=deadbeef"
    red = Pgdrill::Source.redact(url)
    refute_match(/deadbeef|AKIA|pw/, red)
    assert_equal "https://bucket.s3.amazonaws.com/db.dump?…", red
  end

  def test_parse_s3
    assert_equal ["b", "nightly/"], Pgdrill::Source.parse_s3("s3://b/nightly/")
    assert_equal ["b", ""], Pgdrill::Source.parse_s3("s3://b")
    assert_raises(Pgdrill::Error) { Pgdrill::Source.parse_s3("s3://") }
  end

  def test_local_paths_pass_through
    f = Pgdrill::Source.fetch("/tmp/x.dump")
    assert_equal "/tmp/x.dump", f.path
    assert_raises(Pgdrill::Error) { Pgdrill::Source.fetch("/tmp/x.dump", latest: true) }
  end

  class FakeS3
    def initialize(entries) = @entries = entries
    def latest(_bucket, prefix) = @entries.select { _1.key.start_with?(prefix) && _1.size.positive? }.max_by(&:last_modified)
    def get(_bucket, key, io) = io.write("contents of #{key}")
  end

  class ShortS3 < FakeS3
    def get(_bucket, _key, io) = io.write("partial").then { 1_000 } # server declared 1000 bytes
  end

  def test_cut_off_download_is_a_tool_error_and_cleans_up
    before = Dir.glob(File.join(Dir.tmpdir, "pgdrill-src-*")).size
    err = assert_raises(Pgdrill::Error) { Pgdrill::Source.fetch("s3://b/k.dump", s3: ShortS3.new([])) }
    assert_includes err.message, "cut off"
    assert_equal before, Dir.glob(File.join(Dir.tmpdir, "pgdrill-src-*")).size
  end

  def test_latest_breaks_timestamp_ties_by_key
    e = Pgdrill::S3::Entry
    s3 = Pgdrill::S3.new(access_key: "a", secret_key: "b", region: "r")
    t = Time.utc(2026, 9, 25)
    s3.define_singleton_method(:list) { |*| [e.new("n/2026-09-24.dump", 5, t), e.new("n/2026-09-25.dump", 5, t)] }
    assert_equal "n/2026-09-25.dump", s3.latest("b", "n/").key
  end

  def test_latest_can_skip_baseline_json_files
    e = Pgdrill::S3::Entry
    s3 = Pgdrill::S3.new(access_key: "a", secret_key: "b", region: "r")
    s3.define_singleton_method(:list) { |*| [e.new("n/db.dump", 5, Time.utc(2026, 9, 25, 3)), e.new("n/db.baseline.json", 5, Time.utc(2026, 9, 25, 4))] }
    assert_equal "n/db.baseline.json", s3.latest("b", "n/").key
    assert_equal "n/db.dump", s3.latest("b", "n/", skip: /\.json\z/).key
  end

  def test_s3_prefix_downloads_newest_object_into_private_dir
    e = Pgdrill::S3::Entry
    fake = FakeS3.new([e.new("n/old.dump", 5, Time.utc(2026, 9, 1)), e.new("n/new.dump", 5, Time.utc(2026, 9, 2)), e.new("n/empty", 0, Time.utc(2026, 9, 3))])
    f = Pgdrill::Source.fetch("s3://b/n/", s3: fake)
    assert_equal "n/new.dump", f.key
    assert_equal "contents of n/new.dump", File.read(f.path)
    assert_equal "700", format("%o", File.stat(f.dir).mode & 0o777)
    f.cleanup
    refute File.exist?(f.dir)
  end
end
