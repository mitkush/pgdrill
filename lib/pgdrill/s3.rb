require "cgi"
require "net/http"
require "openssl"
require "time"
require "uri"

module Pgdrill
  # Minimal S3 client (AWS Signature Version 4) for GetObject and ListObjectsV2, using only
  # the standard library. Works with AWS S3 and S3-compatible stores via an endpoint URL
  # (Cloudflare R2, Backblaze B2, RustFS, ...).
  class S3
    EMPTY_SHA256 = OpenSSL::Digest::SHA256.hexdigest("")
    Entry = Struct.new(:key, :size, :last_modified)

    attr_reader :region

    def self.from_env(env = ENV)
      ak, sk = env["AWS_ACCESS_KEY_ID"], env["AWS_SECRET_ACCESS_KEY"]
      unless ak && sk
        raise Error, "s3:// needs AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in the environment " \
                     "(for IAM roles or SSO, pass a presigned https:// URL instead, e.g. from `aws s3 presign`)"
      end
      new(access_key: ak, secret_key: sk, session_token: env["AWS_SESSION_TOKEN"],
          region: env["AWS_REGION"] || env["AWS_DEFAULT_REGION"] || "us-east-1",
          endpoint: env["AWS_ENDPOINT_URL_S3"] || env["AWS_ENDPOINT_URL"])
    end

    def initialize(access_key:, secret_key:, region:, session_token: nil, endpoint: nil, clock: -> { Time.now.utc })
      @ak, @sk, @token, @region, @clock = access_key, secret_key, session_token, region, clock
      @endpoint = endpoint && URI.parse(endpoint)
    end

    def get(bucket, key, io)
      uri = object_uri(bucket, key)
      request(uri) do |res|
        raise Error, s3_error(res, "s3://#{bucket}/#{key}") unless res.is_a?(Net::HTTPSuccess)
        res.read_body { io.write(_1) }
      end
    end

    def list(bucket, prefix)
      entries, token = [], nil
      loop do
        query = { "list-type" => "2", "prefix" => prefix }
        query["continuation-token"] = token if token
        body = nil
        request(object_uri(bucket, "", query)) do |res|
          raise Error, s3_error(res, "s3://#{bucket}/#{prefix}") unless res.is_a?(Net::HTTPSuccess)
          body = res.body
        end
        entries.concat(parse_list(body))
        break unless body.include?("<IsTruncated>true</IsTruncated>")
        token = xml_text(body[%r{<NextContinuationToken>(.*?)</NextContinuationToken>}m, 1])
      end
      entries
    end

    # Newest non-empty object under the prefix: the usual "drill last night's backup" case.
    def latest(bucket, prefix)
      pick = list(bucket, prefix).reject { _1.size.zero? || _1.key.end_with?("/") }.max_by(&:last_modified)
      raise Error, "no backups found under s3://#{bucket}/#{prefix}" unless pick
      pick
    end

    # Signs a request; returns the headers to send. Public so it can be checked against AWS's examples.
    def signed_headers(method, uri, extra = {}, payload_sha256: EMPTY_SHA256)
      now = @clock.call
      amz_date = now.strftime("%Y%m%dT%H%M%SZ")
      date = now.strftime("%Y%m%d")
      headers = { "host" => host_header(uri), "x-amz-content-sha256" => payload_sha256, "x-amz-date" => amz_date }
      headers["x-amz-security-token"] = @token if @token
      extra.each { |k, v| headers[k.downcase] = v.to_s.strip }
      names = headers.keys.sort
      canonical = [method, uri.path.empty? ? "/" : uri.path, canonical_query(uri.query),
                   names.map { "#{_1}:#{headers[_1]}\n" }.join, names.join(";"), payload_sha256].join("\n")
      scope = "#{date}/#{@region}/s3/aws4_request"
      to_sign = ["AWS4-HMAC-SHA256", amz_date, scope, OpenSSL::Digest::SHA256.hexdigest(canonical)].join("\n")
      key = %W[#{date} #{@region} s3 aws4_request].reduce("AWS4#{@sk}") { |k, part| hmac(k, part) }
      signature = OpenSSL::HMAC.hexdigest("SHA256", key, to_sign)
      headers.merge("authorization" => "AWS4-HMAC-SHA256 Credential=#{@ak}/#{scope}, SignedHeaders=#{names.join(';')}, Signature=#{signature}")
    end

    def object_uri(bucket, key, query = {})
      path_key = key.split("/", -1).map { encode(_1) }.join("/")
      q = query.empty? ? nil : query.map { |k, v| "#{encode(k)}=#{encode(v)}" }.join("&")
      if @endpoint
        base = @endpoint.dup
        base.path = "#{@endpoint.path.chomp('/')}/#{encode(bucket)}/#{path_key}"
        base.query = q
        base
      elsif bucket.include?(".")
        URI::HTTPS.build(host: "s3.#{@region}.amazonaws.com", path: "/#{bucket}/#{path_key}", query: q)
      else
        URI::HTTPS.build(host: "#{bucket}.s3.#{@region}.amazonaws.com", path: "/#{path_key}", query: q)
      end
    end

    private

    def request(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 15
      http.read_timeout = 120
      http.start do
        req = Net::HTTP::Get.new(uri)
        signed_headers("GET", uri).each { |k, v| req[k] = v }
        http.request(req) { yield _1 }
      end
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      raise Error, "cannot reach #{uri.host}: #{e.message}"
    end

    def host_header(uri) = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"

    def hmac(key, data) = OpenSSL::HMAC.digest("SHA256", key, data)

    # RFC 3986 unreserved characters stay; everything else is percent-encoded (SigV4 rules).
    def encode(s) = s.to_s.b.gsub(/[^A-Za-z0-9\-_.~]/) { format("%%%02X", _1.ord) }

    def canonical_query(q)
      return "" if q.nil? || q.empty?
      q.split("&").map { |p| k, v = p.split("=", 2); [k, v.to_s] }.sort.map { |k, v| "#{k}=#{v}" }.join("&")
    end

    def parse_list(xml)
      xml.scan(%r{<Contents>(.*?)</Contents>}m).map do |(c)|
        Entry.new(xml_text(c[%r{<Key>(.*?)</Key>}m, 1]), c[%r{<Size>(\d+)</Size>}, 1].to_i,
                  Time.parse(c[%r{<LastModified>(.*?)</LastModified>}, 1]))
      end
    end

    def xml_text(s) = CGI.unescapeHTML(s.to_s)

    def s3_error(res, what)
      body = res.body.to_s rescue ""
      code = body[%r{<Code>(.*?)</Code>}, 1]
      msg = body[%r{<Message>(.*?)</Message>}m, 1]
      "#{what}: HTTP #{res.code}#{code ? " #{code}" : ''}#{msg ? " (#{xml_text(msg)})" : ''}"
    end
  end
end
