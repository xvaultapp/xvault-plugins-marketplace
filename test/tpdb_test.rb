# Pure minitest, no Gemfile: `ruby test/tpdb_test.rb` must pass with system
# Ruby alone. tpdb.rb references ActiveSupport's blank?/present?/presence and
# ::Metadata::SearchTerm — those only really exist inside the host XVault process
# (docs/scraper-plugin-authoring.md, "Connector escape hatch"). Here we hand-roll
# just enough of each to drive the plugin's pure logic without a network call or
# a Rails boot. Scene/VideoFile stand-ins are plain classes (no ActiveRecord) —
# resolve/fingerprint_match only ever touch the handful of attributes below. The
# resolve throttle itself now lives in the host (core), not here.
require "minitest/autorun"
require "json"
require "uri"
require "date"

class Object
  def blank? = respond_to?(:empty?) ? !!empty? : !self
  def present? = !blank?
  def presence = present? ? self : nil
end

# Minimal stand-in for the real ActiveModel::Type::Boolean tpdb.rb's cast_bool
# uses to type-cast TPDB's stringy booleans ("false"/"true") — kept as a real
# reference (not hand-rolled inline) for fidelity to the ported original.
module ActiveModel
  module Type
    class Boolean
      FALSE_VALUES = [ false, 0, "0", "f", "F", "false", "FALSE", "off", "OFF" ].freeze
      def cast(value) = !FALSE_VALUES.include?(value)
    end
  end
end

module Metadata
  # Minimal stand-in for the real regex-based cleaner (app/services/metadata/search_term.rb)
  # — just enough to prove tpdb.rb's parse-search fallback searches with a cleaned term,
  # not the raw release-junk title.
  module SearchTerm
    RELEASE_JUNK = /\b(?:\d{3,4}p|[hx]\.?26[45]|web[-.]?(?:dl|rip))\b/i
    DATE_FRAGMENT = /\b\d{4}[.\-]\d{2}[.\-]\d{2}\b/

    def self.for(scene)
      cleaned = scene.title.to_s.gsub(DATE_FRAGMENT, " ").gsub(RELEASE_JUNK, " ").gsub(/[._-]/, " ")
      cleaned.squeeze(" ").strip
    end
  end
end

PLUGIN_PATH = File.expand_path("../plugins/tpdb/tpdb.rb", __dir__)
TPDB = Object.new.instance_eval(File.read(PLUGIN_PATH), PLUGIN_PATH)
FIXTURE = File.read(File.expand_path("../plugins/tpdb/fixtures/tpdb_phash_search.json", __dir__))

class FakeScene
  attr_accessor :title, :webpage_url, :source_id, :resolve_last_attempt_at

  def initialize(title: "orig", webpage_url: nil, source_id: nil, resolve_last_attempt_at: nil)
    @title = title
    @webpage_url = webpage_url
    @source_id = source_id
    @resolve_last_attempt_at = resolve_last_attempt_at
  end

  def update_column(attr, value) = public_send("#{attr}=", value)
end

class FakeVideoFile
  attr_accessor :scene, :phash, :duration

  def initialize(scene:, phash: "abcdef0123456789", duration: 1802)
    @scene = scene
    @phash = phash
    @duration = duration
  end
end

