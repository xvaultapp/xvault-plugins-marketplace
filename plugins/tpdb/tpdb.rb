require "net/http"
require "uri"
require "cgi"
require "json"

# ThePornDB (theporndb.net) connector — merges the former core Metadata::Tpdb
# resolver with Connectors::Tpdb's plugin-interface shim into one plugin
# object, per the `connector:` escape hatch (xvault docs/scraper-plugin-authoring.md).
# #fingerprint_match is the pure PHASH lookup (XVault's Library::Phash is bit-compatible
# with TPDB's, so a matching stored PHASH is a near-exact hit; confirmed with a duration
# agreement ±5s to guard against hash collisions) — the host calls it directly for
# auto-resolve and owns the per-scene resolve throttle. #resolve wraps it with two more
# fallback strategies for the Identify panel's manual retry, tried in order:
#   (a) fingerprint_match
#   (b) URL verify — when the scene's page URL is already known, parse-search TPDB
#       and keep the candidate whose own url matches ours (host+path).
#   (c) free-text parse-search on the cleaned title, as a last resort.
# Neither method ever raises; both return {} on any failure, missing credential, or no
# match. See docs/tpdb-api.md for the (unofficial) API surface.
#
# Ported ~verbatim from XVault core's former Metadata::Tpdb + Connectors::Tpdb
# (#40 plugin extraction). This file is `instance_eval`'d inside the host XVault
# process, so referencing ActiveSupport's blank?/present? is safe — it's already
# loaded in the same process, not a dependency this file ships.
class Tpdb
  BASE = "https://api.theporndb.net".freeze
  DURATION_TOLERANCE = 5 # seconds; ponytail: the disambiguation knob, widen if hits are missed
  PARSE_SEARCH_DURATION_TOLERANCE = 10 # seconds; wider than phash — free-text search is fuzzier, needs a stronger guard

  # Thin HTTP wrapper: 10s timeouts, one retry on timeout, one retry after a 2s backoff
  # on 429. Returns the JSON body on 200, nil on anything else. Never raises.
  class Client
    def initialize(credential)
      @credential = credential
    end

    def get(path)
      uri = URI("#{BASE}#{path}")
      retried_timeout = false
      retried_429 = false
      begin
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) do |http|
          req = Net::HTTP::Get.new(uri)
          req["Authorization"] = "Bearer #{@credential}"
          req["Accept"] = "application/json"
          http.request(req)
        end

        if res.code.to_i == 429 && !retried_429
          retried_429 = true
          sleep 2
          raise Retry429
        end
        return nil unless res.code.to_i == 200

        res.body
      rescue Retry429
        retry
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
        unless retried_timeout
          retried_timeout = true
          retry
        end
        nil
      rescue StandardError
        nil
      end
    end

    Retry429 = Class.new(StandardError)
    private_constant :Retry429
  end

  class << self
    def available?(credential) = credential.present?
    def capabilities = %w[resolver fingerprint performer]
    def trusted_hosts = %w[theporndb.net]

    # Pure fingerprint lookup (FINGERPRINT capability) — the host calls this directly
    # for auto-resolve and owns the throttle/stamp itself, so this method has no side
    # effects and is safe to call repeatedly. Self-stamps source_key since ResolveJob's
    # automatic multi-source merge has no per-source bookkeeping of its own (unlike
    # Identify's Apply path, which merges source_key explicitly from the picked connector).
    def fingerprint_match(video_file, credential)
      return {} if credential.blank?
      return {} if video_file.phash.blank?

      client = Client.new(credential)
      body = client.get("/scenes?hash=#{CGI.escape(video_file.phash)}&hashType=PHASH")
      return {} unless body

      candidate = results(body).find { |s| duration_agrees?(s, video_file.duration) }
      candidate ? map_scene(candidate).merge(source_key: "tpdb") : {}
    rescue StandardError
      {}
    end

    # Manual resolve entry for the Identify panel's retry action: tries the pure
    # fingerprint match first, then falls back to URL verify and free-text parse-search.
    def resolve(video_file, credential)
      return {} if credential.blank?

      data = fingerprint_match(video_file, credential)
      if data.empty?
        scene = video_file.scene
        client = Client.new(credential)
        data = by_url(scene, client)
        data = by_parse_search(scene, video_file, client) if data.empty?
      end
      data.present? ? data.merge(source_key: "tpdb") : data
    rescue StandardError
      {}
    end

    # Free-text scene search for the Identify panel — same `?parse=` endpoint
    # the resolver's parse-search fallback uses, minus the guard: here a human
    # picks the right candidate from the list, so every mapped result is
    # returned as-is. The host does NOT stamp source_key for connector plugins,
    # so it's merged in here.
    def search(term, credential)
      return [] if credential.blank? || term.blank?

      client = Client.new(credential)
      body = client.get("/scenes?parse=#{CGI.escape(term)}")
      return [] unless body

      results(body).map { |s| map_scene(s).merge(source_key: "tpdb") }
    rescue StandardError
      []
    end

    # Full scene detail by id — the Identify panel's Apply button re-fetches the
    # candidate the user picked in full (search results are otherwise complete
    # enough already, but this keeps applied data fresh and is one call).
    def fetch(source_id, credential)
      return nil if credential.blank? || source_id.blank?

      client = Client.new(credential)
      body = client.get("/scenes/#{CGI.escape(source_id)}")
      return nil unless body

      scene = JSON.parse(body)["data"]
      scene.is_a?(Hash) ? map_scene(scene) : nil
    rescue StandardError
      nil
    end

    # Free-text performer search for the performer Identify panel — same idiom
    # as scene search: a human picks the right candidate from the list, so
    # every mapped result is returned as-is, no duration/title guard needed.
    def search_performers(term, credential)
      return [] if credential.blank? || term.blank?

      client = Client.new(credential)
      body = client.get("/performers?q=#{CGI.escape(term)}")
      return [] unless body

      results(body).map { |p| map_performer(p) }
    rescue StandardError
      []
    end

    # Full performer detail by id — used by the Identify panel's "Confirm"
    # action to enrich a comment-mined suggestion once it carries a
    # source_performer_id.
    def fetch_performer(source_id, credential)
      return nil if credential.blank? || source_id.blank?

      client = Client.new(credential)
      body = client.get("/performers/#{CGI.escape(source_id)}")
      return nil unless body

      performer = JSON.parse(body)["data"]
      performer.is_a?(Hash) ? map_performer(performer) : nil
    rescue StandardError
      nil
    end

    # The canonical performer's known aliases — used by the refresh action to
    # fill-only performer_aliases. [] on no credential/id, no body, or any error.
    def fetch_performer_aliases(source_id, credential)
      return [] if credential.blank? || source_id.blank?

      client = Client.new(credential)
      body = client.get("/performers/#{CGI.escape(source_id)}")
      return [] unless body

      performer = JSON.parse(body)["data"]
      return [] unless performer.is_a?(Hash)

      canonical = performer["parent"].is_a?(Hash) ? performer["parent"] : performer
      Array(canonical["aliases"])
    rescue StandardError
      []
    end

    # The canonical performer's poster gallery, for the photo picker. Poster
    # URLs ordered as TPDB ranks them. [] on no credential/id, no body, or any error.
    def fetch_performer_posters(source_id, credential)
      return [] if credential.blank? || source_id.blank?

      client = Client.new(credential)
      body = client.get("/performers/#{CGI.escape(source_id)}")
      return [] unless body

      performer = JSON.parse(body)["data"]
      return [] unless performer.is_a?(Hash)

      canonical = performer["parent"].is_a?(Hash) ? performer["parent"] : performer
      Array(canonical["posters"]).sort_by { |p| p["order"] || 0 }.filter_map { |p| p["url"].presence }
    rescue StandardError
      []
    end

    # Performer search by name, for comment-mined candidates. Returns the top
    # match's TPDB id, or nil on no match/no credential/any failure.
    def find_performer_id(name, credential)
      return nil if credential.blank?

      client = Client.new(credential)
      body = client.get("/performers?q=#{CGI.escape(name)}")
      return nil unless body

      results(body).first&.dig("id")
    rescue StandardError
      nil
    end

    private

    def by_url(scene, client)
      return {} if scene.webpage_url.blank?

      body = client.get("/scenes?parse=#{CGI.escape(parse_terms(scene.webpage_url))}")
      return {} unless body

      ours = normalize_url(scene.webpage_url)
      candidate = results(body).find { |s| normalize_url(s["url"]) == ours }
      candidate ? map_scene(candidate) : {}
    end

    # Last-resort fallback for files with no phash hit and no URL match: search TPDB
    # with a cleaned title/filename and accept a candidate ONLY under a strong guard
    # — duration agreement (±#{PARSE_SEARCH_DURATION_TOLERANCE}s) when we know the
    # file's duration, else a near-exact normalized title match. Needed because the
    # free-text search is fuzzy-ranked, not filtered: a generic title can return ~20
    # loosely related candidates (verified live, see docs/tpdb-api.md).
    def by_parse_search(scene, video_file, client)
      term = ::Metadata::SearchTerm.for(scene)
      return {} if term.blank?

      body = client.get("/scenes?parse=#{CGI.escape(term)}")
      return {} unless body

      list = results(body)
      candidate = if video_file.duration.present?
        list.find { |s| duration_agrees?(s, video_file.duration, tolerance: PARSE_SEARCH_DURATION_TOLERANCE) }
      else
        normalized = normalize_title(term)
        list.find { |s| normalize_title(s["title"]) == normalized }
      end
      candidate ? map_scene(candidate) : {}
    end

    def results(body)
      parsed = JSON.parse(body)
      Array(parsed["data"])
    rescue JSON::ParserError
      []
    end

    # The scene's own duration or any of its PHASH fingerprint durations must land
    # within tolerance of the file — the site's stated runtime and the fingerprinted
    # encode can differ, so we accept either.
    def duration_agrees?(scene, file_duration, tolerance: DURATION_TOLERANCE)
      return false if file_duration.nil?

      candidates = [ scene["duration"] ]
      candidates += Array(scene["hashes"]).select { |h| h["type"] == "PHASH" }.map { |h| h["duration"] }
      candidates.compact.any? { |d| (d.to_f - file_duration).abs <= tolerance }
    end

    def normalize_title(str)
      str.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squeeze(" ").strip
    end

    def map_scene(scene)
      performers = Array(scene["performers"]).map { |p| map_performer(p) }
      {
        title: scene["title"],
        description: scene["description"],
        release_date: parse_date(scene["date"]),
        webpage_url: scene["url"],
        studio_name: scene.dig("site", "name"),
        tag_names: Array(scene["tags"]).filter_map { |t| t["name"] },
        performer_names: performers.filter_map { |p| p[:name] },
        source_id: scene["id"].to_s,
        performers: performers,
        duration: scene["duration"],
        # ponytail: `image` (the site's own hosted still) over `poster` (TPDB's
        # own watermarked crop) when both exist — only used for the Identify
        # panel's display, never persisted.
        cover_url: scene["image"].presence || scene["poster"].presence
      }
    end

    # Prefer TPDB's canonical parent performer (stable identity + richer bio) over the
    # per-site appearance. Either way `canonical` is a complete performer record.
    # ponytail: maps the `image` field only; add a posters[] fallback if a real
    # performer ever turns up without one.
    def map_performer(performer)
      canonical = performer["parent"].is_a?(Hash) ? performer["parent"] : performer
      extra = canonical["extras"] || canonical["extra"] || {}
      {
        name: canonical["name"],
        source_id: canonical["id"].to_s,
        image_url: canonical["image"].presence,
        face_image_url: canonical["face"].presence,
        birthdate: parse_date(extra["birthday"]),
        country: extra["nationality"].presence,
        bio: canonical["bio"].presence,
        disambiguation: canonical["disambiguation"].presence,
        full_name: canonical["full_name"].presence,
        gender: extra["gender"].presence,
        ethnicity: extra["ethnicity"].presence,
        birthplace: extra["birthplace"].presence,
        astrology: extra["astrology"].presence,
        hair_color: extra["hair_colour"].presence,
        eye_color: extra["eye_colour"].presence,
        height: extra["height"].presence,
        weight: extra["weight"].presence,
        measurements: extra["measurements"].presence,
        cup_size: extra["cupsize"].presence,
        waist: extra["waist"].presence,
        hips: extra["hips"].presence,
        tattoos: extra["tattoos"].presence,
        piercings: extra["piercings"].presence,
        fake_boobs: cast_bool(extra["fake_boobs"]),
        same_sex_only: cast_bool(extra["same_sex_only"]),
        career_start_year: extra["career_start_year"].presence&.to_i,
        career_end_year: extra["career_end_year"].presence&.to_i,
        deathday: parse_date(extra["deathday"])
      }
    end

    def cast_bool(value)
      value.present? ? ActiveModel::Type::Boolean.new.cast(value) : nil
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value)
    rescue ArgumentError
      nil
    end

    # Build a parse-search string from a scene URL: the site's short host plus the last
    # path segment (the slug) with separators turned into spaces. A malformed URL raises
    # up to resolve's rescue (→ {}), so no local guard needed.
    def parse_terms(url)
      uri = URI.parse(url)
      host = uri.host.sub(/\Awww\./, "").split(".").first
      slug = uri.path.to_s.split("/").reject(&:empty?).last.to_s
      "#{host} #{slug.tr('-_', ' ')}".strip
    end

    def normalize_url(url)
      uri = URI.parse(url)
      host = uri.host.to_s.downcase.sub(/\Awww\./, "")
      "#{host}#{uri.path.to_s.chomp('/').downcase}"
    end
  end
end

Tpdb
