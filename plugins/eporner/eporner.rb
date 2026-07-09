# Eporner connector — merges free-text search/fetch (Identify's RESOLVER
# capability) with the public search API used for web recommendations
# (WEB_SEARCH capability) into one plugin object, per the `connector:` escape
# hatch (xvault docs/scraper-plugin-authoring.md). No API key needed.
#
# Ported ~verbatim from XVault core's former Connectors::Eporner +
# Recommendations::Providers::Eporner (#40 plugin extraction). This file is
# `instance_eval`'d inside the host XVault process, so referencing
# ::Metadata::PageFetcher / ::Metadata::GenericJsonLd is safe — they're core
# classes already loaded in the same process, not a dependency this file ships.
class Eporner
  def self.available?(_credential) = true
  def self.capabilities = %w[resolver web_search]
  def self.trusted_hosts = %w[eporner.com]

  # Identify panel search (RESOLVER) — maps the same public search API
  # WebSearchProvider uses, stamped with this plugin's own source_key/source_id
  # so Merger can attribute a picked result back to this connector.
  def self.search(term, _credential)
    WebSearchProvider.search(term, limit: 12).map do |v|
      {
        title: v[:title],
        cover_url: v[:thumbnail_url],
        webpage_url: v[:webpage_url],
        duration: v[:duration],
        source_key: "eporner",
        source_id: v[:webpage_url]
      }
    end
  end

  # source_id is the video's page URL. Enrich via the page's JSON-LD
  # VideoObject when present; always at least sets webpage_url so the next
  # auto-resolve can enrich further.
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

  # Eporner's public JSON search API (no auth, api-doc at eporner.com/api-doc/)
  # for keyword/performer search — the response carries real page/total_pages
  # fields, so #search_page's has_more is exact, not a guess. Eporner has no
  # related-videos API, so #related best-effort scrapes the #relateddiv
  # sidebar off the origin page's own HTML — only attempted when that page is
  # itself eporner.com. Never raises: any failure yields [] (or has_more: false
  # for #search_page). Implements the interface Recommendations::Web expects
  # of a WEB_SEARCH provider: .search/.search_page/.related.
  module WebSearchProvider
    HOST = "eporner.com"
    SEARCH_URL = "https://www.eporner.com/api/v2/video/search/"

    def self.search(query, limit: 12, page: 1)
      search_page(query, limit: limit, page: page)[:results]
    end

    # Same lookup as #search, but also reports whether the API has further
    # pages beyond this one (real total_pages from the response, not a guess)
    # — Recommendations::Web.search uses this to decide whether to nest
    # another lazy-loaded page.
    def self.search_page(query, limit: 12, page: 1)
      return { results: [], has_more: false } if query.blank?

      page = [ page.to_i, 1 ].max
      url = "#{SEARCH_URL}?#{URI.encode_www_form(query: query, per_page: limit.clamp(1, 24), page: page, thumbsize: "big", format: "json")}"
      body = ::Metadata::PageFetcher.get(url)
      return { results: [], has_more: false } if body.blank?

      json = JSON.parse(body)
      results = Array(json["videos"]).filter_map { |video| map_video(video) }
      { results: results, has_more: page < json["total_pages"].to_i }
    rescue StandardError
      { results: [], has_more: false }
    end

    def self.related(webpage_url, limit: 12)
      return [] unless own_page?(webpage_url)

      html = ::Metadata::PageFetcher.get(webpage_url)
      return [] if html.blank?

      Nokogiri::HTML(html).css("#relateddiv .mb").first(limit).filter_map { |node| map_related(node) }
    rescue StandardError
      []
    end

    def self.own_page?(url)
      host = URI.parse(url).host.to_s.downcase
      host == HOST || host.end_with?(".#{HOST}") # suffix alone would match noteporner.com
    rescue URI::InvalidURIError
      false
    end
    private_class_method :own_page?

    def self.map_video(video)
      return nil if video["url"].blank?

      {
        provider: "eporner",
        title: video["title"].presence || "Untitled",
        webpage_url: video["url"],
        embed_url: video["embed"],
        thumbnail_url: video.dig("default_thumb", "src"),
        duration: video["length_sec"]
      }
    end
    private_class_method :map_video

    def self.map_related(node)
      link = node.at_css(".mbcontent a")
      return nil if link.nil? || link["href"].blank?

      id = link["href"][%r{/video-([A-Za-z0-9]+)/}, 1]
      return nil if id.nil?

      {
        provider: "eporner",
        title: node.at_css(".mbtit a")&.text&.strip.presence || "Untitled",
        webpage_url: URI.join("https://www.eporner.com", link["href"]).to_s,
        embed_url: "https://www.eporner.com/embed/#{id}/",
        thumbnail_url: node.at_css("img")&.attr("data-src"),
        duration: parse_duration(node.at_css(".mbtim")&.text)
      }
    end
    private_class_method :map_related

    def self.parse_duration(text)
      return nil if text.blank?

      text.strip.split(":").map(&:to_i).reduce(0) { |acc, n| acc * 60 + n }
    end
    private_class_method :parse_duration
  end
end

Eporner
