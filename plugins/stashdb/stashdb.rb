require "net/http"
require "uri"
require "json"

# StashDB (stashdb.org) connector — a clean-room consumer of the public stash-box
# GraphQL API (no stash/stash-box source referenced or copied; queries below are
# written from scratch against the documented schema, see docs/stashdb-api.md).
# Two resolve strategies, tried in order:
#   (a) fingerprint match — XVault's OSHASH/PHASH sent as a batch to
#       findScenesBySceneFingerprints; confirmed with a duration agreement (±5s)
#       against either the candidate's own duration or any of its fingerprint
#       durations, to guard against hash collisions.
#   (b) free-text search — cleaned-title fallback, mirroring TPDB's parse-search
#       strategy, tried only when fingerprint match comes up empty.
# No by_url strategy: StashDB's scene `urls` point at studio pages, not tube
# pages, so there's nothing to verify our scene's webpage_url against.
# #resolve never raises and returns {} on any failure, missing credential, throttle,
# or no match. See docs/stashdb-api.md for the (verified live) API surface.
#
# This file is `instance_eval`'d inside the host XVault process, so referencing
# ActiveSupport's blank?/present?/presence and Time.current/Integer#hours/#ago is
# safe — they're already loaded in the same process, not a dependency this file ships.
class Stashdb
  BASE = "https://stashdb.org/graphql".freeze
  DURATION_TOLERANCE = 5 # seconds; ponytail: the disambiguation knob, widen if hits are missed
  SEARCH_DURATION_TOLERANCE = 10 # seconds; wider than fingerprint — free-text search is fuzzier, needs a stronger guard

  FIND_BY_FINGERPRINTS_QUERY = <<~GRAPHQL.freeze
    query FindByFP($fingerprints: [[FingerprintQueryInput!]!]!) {
      findScenesBySceneFingerprints(fingerprints: $fingerprints) {
        id title details release_date duration
        urls { url }
        studio { name }
        tags { name }
        images { url }
        performers { as performer { id name } }
        fingerprints { hash algorithm duration }
      }
    }
  GRAPHQL

  SEARCH_SCENES_QUERY = <<~GRAPHQL.freeze
    query Search($term: String!, $per_page: Int) {
      searchScenes(term: $term, page: 1, per_page: $per_page) {
        count
        scenes { id title details release_date duration urls { url } studio { name } tags { name } images { url } performers { as performer { id name } } }
      }
    }
  GRAPHQL

  FIND_SCENE_QUERY = <<~GRAPHQL.freeze
    query FindScene($id: ID!) {
      findScene(id: $id) {
        id title details release_date duration director code
        urls { url site { name } }
        studio { id name }
        tags { id name }
        images { url }
        performers { as performer { id name } }
      }
    }
  GRAPHQL

  SEARCH_PERFORMERS_QUERY = <<~GRAPHQL.freeze
    query SearchP($term: String!, $per_page: Int) {
      searchPerformers(term: $term, page: 1, per_page: $per_page) {
        performers { id name disambiguation aliases gender birth_date country images { url } }
      }
    }
  GRAPHQL

  FIND_PERFORMER_QUERY = <<~GRAPHQL.freeze
    query FindP($id: ID!) {
      findPerformer(id: $id) {
        id name disambiguation aliases gender birth_date death_date country ethnicity
        eye_color hair_color height cup_size band_size waist_size hip_size
        career_start_year career_end_year
        tattoos { location description } piercings { location description }
        images { url }
      }
    }
  GRAPHQL

  # Thin GraphQL POST wrapper: 10s timeouts, one retry on timeout, one retry after a 2s
  # backoff on 429. Returns the parsed `data` Hash on 200 with a present `data`, nil on
  # anything else (null `data`, GraphQL errors, non-200, timeout). Never raises.
  class Client
    def initialize(credential)
      @credential = credential
    end

    def query(document, variables = {})
      uri = URI(BASE)
      retried_timeout = false
      retried_429 = false
      begin
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) do |http|
          req = Net::HTTP::Post.new(uri)
          req["ApiKey"] = @credential
          req["Content-Type"] = "application/json"
          req["Accept"] = "application/json"
          req.body = JSON.generate(query: document, variables: variables)
          http.request(req)
        end

        if res.code.to_i == 429 && !retried_429
          retried_429 = true
          sleep 2
          raise Retry429
        end
        return nil unless res.code.to_i == 200

        JSON.parse(res.body)["data"].presence
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
    # ponytail: image embed allowlist — verify/adjust if StashDB ever serves images
    # from another CDN host.
    def trusted_hosts = %w[stashdb.org cdn.stashdb.org]

    # Auto-resolve entry (FINGERPRINT capability). Self-stamps source_key since
    # ResolveJob's automatic multi-source merge has no per-source bookkeeping of
    # its own (unlike Identify's Apply path, which merges source_key explicitly
    # from the picked connector).
    def resolve(video_file, credential)
      return {} if credential.blank?

      scene = video_file.scene
      return {} if throttled?(scene)

      scene.update_column(:resolve_last_attempt_at, Time.current)

      client = Client.new(credential)
      data = by_fingerprint(video_file, client)
      data = by_search(scene, video_file, client) if data.empty?
      data.present? ? data.merge(source_key: "stashdb") : data
    rescue StandardError
      {}
    end

    # Free-text scene search for the Identify panel. A human picks the right
    # candidate from the list, so every mapped result is returned as-is. The
    # host does NOT stamp source_key for connector plugins, so it's merged in here.
    def search(term, credential)
      return [] if credential.blank? || term.blank?

      client = Client.new(credential)
      data = client.query(SEARCH_SCENES_QUERY, term: term, per_page: 25)
      return [] unless data

      Array(data.dig("searchScenes", "scenes")).map { |s| map_scene(s).merge(source_key: "stashdb") }
    rescue StandardError
      []
    end

    # Full scene detail by id — the Identify panel's Apply button re-fetches the
    # candidate the user picked in full.
    def fetch(source_id, credential)
      return nil if credential.blank? || source_id.blank?

      client = Client.new(credential)
      data = client.query(FIND_SCENE_QUERY, id: source_id)
      return nil unless data

      scene = data["findScene"]
      scene.is_a?(Hash) ? map_scene(scene) : nil
    rescue StandardError
      nil
    end

    # Free-text performer search for the performer Identify panel — same idiom
    # as scene search: a human picks the right candidate, so every mapped
    # result is returned as-is, no duration/title guard needed.
    def search_performers(term, credential)
      return [] if credential.blank? || term.blank?

      client = Client.new(credential)
      data = client.query(SEARCH_PERFORMERS_QUERY, term: term, per_page: 25)
      return [] unless data

      Array(data.dig("searchPerformers", "performers")).map { |p| map_performer(p) }
    rescue StandardError
      []
    end

    # Full performer detail by id — used by the Identify panel's "Confirm"
    # action to enrich a comment-mined suggestion once it carries a
    # source_performer_id.
    def fetch_performer(source_id, credential)
      return nil if credential.blank? || source_id.blank?

      client = Client.new(credential)
      data = client.query(FIND_PERFORMER_QUERY, id: source_id)
      return nil unless data

      performer = data["findPerformer"]
      performer.is_a?(Hash) ? map_performer(performer) : nil
    rescue StandardError
      nil
    end

    # StashDB's known aliases for this performer — used by the refresh action
    # to fill-only performer_aliases. [] on no credential/id, no data, or any error.
    def fetch_performer_aliases(source_id, credential)
      return [] if credential.blank? || source_id.blank?

      client = Client.new(credential)
      data = client.query(FIND_PERFORMER_QUERY, id: source_id)
      return [] unless data

      performer = data["findPerformer"]
      return [] unless performer.is_a?(Hash)

      Array(performer["aliases"])
    rescue StandardError
      []
    end

    # This performer's photo gallery, for the photo picker. [] on no
    # credential/id, no data, or any error.
    def fetch_performer_posters(source_id, credential)
      return [] if credential.blank? || source_id.blank?

      client = Client.new(credential)
      data = client.query(FIND_PERFORMER_QUERY, id: source_id)
      return [] unless data

      performer = data["findPerformer"]
      return [] unless performer.is_a?(Hash)

      Array(performer["images"]).filter_map { |i| i["url"].presence }
    rescue StandardError
      []
    end

    # Performer search by name, for comment-mined candidates. Returns the top
    # match's StashDB id, or nil on no match/no credential/any failure.
    def find_performer_id(name, credential)
      return nil if credential.blank?

      client = Client.new(credential)
      data = client.query(SEARCH_PERFORMERS_QUERY, term: name, per_page: 25)
      return nil unless data

      Array(data.dig("searchPerformers", "performers")).first&.dig("id")
    rescue StandardError
      nil
    end

    private

    def throttled?(scene)
      scene.source_id.nil? &&
        scene.resolve_last_attempt_at.present? &&
        scene.resolve_last_attempt_at > 24.hours.ago
    end

    # Batch fingerprint match — one file, so one inner list; the result is
    # index-aligned to the input outer list, so result[0] is our candidates.
    # Skip a hash type XVault doesn't have (a nil oshash or phash).
    def by_fingerprint(video_file, client)
      fingerprints = []
      fingerprints << { hash: video_file.oshash, algorithm: "OSHASH" } if video_file.oshash.present?
      fingerprints << { hash: video_file.phash, algorithm: "PHASH" } if video_file.phash.present?
      return {} if fingerprints.empty?

      data = client.query(FIND_BY_FINGERPRINTS_QUERY, fingerprints: [ fingerprints ])
      return {} unless data

      candidates = Array(data["findScenesBySceneFingerprints"]).first
      candidate = Array(candidates).find { |s| duration_agrees?(s, video_file.duration) }
      candidate ? map_scene(candidate) : {}
    end

    # Last-resort fallback for files with no fingerprint hit: search StashDB with a
    # cleaned title/filename and accept a candidate ONLY under a strong guard —
    # duration agreement (±#{SEARCH_DURATION_TOLERANCE}s) when we know the file's
    # duration, else a near-exact normalized title match. searchScenes is fuzzy-ranked,
    # not filtered, so a generic title can return several loosely related candidates.
    def by_search(scene, video_file, client)
      term = ::Metadata::SearchTerm.for(scene)
      return {} if term.blank?

      data = client.query(SEARCH_SCENES_QUERY, term: term, per_page: 25)
      return {} unless data

      list = Array(data.dig("searchScenes", "scenes"))
      candidate = if video_file.duration.present?
        list.find { |s| duration_agrees?(s, video_file.duration, tolerance: SEARCH_DURATION_TOLERANCE) }
      else
        normalized = normalize_title(term)
        list.find { |s| normalize_title(s["title"]) == normalized }
      end
      candidate ? map_scene(candidate) : {}
    end

    # The scene's own duration or any of its fingerprint durations must land within
    # tolerance of the file — StashDB has no server-side duration filter on the
    # fingerprint query, so this is our only guard against a hash collision.
    def duration_agrees?(scene, file_duration, tolerance: DURATION_TOLERANCE)
      return false if file_duration.nil?

      candidates = [ scene["duration"] ]
      candidates += Array(scene["fingerprints"]).map { |f| f["duration"] }
      candidates.compact.any? { |d| (d.to_f - file_duration).abs <= tolerance }
    end

    def normalize_title(str)
      str.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squeeze(" ").strip
    end

    def map_scene(scene)
      performers = Array(scene["performers"]).filter_map { |p| p["performer"] }
      {
        title: scene["title"],
        description: scene["details"],
        release_date: parse_date(scene["release_date"]),
        webpage_url: scene["urls"]&.first&.dig("url"),
        studio_name: scene.dig("studio", "name"),
        tag_names: Array(scene["tags"]).filter_map { |t| t["name"] },
        performer_names: performers.filter_map { |p| p["name"] },
        source_id: scene["id"].to_s,
        performers: performers.map { |p| { name: p["name"], source_id: p["id"].to_s } },
        duration: scene["duration"],
        # ponytail: display only for the Identify panel, never persisted.
        cover_url: scene["images"]&.first&.dig("url")
      }
    end

    # StashDB performer fields are flat strings (no per-site vs. canonical split like
    # TPDB's parent/child performers — StashDB has one record per performer). Emits
    # the same key set as TPDB's map_performer so Merger#enrich_performer has nothing
    # source-specific to special-case; fields StashDB's schema simply doesn't carry
    # (bio, face_image_url, full_name, birthplace, astrology, weight, measurements,
    # fake_boobs, same_sex_only) are always nil here.
    def map_performer(performer)
      {
        name: performer["name"],
        source_id: performer["id"].to_s,
        image_url: performer["images"]&.first&.dig("url").presence,
        face_image_url: nil,
        birthdate: parse_date(performer["birth_date"]),
        country: performer["country"].presence,
        bio: nil,
        disambiguation: performer["disambiguation"].presence,
        full_name: nil,
        gender: performer["gender"].presence,
        ethnicity: performer["ethnicity"].presence,
        birthplace: nil,
        astrology: nil,
        hair_color: performer["hair_color"].presence,
        eye_color: performer["eye_color"].presence,
        height: performer["height"].presence,
        weight: nil,
        measurements: nil,
        cup_size: performer["cup_size"].presence,
        waist: performer["waist_size"].presence,
        hips: performer["hip_size"].presence,
        tattoos: join_body_mods(performer["tattoos"]),
        piercings: join_body_mods(performer["piercings"]),
        fake_boobs: nil,
        same_sex_only: nil,
        career_start_year: performer["career_start_year"].presence&.to_i,
        career_end_year: performer["career_end_year"].presence&.to_i,
        deathday: parse_date(performer["death_date"])
      }
    end

    # StashDB models tattoos/piercings as structured {location, description} entries,
    # unlike TPDB's single free-text string — join into one string so Merger sees the
    # same flat `tattoos`/`piercings` key contract regardless of source.
    def join_body_mods(entries)
      Array(entries)
        .filter_map { |e| [ e["location"], e["description"] ].reject(&:blank?).join(": ").presence }
        .join("; ")
        .presence
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value)
    rescue ArgumentError
      nil
    end
  end
end

Stashdb
