# Pure minitest, no Gemfile: `ruby test/beeg_test.rb` must pass with system
# Ruby alone. beeg.rb references ::Metadata::PageFetcher /
# ::Metadata::GenericJsonLd and ActiveSupport's blank?/present? — those only
# really exist inside the host XVault process (docs/scraper-plugin-authoring.md,
# "Connector escape hatch"). Here we hand-roll just enough of each to drive
# the plugin's pure logic without a network call or a Rails boot.
#
# beeg's search box is a WebSocket (search.externulls.com), not something
# ::Metadata::PageFetcher can stub — beeg.rb isolates that behind
# WebSearchProvider#resolve_tag (private) precisely so the REST-driven half,
# #videos_for_tag, stays unit-testable on its own via a stubbed PageFetcher.
# That's what's exercised below, using a scrubbed real response saved at
# plugins/beeg/fixtures/beeg_search.json. The WebSocket path itself, and
# #search_page for a non-blank query (which would call it), are not exercised
# here — only smoke_test.rb's interface check covers that surface.
require "minitest/autorun"
require "json"
require "uri"

class Object
  def blank? = respond_to?(:empty?) ? !!empty? : !self
  def present? = !blank?
  def presence = present? ? self : nil
end

module Metadata
  module PageFetcher
    class << self
      attr_accessor :stub
    end

    def self.get(*_args, **_kwargs) = stub
  end

  module GenericJsonLd
    # Minimal stand-in: real one reads a JSON-LD VideoObject block; this just
    # pulls a <title> so fetch()'s enrichment path has something to assert on.
    def self.extract(html)
      return {} if html.to_s.strip.empty?

      { title: html[%r{<title>(.*?)</title>}, 1] }
    end
  end
end

PLUGIN_PATH = File.expand_path("../plugins/beeg/beeg.rb", __dir__)
FIXTURE_PATH = File.expand_path("../plugins/beeg/fixtures/beeg_search.json", __dir__)
BEEG = Object.new.instance_eval(File.read(PLUGIN_PATH), PLUGIN_PATH)

class BeegTest < Minitest::Test
  def setup
    Metadata::PageFetcher.stub = nil
  end

  def test_declares_the_connector_interface
    assert_equal true, BEEG.available?(nil)
    assert_equal %w[resolver web_search], BEEG.capabilities
    assert_equal %w[beeg.com], BEEG.trusted_hosts
    assert_respond_to BEEG, :search
    assert_respond_to BEEG, :fetch

    provider = BEEG.web_search_provider
    assert_respond_to provider, :search
    assert_respond_to provider, :search_page
    assert_respond_to provider, :related
  end

  def test_fetch_returns_nil_for_a_blank_source_id
    assert_nil BEEG.fetch(nil, nil)
    assert_nil BEEG.fetch("", nil)
  end

  def test_fetch_enriches_via_json_ld_when_the_page_has_it
    Metadata::PageFetcher.stub = "<title>T</title>"
    data = BEEG.fetch("https://beeg.com/-0123", nil)

    assert_equal "T", data[:title]
    assert_equal "https://beeg.com/-0123", data[:webpage_url]
  end

  def test_fetch_falls_back_to_just_webpage_url_with_no_page
    Metadata::PageFetcher.stub = nil
    data = BEEG.fetch("https://beeg.com/-0123", nil)

    assert_equal({ webpage_url: "https://beeg.com/-0123" }, data)
  end

  def test_search_page_skips_the_network_for_a_blank_query
    Metadata::PageFetcher.stub = "should never be read"

    result = BEEG.web_search_provider.search_page("")

    assert_equal({ results: [], has_more: false }, result)
  end

  def test_videos_for_tag_maps_the_rest_api_results
    Metadata::PageFetcher.stub = File.read(FIXTURE_PATH)

    result = BEEG.web_search_provider.send(:videos_for_tag, "Lesbian", 50, limit: 2, offset: 0)

    assert_equal 2, result[:results].length
    first = result[:results].first
    assert_equal "Busty Hot Milf Puts My Giant Dick in Her Mouth", first[:title]
    assert_equal "https://beeg.com/-0214989642141614", first[:webpage_url]
    assert_equal "https://thumbs.externulls.com/videos/214989642141614/0.webp?size=320x180", first[:thumbnail_url]
    assert_equal 606, first[:duration]
    assert_equal "beeg", first[:provider]
  end

  def test_videos_for_tag_reports_has_more_from_the_tags_real_video_count
    Metadata::PageFetcher.stub = File.read(FIXTURE_PATH)

    result = BEEG.web_search_provider.send(:videos_for_tag, "Lesbian", 50, limit: 2, offset: 0)
    assert_equal true, result[:has_more]

    result = BEEG.web_search_provider.send(:videos_for_tag, "Lesbian", 2, limit: 2, offset: 0)
    assert_equal false, result[:has_more]
  end

  def test_videos_for_tag_skips_entries_missing_a_file_id
    Metadata::PageFetcher.stub = JSON.generate([ { "file" => { "id" => nil } }, { "file" => nil } ])

    result = BEEG.web_search_provider.send(:videos_for_tag, "Lesbian", 0, limit: 10, offset: 0)

    assert_equal({ results: [], has_more: false }, result)
  end

  def test_videos_for_tag_swallows_malformed_json
    Metadata::PageFetcher.stub = "not json"

    result = BEEG.web_search_provider.send(:videos_for_tag, "Lesbian", 0, limit: 10, offset: 0)

    assert_equal({ results: [], has_more: false }, result)
  end

  def test_videos_for_tag_handles_a_blank_response
    Metadata::PageFetcher.stub = nil

    result = BEEG.web_search_provider.send(:videos_for_tag, "Lesbian", 0, limit: 10, offset: 0)

    assert_equal({ results: [], has_more: false }, result)
  end

  # #search ultimately calls WebSearchProvider#resolve_tag, which needs the
  # live search WebSocket — not stubbable here (see file header). A blank
  # term is the one input that's guaranteed to short-circuit before that
  # network call, so it's the only #search path this suite can safely cover;
  # the field-stamping it does on a resolved result is otherwise identical
  # to (and covered by the same shape as) the values #videos_for_tag already
  # produces, asserted above.
  def test_search_returns_empty_for_a_blank_term
    assert_equal [], BEEG.search("", nil)
    assert_equal [], BEEG.search(nil, nil)
  end
end
