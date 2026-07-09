# Pure minitest, no Gemfile: `ruby test/stashdb_test.rb` must pass with system
# Ruby alone. stashdb.rb references ActiveSupport's blank?/present?/presence,
# Time.current, Integer#hours/#ago, and ::Metadata::SearchTerm — those only really
# exist inside the host XVault process (docs/scraper-plugin-authoring.md,
# "Connector escape hatch"). Here we hand-roll just enough of each to drive the
# plugin's pure logic without a network call or a Rails boot. Scene/VideoFile
# stand-ins are plain classes (no ActiveRecord) — resolve only ever touches the
# handful of attributes below.
require "minitest/autorun"
require "json"
require "uri"
require "date"

class Object
  def blank? = respond_to?(:empty?) ? !!empty? : !self
  def present? = !blank?
  def presence = present? ? self : nil
end

class Time
  def self.current = now
end

class Numeric
  def hours = self * 3600
end

class Integer
  def ago = Time.now - self
end

module Metadata
  # Minimal stand-in for the real regex-based cleaner (app/services/metadata/search_term.rb)
  # — just enough to prove stashdb.rb's search fallback searches with a cleaned term,
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

PLUGIN_PATH = File.expand_path("../plugins/stashdb/stashdb.rb", __dir__)
STASHDB = Object.new.instance_eval(File.read(PLUGIN_PATH), PLUGIN_PATH)
FIXTURE = File.read(File.expand_path("../plugins/stashdb/fixtures/stashdb_fingerprint_match.json", __dir__))
FIXTURE_DATA = JSON.parse(FIXTURE)["data"]
FIXTURE_SCENE = FIXTURE_DATA["findScenesBySceneFingerprints"][0][0]

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
  attr_accessor :scene, :oshash, :phash, :duration

  def initialize(scene:, oshash: "1234567890abcdef", phash: "abcdef0123456789", duration: 1802)
    @scene = scene
    @oshash = oshash
    @phash = phash
    @duration = duration
  end
end