class TpdbTest < Minitest::Test
  # Bypasses the real Client#get (network) entirely with a canned body, and
  # records the paths requested — follows eporner_test.rb's stubbing style,
  # adapted since Client is instantiated internally rather than injected.
  def stub_client_get(body)
    calls = []
    original = TPDB::Client.instance_method(:get)
    TPDB::Client.define_method(:get) { |path| calls << path; body }
    yield calls
  ensure
    TPDB::Client.define_method(:get, original)
  end

  def make_video_file(**opts)
    FakeVideoFile.new(scene: FakeScene.new(**opts.slice(:title, :webpage_url, :source_id, :resolve_last_attempt_at)),
                       **opts.slice(:phash, :duration))
  end

  def test_declares_the_connector_interface
    assert_equal true, TPDB.available?("k")
    assert_equal false, TPDB.available?(nil)
    assert_equal %w[resolver fingerprint performer], TPDB.capabilities
    assert_equal %w[theporndb.net], TPDB.trusted_hosts
    assert_respond_to TPDB, :search
    assert_respond_to TPDB, :fetch
    assert_respond_to TPDB, :resolve
  end

  # --- fingerprint_match: pure lookup, no throttle, no stamp ---

  def test_fingerprint_match_maps_a_hit_and_stamps_source_key_when_duration_agrees
    vf = make_video_file(duration: 1802)
    data = stub_client_get(FIXTURE) { TPDB.fingerprint_match(vf, "k") }

    assert_equal "Test Scene Title", data[:title]
    assert_equal "scene-uuid-0001", data[:source_id]
    assert_equal [ "Tag One", "Tag Two" ], data[:tag_names]
    assert_equal [ "Jane Canonical", "Kate Noparent" ], data[:performer_names]
    assert_equal "tpdb", data[:source_key]
  end

  def test_fingerprint_match_rejects_a_hit_when_duration_disagrees_beyond_tolerance
    vf = make_video_file(duration: 1600)
    assert_equal({}, stub_client_get(FIXTURE) { TPDB.fingerprint_match(vf, "k") })
  end

  def test_fingerprint_match_returns_empty_hash_without_a_credential
    vf = make_video_file
    assert_equal({}, stub_client_get(FIXTURE) { TPDB.fingerprint_match(vf, nil) })
  end

  def test_fingerprint_match_never_stamps_or_otherwise_touches_the_scene
    vf = make_video_file(duration: 1802)
    stub_client_get(FIXTURE) { TPDB.fingerprint_match(vf, "k") }

    assert_nil vf.scene.resolve_last_attempt_at
  end

  # --- resolve: phash hit, using the ported fixture ---

  def test_resolve_maps_a_phash_hit_and_stamps_source_key_when_duration_agrees
    vf = make_video_file(duration: 1802)
    data = stub_client_get(FIXTURE) { TPDB.resolve(vf, "k") }

    assert_equal "Test Scene Title", data[:title]
    assert_equal "scene-uuid-0001", data[:source_id]
    assert_equal [ "Tag One", "Tag Two" ], data[:tag_names]
    assert_equal [ "Jane Canonical", "Kate Noparent" ], data[:performer_names]
    assert_equal "tpdb", data[:source_key]
    assert_nil vf.scene.resolve_last_attempt_at
  end

  def test_resolve_prefers_the_canonical_parent_performer
    vf = make_video_file
    data = stub_client_get(FIXTURE) { TPDB.resolve(vf, "k") }

    jane = data[:performers].find { |p| p[:source_id] == "perf-canonical-1" }
    assert_equal "Jane Canonical", jane[:name]
    assert_equal Date.new(1990, 3, 22), jane[:birthdate]
    assert_equal "American", jane[:country]

    kate = data[:performers].find { |p| p[:source_id] == "perf-noparent-2" }
    assert_equal "Kate Noparent", kate[:name]
    assert_equal "Canadian", kate[:country]
  end

  def test_resolve_rejects_a_phash_hit_when_duration_disagrees_beyond_tolerance
    vf = make_video_file(duration: 1600)
    assert_equal({}, stub_client_get(FIXTURE) { TPDB.resolve(vf, "k") })
  end

  def test_resolve_url_verify_matches_ignoring_scheme_and_query
    vf = make_video_file(phash: nil, webpage_url: "https://www.TestStudio.example/scene/1/?utm=x")
    data = stub_client_get(FIXTURE) { TPDB.resolve(vf, "k") }

    assert_equal "scene-uuid-0001", data[:source_id]
  end

  def test_resolve_returns_empty_hash_without_a_credential
    vf = make_video_file
    assert_equal({}, stub_client_get(FIXTURE) { TPDB.resolve(vf, nil) })
  end

  # --- search: Identify panel, self-stamps source_key (host does not) ---

  def test_search_maps_results_and_stamps_source_key
    results = stub_client_get(FIXTURE) { TPDB.search("orig", "k") }

    assert_equal [ "Test Scene Title" ], results.map { |r| r[:title] }
    assert_equal [ "tpdb" ], results.map { |r| r[:source_key] }
  end

  def test_search_returns_empty_array_without_a_credential_a_blank_term_or_a_nil_body
    assert_equal [], stub_client_get(FIXTURE) { TPDB.search("orig", nil) }
    assert_equal [], stub_client_get(FIXTURE) { TPDB.search("", "k") }
    assert_equal [], stub_client_get(nil) { TPDB.search("orig", "k") }
  end

  # --- fetch: Identify Apply re-fetch, full scene detail by id ---

  def test_fetch_maps_a_hash_detail_payload_and_returns_nil_otherwise
    body = { data: { "id" => "s1", "title" => "Detail Scene", "site" => {}, "tags" => [], "performers" => [] } }.to_json
    assert_equal "Detail Scene", stub_client_get(body) { TPDB.fetch("s1", "k") }[:title]

    # A list-shaped body (array under "data") must not be mistaken for a detail payload.
    assert_nil stub_client_get(FIXTURE) { TPDB.fetch("s1", "k") }
    assert_nil stub_client_get(body) { TPDB.fetch(nil, "k") }
    assert_nil stub_client_get(body) { TPDB.fetch("s1", nil) }
  end

  # --- map_performer: full scalar profile with correctly typed values ---

  def test_fetch_performer_maps_bio_disambiguation_and_the_full_scalar_profile
    body = {
      data: {
        "id" => "p1", "name" => "Anna Foxx", "full_name" => "Krystal Boyd",
        "bio" => "A bio.", "disambiguation" => "the one from Ohio",
        "extras" => {
          "gender" => "Female", "hair_colour" => "Blonde", "cupsize" => "30B",
          "fake_boobs" => "false", "career_start_year" => "2011", "deathday" => "2020-05-05"
        }
      }
    }.to_json
    data = stub_client_get(body) { TPDB.fetch_performer("p1", "k") }

    assert_equal "A bio.", data[:bio]
    assert_equal "the one from Ohio", data[:disambiguation]
    assert_equal "Krystal Boyd", data[:full_name]
    assert_equal "Female", data[:gender]
    assert_equal "Blonde", data[:hair_color]
    assert_equal "30B", data[:cup_size]
    assert_equal false, data[:fake_boobs]
    assert_equal 2011, data[:career_start_year]
    assert_equal Date.new(2020, 5, 5), data[:deathday]
  end

  # --- parse-search fallback: last resort, strong duration/title guard ---

  def test_resolve_parse_search_fallback_searches_with_the_cleaned_scene_title
    vf = make_video_file(title: "My Scene.2021-06-15.1080p.WEB-DL-x264", phash: nil, webpage_url: nil, duration: nil)
    calls = nil
    stub_client_get(JSON.generate({ data: [] })) { |c| calls = c; TPDB.resolve(vf, "k") }

    assert_equal [ "/scenes?parse=My+Scene" ], calls
  end

  def test_resolve_parse_search_fallback_accepts_within_widened_tolerance
    body = JSON.generate({ data: [
      { "id" => "wrong", "title" => "Other", "duration" => 1000, "site" => {}, "tags" => [], "performers" => [] },
      { "id" => "right", "title" => "Orig", "duration" => 1808, "site" => {}, "tags" => [], "performers" => [] }
    ] })
    vf = make_video_file(title: "Orig", phash: nil, webpage_url: nil, duration: 1800)

    assert_equal "right", stub_client_get(body) { TPDB.resolve(vf, "k") }[:source_id]
  end

  def test_resolve_parse_search_fallback_rejects_beyond_widened_tolerance
    body = JSON.generate({ data: [ { "id" => "far", "title" => "Orig", "duration" => 1500, "site" => {}, "tags" => [], "performers" => [] } ] })
    vf = make_video_file(title: "Orig", phash: nil, webpage_url: nil, duration: 1800)

    assert_equal({}, stub_client_get(body) { TPDB.resolve(vf, "k") })
  end

  # --- real Client HTTP behavior, swapping Net::HTTP.start (no network) ---

  def fake_response(code, body = "")
    Struct.new(:code, :body).new(code, body)
  end

  def with_net_http_start(fake)
    fake_http = Object.new
    fake_http.define_singleton_method(:request) { |_req| fake.call }
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*_a, **_k, &blk| blk.call(fake_http) }
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def test_client_returns_the_body_on_200
    client = TPDB::Client.new("k")
    with_net_http_start(->(*_a, **_k) { fake_response("200", '{"data":[]}') }) do
      assert_equal '{"data":[]}', client.get("/scenes")
    end
  end

  def test_client_retries_once_after_a_429_backoff_then_succeeds
    client = TPDB::Client.new("k")
    slept = []
    client.define_singleton_method(:sleep) { |seconds| slept << seconds }
    seq = [ fake_response("429"), fake_response("200", "ok") ]
    with_net_http_start(->(*_a, **_k) { seq.shift }) do
      assert_equal "ok", client.get("/scenes")
    end
    assert_equal [ 2 ], slept
  end

  def test_client_retries_once_on_timeout_then_returns_nil
    client = TPDB::Client.new("k")
    calls = 0
    with_net_http_start(->(*_a, **_k) { calls += 1; raise Net::ReadTimeout }) do
      assert_nil client.get("/scenes")
    end
    assert_equal 2, calls
  end

  def test_client_returns_nil_on_a_non_200_response
    client = TPDB::Client.new("k")
    with_net_http_start(->(*_a, **_k) { fake_response("500", "boom") }) do
      assert_nil client.get("/scenes")
    end
  end

  def test_client_gives_up_after_a_second_429
    client = TPDB::Client.new("k")
    client.define_singleton_method(:sleep) { |_seconds| nil }
    with_net_http_start(->(*_a, **_k) { fake_response("429") }) do
      assert_nil client.get("/scenes")
    end
  end

  def test_client_returns_nil_on_an_unexpected_error
    client = TPDB::Client.new("k")
    with_net_http_start(->(*_a, **_k) { raise SocketError, "no dns" }) do
      assert_nil client.get("/scenes")
    end
  end
end
