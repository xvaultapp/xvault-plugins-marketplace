# Pure minitest, no Gemfile: `ruby test/eporner_test.rb` must pass with
# system Ruby alone. eporner.rb references ::Metadata::PageFetcher /
# ::Metadata::GenericJsonLd and ActiveSupport's blank?/present? — those only
# really exist inside the host XVault process (docs/scraper-plugin-authoring.md,
# "Connector escape hatch"). Here we hand-roll just enough of each to drive
# the plugin's pure logic without a network call or a Rails boot.
#
# Nokogiri-backed HTML scraping (WebSearchProvider#related) isn't exercised
# here — it needs a real HTML parser this repo doesn't depend on. The smoke
# test (test/smoke_test.rb) covers that the interface exists; #search/#fetch/
# #search_page below cover the JSON-driven logic, which is the high-value part.
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

PLUGIN_PATH = File.expand_path("../plugins/eporner.rb", __dir__)
EPORNER = Object.new.instance_eval(File.read(PLUGIN_PATH), PLUGIN_PATH)

class EpornerTest < Minitest::Test
  def setup
    Metadata::PageFetcher.stub = nil
  end

  def test_declares_the_connector_interface
    assert_equal true, EPORNER.available?(nil)
    assert_equal %w[resolver web_search], EPORNER.capabilities
    assert_equal %w[eporner.com], EPORNER.trusted_hosts
    assert_respond_to EPORNER, :search
    assert_respond_to EPORNER, :fetch

    provider = EPORNER.web_search_provider
    assert_respond_to provider, :search
    assert_respond_to provider, :search_page
    assert_respond_to provider, :related
  end

  def test_fetch_returns_nil_for_a_blank_source_id
    assert_nil EPORNER.fetch(nil, nil)
    assert_nil EPORNER.fetch("", nil)
  end

  def test_fetch_enriches_via_json_ld_when_the_page_has_it
    Metadata::PageFetcher.stub = "<title>T</title>"
    data = EPORNER.fetch("https://eporner.com/v/1", nil)

    assert_equal "T", data[:title]
    assert_equal "https://eporner.com/v/1", data[:webpage_url]
  end

  def test_fetch_falls_back_to_just_webpage_url_with_no_page
    Metadata::PageFetcher.stub = nil
    data = EPORNER.fetch("https://eporner.com/v/1", nil)

    assert_equal({ webpage_url: "https://eporner.com/v/1" }, data)
  end

  def test_search_maps_the_api_results_and_stamps_source_key_and_id
    json = JSON.generate({
      "videos" => [
        { "url" => "https://www.eporner.com/video-x/", "title" => "Vid", "length_sec" => 90,
          "default_thumb" => { "src" => "https://cdn.example/1.jpg" } }
      ],
      "total_pages" => 1
    })
    Metadata::PageFetcher.stub = json

    results = EPORNER.search("term", nil)

    assert_equal 1, results.length
    result = results.first
    assert_equal "Vid", result[:title]
    assert_equal "https://cdn.example/1.jpg", result[:cover_url]
    assert_equal 90, result[:duration]
    assert_equal "eporner", result[:source_key]
    assert_equal "https://www.eporner.com/video-x/", result[:source_id]
  end

  def test_search_page_reports_has_more_from_total_pages
    json = JSON.generate({ "videos" => [], "total_pages" => 5 })
    Metadata::PageFetcher.stub = json

    result = EPORNER.web_search_provider.search_page("term", page: 1)

    assert_equal true, result[:has_more]
  end

  def test_search_page_skips_the_network_for_a_blank_query
    Metadata::PageFetcher.stub = "should never be read"

    result = EPORNER.web_search_provider.search_page("")

    assert_equal({ results: [], has_more: false }, result)
  end

  def test_search_page_swallows_malformed_json
    Metadata::PageFetcher.stub = "not json"

    result = EPORNER.web_search_provider.search_page("term")

    assert_equal({ results: [], has_more: false }, result)
  end
end
