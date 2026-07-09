require "socket"
require "openssl"
require "base64"
require "securerandom"
require "cgi"
require "json"
require "uri"

# Beeg (beeg.com) connector — merges free-text search/fetch (Identify's
# RESOLVER capability) with the public JSON API used for web recommendations
# (WEB_SEARCH capability) into one plugin object, per the `connector:` escape
# hatch (xvault docs/scraper-plugin-authoring.md). No API key needed.
#
# Clean-room reverse-engineered live from beeg.com's own webpack bundle
# (dist/main.*.js) — no server-rendered HTML exists to scrape (it's a Vue
# SPA). beeg.com's own frontend calls two backends, both unauthenticated:
#   - store.externulls.com   plain REST/JSON (tag lookup, tag's video list)
#   - search.externulls.com  a WebSocket, not REST — the site's search box
#     sends {type:"search", payload:{Search_string:...}} over it and gets
#     back an array of matching TAG records (category or performer), never
#     video records. beeg.com has no full-text video-title search API; typing
#     a query and hitting enter just resolves to the best-matching tag/
#     performer page. So #search here reproduces exactly that: resolve the
#     term to a tag over the WebSocket, then list that tag's videos via the
#     plain REST endpoint. A single word/name query (e.g. "lesbian", "riley
#     reid") works well; an arbitrary title-ish phrase generally will not
#     match any tag and returns [].
#
# ::Metadata::PageFetcher has no WebSocket support (nor does any Ruby stdlib
# HTTP client), so SearchSocket below is a minimal, single-request RFC 6455
# client built on Socket+OpenSSL (both stdlib) — open, upgrade, send one
# masked text frame, read one frame, close. It is the one piece of this file
# that needs live network to exercise, so it is kept as thin as possible and
# isolated behind #resolve_tag; everything else (JSON shape mapping, has_more
# math) is plain data-in/data-out and unit-tested via a stubbed
# ::Metadata::PageFetcher in test/beeg_test.rb.
#
# This file is `instance_eval`'d inside the host XVault process, so
# referencing ::Metadata::PageFetcher / ::Metadata::GenericJsonLd and
# ActiveSupport's blank?/present? is safe — they're core classes already
# loaded in the same process, not a dependency this file ships.
class Beeg
  def self.available?(_credential) = true
  def self.capabilities = %w[resolver web_search]
  def self.trusted_hosts = %w[beeg.com]

  # Identify panel search (RESOLVER) — maps the same tag-resolve + tag-videos
  # lookup WebSearchProvider uses, stamped with this plugin's own
  # source_key/source_id so Merger can attribute a picked result back to this
  # connector.
  def self.search(term, _credential)
    WebSearchProvider.search(term, limit: 12).map do |v|
      {
        title: v[:title],
        cover_url: v[:thumbnail_url],
        webpage_url: v[:webpage_url],
        duration: v[:duration],
        source_key: "beeg",
        source_id: v[:webpage_url]
      }
    end
  end

  # source_id is the video's page URL. beeg.com's video pages are entirely
  # client-rendered (no JSON-LD on the raw HTML), so this enrichment is best-
  # effort like every other connector's #fetch — it always at least sets
  # webpage_url so the next auto-resolve step can enrich further.
  def self.fetch(source_id, _credential)
    return nil if source_id.blank?

    html = ::Metadata::PageFetcher.get(source_id)
    data = html.present? ? ::Metadata::GenericJsonLd.extract(html) : {}
    data[:webpage_url] = source_id
    data
  rescue StandardError
    nil
  end

  # WEB_SEARCH capability — Recommendations::Web derives its provider list from
  # this instead of a hardcoded constant.
  def self.web_search_provider = WebSearchProvider

  # Implements the interface Recommendations::Web expects of a WEB_SEARCH
  # provider: .search/.search_page/.related. Never raises: any failure yields
  # [] (or has_more: false for #search_page).
  module WebSearchProvider
    HOST = "beeg.com"
    STORE = "https://store.externulls.com"
    THUMBS = "https://thumbs.externulls.com"

    def self.search(query, limit: 12, page: 1)
      search_page(query, limit: limit, page: page)[:results]
    end

    # Same lookup as #search, but also reports whether the tag has further
    # videos beyond this page — real tg_videos_count from the WebSocket's tag
    # record, not a guess.
    def self.search_page(query, limit: 12, page: 1)
      return { results: [], has_more: false } if query.blank?

      page = [ page.to_i, 1 ].max
      limit = limit.to_i.clamp(1, 36)
      tag = resolve_tag(query)
      return { results: [], has_more: false } if tag.nil?

      videos_for_tag(tag[:slug], tag[:videos_count], limit: limit, offset: (page - 1) * limit)
    rescue StandardError
      { results: [], has_more: false }
    end

    # beeg.com's SPA surfaces no related-videos API (only tag-page video
    # listings) — best-effort empty, per the WEB_SEARCH provider contract.
    def self.related(_webpage_url, limit: 12)
      []
    end

    def self.own_page?(url)
      host = URI.parse(url).host.to_s.downcase
      host == HOST || host.end_with?(".#{HOST}") # suffix alone would match notbeeg.com
    rescue URI::InvalidURIError
      false
    end
    private_class_method :own_page?

    # Resolves a free-text query to its best-matching tag (category or
    # performer — beeg represents both as "tags") over the search WebSocket.
    def self.resolve_tag(query)
      tags = SearchSocket.search_tags(query, limit: 5)
      best = tags.first
      return nil if best.nil? || best["tg_slug"].to_s.empty?

      { slug: best["tg_slug"], videos_count: best["tg_videos_count"] }
    end
    private_class_method :resolve_tag

    # Plain REST GET — the pure, unit-testable half of #search_page. Kept
    # separate from #resolve_tag so tests can stub ::Metadata::PageFetcher and
    # exercise this without a live WebSocket.
    def self.videos_for_tag(slug, videos_count, limit:, offset:)
      url = "#{STORE}/tag/videos/#{CGI.escape(slug)}?#{URI.encode_www_form(limit: limit, offset: offset)}"
      body = ::Metadata::PageFetcher.get(url)
      return { results: [], has_more: false } if body.blank?

      results = Array(JSON.parse(body)).filter_map { |v| map_video(v) }
      { results: results, has_more: videos_count.to_i > offset + results.length }
    rescue StandardError
      { results: [], has_more: false }
    end
    private_class_method :videos_for_tag

    def self.map_video(video)
      file = video["file"] || {}
      return nil if file["id"].blank?

      title = Array(file["data"]).find { |d| d["cd_column"] == "sf_name" }&.dig("cd_value")
      {
        provider: "beeg",
        title: title.presence || "Untitled",
        webpage_url: "https://#{HOST}/-0#{file["id"]}",
        embed_url: "https://#{HOST}/embed/#{file["id"]}",
        thumbnail_url: "#{THUMBS}/videos/#{file["id"]}/0.webp?size=320x180",
        duration: file["fl_duration"]
      }
    end
    private_class_method :map_video

    # Minimal one-shot RFC 6455 client — the only way to reach beeg's search
    # box, which is WebSocket-only (verified live: a plain HTTPS GET to
    # search.externulls.com returns "400 Bad Request", it only accepts the
    # Upgrade handshake). ::Metadata::PageFetcher and Net::HTTP can't do
    # WebSocket, so this hand-rolls the handshake and framing on stdlib
    # Socket+OpenSSL: connect, upgrade, send one masked text frame, read one
    # frame, close. No ping/continuation handling — beeg's search op always
    # replies with exactly one small text frame (observed live), and a 6s
    # socket read timeout guards against ever hanging the caller.
    module SearchSocket
      WS_HOST = "search.externulls.com"
      READ_TIMEOUT = 6 # seconds; ponytail: fixed budget, no retry — a slow search API isn't worth stalling the whole search() call for

      def self.search_tags(query, limit: 5)
        payload = JSON.generate({
          type: "search",
          ignore_stats: true,
          payload: { Search_string: query, offset: 0, limit: limit, category_id: nil }
        })
        body = round_trip(payload)
        return [] if body.to_s.strip.empty?

        Array(JSON.parse(body)).first(limit)
      rescue StandardError
        []
      end

      def self.round_trip(payload)
        tcp = TCPSocket.new(WS_HOST, 443)
        tcp.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [ READ_TIMEOUT, 0 ].pack("l_2"))
        ssl = OpenSSL::SSL::SSLSocket.new(tcp, OpenSSL::SSL::SSLContext.new)
        ssl.hostname = WS_HOST
        ssl.connect
        handshake!(ssl)
        send_frame(ssl, payload)
        read_frame(ssl)
      ensure
        ssl&.close
        tcp&.close
      end
      private_class_method :round_trip

      def self.handshake!(ssl)
        key = Base64.strict_encode64(SecureRandom.random_bytes(16))
        ssl.write(
          "GET / HTTP/1.1\r\n" \
          "Host: #{WS_HOST}\r\n" \
          "Upgrade: websocket\r\n" \
          "Connection: Upgrade\r\n" \
          "Sec-WebSocket-Key: #{key}\r\n" \
          "Sec-WebSocket-Version: 13\r\n" \
          "Origin: https://#{HOST}\r\n\r\n"
        )
        headers = "".b
        headers << ssl.readpartial(4096) until headers.include?("\r\n\r\n")
        raise "beeg search handshake failed" unless headers.start_with?("HTTP/1.1 101")
      end
      private_class_method :handshake!

      def self.send_frame(ssl, payload)
        data = payload.b
        mask = SecureRandom.random_bytes(4)
        len = data.bytesize
        frame = +"".b
        frame << [ 0x81 ].pack("C") # FIN + text frame opcode
        frame << if len <= 125
          [ 0x80 | len ].pack("C")
        elsif len <= 65_535
          [ 0x80 | 126, len ].pack("Cn")
        else
          [ 0x80 | 127, len ].pack("CQ>")
        end
        frame << mask
        frame << data.bytes.each_with_index.map { |b, i| b ^ mask.getbyte(i % 4) }.pack("C*")
        ssl.write(frame)
      end
      private_class_method :send_frame

      def self.read_frame(ssl)
        len = read_exactly(ssl, 2).getbyte(1) & 0x7F
        len = read_exactly(ssl, 2).unpack1("n") if len == 126
        len = read_exactly(ssl, 8).unpack1("Q>") if len == 127
        read_exactly(ssl, len)
      end
      private_class_method :read_frame

      def self.read_exactly(ssl, n)
        buf = "".b
        buf << ssl.readpartial(n - buf.bytesize) while buf.bytesize < n
        buf
      end
      private_class_method :read_exactly
    end
    private_constant :SearchSocket
  end
end

Beeg
