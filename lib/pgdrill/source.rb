require "fileutils"
require "net/http"
require "tmpdir"
require "uri"

module Pgdrill
  # Turns a backup location (local path, s3://, https://) into a local file.
  module Source
    Fetched = Struct.new(:path, :display, :key, :seconds, :dir, keyword_init: true) do
      def cleanup = dir && FileUtils.rm_rf(dir)
    end

    MAX_REDIRECTS = 5

    module_function

    # latest: treat an s3:// location as a prefix and drill the newest object under it
    # (also implied by a trailing slash).
    # skip: pattern of keys `latest` must ignore (dumps skip .json so a baseline stored alongside is never drilled).
    def fetch(spec, latest: false, s3: nil, log: nil, skip: nil)
      case spec
      when %r{\As3://}i then fetch_s3(spec, latest, s3 || S3.from_env, log, skip)
      when %r{\Ahttps?://}i then fetch_http(spec, log)
      else
        raise Error, "--latest only works with s3:// locations" if latest
        Fetched.new(path: spec, display: spec, seconds: 0.0)
      end
    end

    # Presigned URLs carry credentials in the query string; never print or store them.
    def redact(url)
      u = URI.parse(url)
      u.user = u.password = nil if u.userinfo
      u.query = nil
      u.fragment = nil
      u.to_s + (URI.parse(url).query ? "?…" : "")
    rescue URI::InvalidURIError
      "(unparseable URL)"
    end

    def redact_spec(spec) = spec.to_s.match?(%r{\Ahttps?://}i) ? redact(spec) : spec.to_s

    def parse_s3(spec)
      m = spec.match(%r{\As3://([^/]+)/?(.*)\z}i) or raise Error, "invalid S3 location #{spec.inspect} (use s3://bucket/key)"
      [m[1], m[2]]
    end

    def fetch_s3(spec, latest, client, log, skip = nil)
      bucket, key = parse_s3(spec)
      if latest || key.empty? || key.end_with?("/")
        entry = skip ? client.latest(bucket, key, skip: skip) : client.latest(bucket, key)
        log&.call("newest backup under s3://#{bucket}/#{key}: #{entry.key} (#{entry.last_modified.utc.iso8601})")
        key = entry.key
      end
      download("s3://#{bucket}/#{key}", File.basename(key), key: key, log: log) { |io| client.get(bucket, key, io) }
    end

    def fetch_http(url, log)
      name = File.basename(URI.parse(url).path.to_s)
      download(redact(url), name.empty? ? "backup" : name, log: log) { |io| http_get(URI.parse(url), io) }
    end

    def download(display, name, key: nil, log: nil)
      dir = Dir.mktmpdir("pgdrill-src-") # 0700: the backup is a copy of production
      path = File.join(dir, name.gsub(/[^\w.\-]/, "_"))
      log&.call("downloading #{display}")
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expected = File.open(path, "wb", 0o600) { |io| yield io }
      # A transfer that ends early is a network problem, not a broken backup: stop with a tool error.
      if expected && (got = File.size(path)) != expected
        raise Error, "download of #{display} was cut off: received #{got} of #{expected} bytes; retry the drill"
      end
      Fetched.new(path: path, display: display, key: key, dir: dir,
                  seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(1))
    rescue StandardError
      FileUtils.rm_rf(dir) if dir
      raise
    end

    def http_get(uri, io, redirects = 0)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 15, read_timeout: 120) do |http|
        req = Net::HTTP::Get.new(uri)
        req["accept-encoding"] = "identity" # so Content-Length is the real file size
        http.request(req) do |res|
          case res
          when Net::HTTPSuccess
            res.read_body { io.write(_1) }
            return res["content-length"]&.to_i
          when Net::HTTPRedirection
            raise Error, "too many redirects downloading #{redact(uri.to_s)}" if redirects >= MAX_REDIRECTS
            return http_get(URI.join(uri, res["location"]), io, redirects + 1)
          else
            raise Error, "downloading #{redact(uri.to_s)} failed: HTTP #{res.code} #{res.message}"
          end
        end
      end
    rescue *S3::NETWORK_ERRORS => e
      raise Error, "cannot download #{redact(uri.to_s)}: #{e.class}: #{e.message}"
    end
  end
end