class StashdbTest < Minitest::Test
  # Bypasses the real Client#query (network) entirely with a canned "data" Hash
  # (already parsed, same shape #query itself returns), and records the
  # documents/variables requested — follows tpdb_test's stub_client_get pattern,
  # adapted since Client is instantiated internally rather than injected.
  def stub_client_query(data)
    calls = []
    original = STASHDB::Client.instance_method(:query)
    STASHDB::Client.define_method(:query) { |document, variables = {}| calls << { document: document, variables: variables }; data }
    yield calls
  ensure
    STASHDB::Client.define_method(:query, original)
  end

  def make_video_file(**opts)
    FakeVideoFile.new(scene: FakeScene.new(**opts.slice(:title, :webpage_url, :source_id, :resolve_last_attempt_at)),
                       **opts.slice(:oshash, :phash, :duration))
  end

  def test_declares_the_connector_interface
    assert_equal true, STASHDB.available?("k")
    assert_equal false, STASHDB.available?(nil)
    assert_equal %w[resolver fingerprint performer], STASHDB.capabilities
    assert_equal %w[stashdb.org cdn.stashdb.org], STASHDB.trusted_hosts
    assert_respond_to STASHDB, :search
    assert_respond_to STASHDB, :fetch
    assert_respond_to STASHDB, :resolve
  end

  # --- resolve: fingerprint hit, using the ported fixture ---

  def test_resolve_maps_a_fingerprint_hit_and_stamps_source_key_when_duration_agrees
    vf = make_video_file(duration: 1802)
    data = stub_client_query(FIXTURE_DATA) { STASHDB.resolve(vf, "k") }

    assert_equal "Test Scene Title", data[:title]
    assert_equal "scene-uuid-0001", data[:source_id]
    assert_equal [ "Tag One", "Tag Two" ], data[:tag_names]
    assert_equal [ "Jane Canonical", "Kate Noparent" ], data[:performer_names]
    assert_equal [
      { name: "Jane Canonical", source_id: "perf-canonical-1" },
      { name: "Kate Noparent", source_id: "perf-noparent-2" }
    ], data[:performers]
    assert_equal "stashdb", data[:source_key]
  end

  def test_resolve_rejects_a_fingerprint_hit_when_duration_disagrees_beyond_tolerance
    vf = make_video_file(duration: 1600)
    assert_equal({}, stub_client_query(FIXTURE_DATA) { STASHDB.resolve(vf, "k") })
  end

  def test_resolve_returns_empty_hash_without_a_credential
    vf = make_video_file
    assert_equal({}, stub_client_query(FIXTURE_DATA) { STASHDB.resolve(vf, nil) })
  end

  # --- throttle window ---

  def test_resolve_throttle_skips_a_recent_miss_with_no_source_id
    vf = make_video_file(source_id: nil, resolve_last_attempt_at: Time.now - 3600)
    assert_equal({}, stub_client_query(FIXTURE_DATA) { STASHDB.resolve(vf, "k") })
  end

  def test_resolve_throttle_lifts_after_24h_once_resolved_or_on_first_attempt
    lifted_after_24h = make_video_file(source_id: nil, resolve_last_attempt_at: Time.now - (25 * 3600))
    already_resolved = make_video_file(source_id: "already", resolve_last_attempt_at: Time.now - 3600)
    first_attempt = make_video_file(source_id: nil, resolve_last_attempt_at: nil)

    [ lifted_after_24h, already_resolved, first_attempt ].each do |vf|
      data = stub_client_query(FIXTURE_DATA) { STASHDB.resolve(vf, "k") }
      assert_equal "scene-uuid-0001", data[:source_id]
    end
  end

  # --- search: Identify panel, self-stamps source_key (host does not) ---

  def test_search_maps_results_and_stamps_source_key
    data = { "searchScenes" => { "count" => 1, "scenes" => [ FIXTURE_SCENE ] } }
    results = stub_client_query(data) { STASHDB.search("orig", "k") }

    assert_equal [ "Test Scene Title" ], results.map { |r| r[:title] }
    assert_equal [ "stashdb" ], results.map { |r| r[:source_key] }
  end

  def test_search_returns_empty_array_without_a_credential_a_blank_term_or_nil_data
    assert_equal [], stub_client_query(FIXTURE_DATA) { STASHDB.search("orig", nil) }
    assert_equal [], stub_client_query(FIXTURE_DATA) { STASHDB.search("", "k") }
    assert_equal [], stub_client_query(nil) { STASHDB.search("orig", "k") }
  end

  # --- fetch: Identify Apply re-fetch, full scene detail by id ---

  def test_fetch_maps_a_hash_detail_payload_and_returns_nil_otherwise
    data = { "findScene" => FIXTURE_SCENE }
    assert_equal "Test Scene Title", stub_client_query(data) { STASHDB.fetch("scene-uuid-0001", "k") }[:title]

    # A null findScene (no such id) must not be mistaken for a detail payload.
    assert_nil stub_client_query({ "findScene" => nil }) { STASHDB.fetch("scene-uuid-0001", "k") }
    assert_nil stub_client_query(data) { STASHDB.fetch(nil, "k") }
    assert_nil stub_client_query(data) { STASHDB.fetch("scene-uuid-0001", nil) }
  end

  # --- map_performer: full scalar profile with correctly typed values ---

  def test_fetch_performer_maps_the_full_scalar_profile_with_correctly_typed_values
    performer = {
      "id" => "p1", "name" => "Anna Foxx", "disambiguation" => "the one from Ohio",
      "gender" => "FEMALE", "birth_date" => "1990-03-22", "death_date" => "2020-05-05",
      "country" => "United States", "ethnicity" => "CAUCASIAN",
      "eye_color" => "BLUE", "hair_color" => "BLONDE", "height" => "165",
      "cup_size" => "30B", "band_size" => "30", "waist_size" => "24", "hip_size" => "34",
      "career_start_year" => 2011, "career_end_year" => 2019,
      "tattoos" => [ { "location" => "Left wrist", "description" => "star" } ],
      "piercings" => [ { "location" => "Navel", "description" => nil } ],
      "images" => [ { "url" => "https://cdn.stashdb.org/performer/p1/main.jpg" } ]
    }
    data = stub_client_query({ "findPerformer" => performer }) { STASHDB.fetch_performer("p1", "k") }

    assert_equal "Anna Foxx", data[:name]
    assert_equal "p1", data[:source_id]
    assert_equal "the one from Ohio", data[:disambiguation]
    assert_equal "FEMALE", data[:gender]
    assert_equal Date.new(1990, 3, 22), data[:birthdate]
    assert_equal Date.new(2020, 5, 5), data[:deathday]
    assert_equal "United States", data[:country]
    assert_equal "BLONDE", data[:hair_color]
    assert_equal "165", data[:height]
    assert_equal "30B", data[:cup_size]
    assert_equal "24", data[:waist]
    assert_equal "34", data[:hips]
    assert_equal 2011, data[:career_start_year]
    assert_equal 2019, data[:career_end_year]
    assert_equal "Left wrist: star", data[:tattoos]
    assert_equal "Navel", data[:piercings]
    assert_equal "https://cdn.stashdb.org/performer/p1/main.jpg", data[:image_url]
    assert_nil data[:bio]
    assert_nil data[:face_image_url]
    assert_nil data[:full_name]
  end

  # --- search fallback: last resort, strong duration/title guard ---

  def test_resolve_search_fallback_searches_with_the_cleaned_scene_title
    vf = make_video_file(title: "My Scene.2021-06-15.1080p.WEB-DL-x264", oshash: nil, phash: nil, webpage_url: nil, duration: nil)
    calls = nil
    stub_client_query(nil) { |c| calls = c; STASHDB.resolve(vf, "k") }

    assert_equal [ "My Scene" ], calls.map { |c| c[:variables][:term] }
  end

  def test_resolve_search_fallback_accepts_within_widened_tolerance
    data = { "searchScenes" => { "scenes" => [
      { "id" => "wrong", "title" => "Other", "duration" => 1000, "urls" => [], "studio" => {}, "tags" => [], "images" => [], "performers" => [], "fingerprints" => [] },
      { "id" => "right", "title" => "Orig", "duration" => 1808, "urls" => [], "studio" => {}, "tags" => [], "images" => [], "performers" => [], "fingerprints" => [] }
    ] } }
    vf = make_video_file(title: "Orig", oshash: nil, phash: nil, webpage_url: nil, duration: 1800)

    assert_equal "right", stub_client_query(data) { STASHDB.resolve(vf, "k") }[:source_id]
  end

  def test_resolve_search_fallback_rejects_beyond_widened_tolerance
    data = { "searchScenes" => { "scenes" => [
      { "id" => "far", "title" => "Orig", "duration" => 1500, "urls" => [], "studio" => {}, "tags" => [], "images" => [], "performers" => [], "fingerprints" => [] }
    ] } }
    vf = make_video_file(title: "Orig", oshash: nil, phash: nil, webpage_url: nil, duration: 1800)

    assert_equal({}, stub_client_query(data) { STASHDB.resolve(vf, "k") })
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

  def test_client_returns_the_data_on_200
    client = STASHDB::Client.new("k")
    with_net_http_start(->(*_a, **_k) { fake_response("200", '{"data":{"findScene":{"id":"s1"}}}') }) do
      assert_equal({ "findScene" => { "id" => "s1" } }, client.query("query{findScene(id:1){id}}"))
    end
  end

  def test_client_retries_once_after_a_429_backoff_then_succeeds
    client = STASHDB::Client.new("k")
    slept = []
    client.define_singleton_method(:sleep) { |seconds| slept << seconds }
    seq = [ fake_response("429"), fake_response("200", '{"data":{"ok":true}}') ]
    with_net_http_start(->(*_a, **_k) { seq.shift }) do
      assert_equal({ "ok" => true }, client.query("query{ok}"))
    end
    assert_equal [ 2 ], slept
  end

  def test_client_retries_once_on_timeout_then_returns_nil
    client = STASHDB::Client.new("k")
    calls = 0
    with_net_http_start(->(*_a, **_k) { calls += 1; raise Net::ReadTimeout }) do
      assert_nil client.query("query{ok}")
    end
    assert_equal 2, calls
  end

  def test_client_returns_nil_on_a_non_200_response
    client = STASHDB::Client.new("k")
    with_net_http_start(->(*_a, **_k) { fake_response("500", "boom") }) do
      assert_nil client.query("query{ok}")
    end
  end

  def test_client_gives_up_after_a_second_429
    client = STASHDB::Client.new("k")
    client.define_singleton_method(:sleep) { |_seconds| nil }
    with_net_http_start(->(*_a, **_k) { fake_response("429") }) do
      assert_nil client.query("query{ok}")
    end
  end

  def test_client_returns_nil_on_an_unexpected_error
    client = STASHDB::Client.new("k")
    with_net_http_start(->(*_a, **_k) { raise SocketError, "no dns" }) do
      assert_nil client.query("query{ok}")
    end
  end
end
