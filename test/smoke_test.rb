# Interface check for every plugins/*.rb a manifest points at via `connector:`
# (docs/scraper-plugin-authoring.md, "Connector escape hatch"). Evaluates each
# file exactly as the XVault host does — Object.new.instance_eval, so no
# constant leaks between plugins — and asserts the required/optional method
# shapes without ever calling into site-specific logic (no network, no
# Nokogiri needed). Pure minitest: `ruby test/smoke_test.rb`.
require "minitest/autorun"
require "yaml"

ROOT = File.expand_path("..", __dir__)

# Mirrors Metadata::Plugin::CAPABILITIES on the XVault core side — duplicated
# here on purpose (this repo has no dependency on core's source).
CAPABILITIES = %w[resolver web_search scrape fingerprint performer].freeze

REQUIRED_ARITY = { available?: 1, capabilities: 0, search: 2, fetch: 2 }.freeze
OPTIONAL_ARITY = {
  resolve: 2, web_search_provider: 0, search_performers: 2, fetch_performer: 2,
  fetch_performer_aliases: 2, fetch_performer_posters: 2, find_performer_id: 2, trusted_hosts: 0
}.freeze

class SmokeTest < Minitest::Test
  Dir.glob(File.join(ROOT, "plugins", "*.yml")).sort.each do |yml_path|
    config = YAML.safe_load_file(yml_path) || {}
    next if config["connector"].to_s.empty?

    plugin_name = File.basename(yml_path)
    rb_path = File.join(File.dirname(yml_path), config["connector"])

    define_method("test_#{plugin_name}_connector_interface") do
      assert File.exist?(rb_path), "#{plugin_name} declares connector: #{config["connector"]} but #{rb_path} is missing"

      connector = Object.new.instance_eval(File.read(rb_path), rb_path)

      REQUIRED_ARITY.each do |method_name, arity|
        assert_respond_to connector, method_name, "#{plugin_name}: missing required ##{method_name}"
        assert_equal arity, connector.method(method_name).arity, "#{plugin_name}: ##{method_name} has the wrong arity"
      end

      OPTIONAL_ARITY.each do |method_name, arity|
        next unless connector.respond_to?(method_name)

        assert_equal arity, connector.method(method_name).arity, "#{plugin_name}: ##{method_name} has the wrong arity"
      end

      capabilities = connector.capabilities
      assert_kind_of Array, capabilities, "#{plugin_name}: capabilities must be an Array"
      assert capabilities.all? { |c| CAPABILITIES.include?(c) },
        "#{plugin_name}: capabilities #{capabilities.inspect} outside the known vocabulary #{CAPABILITIES.inspect}"
    end
  end
end
