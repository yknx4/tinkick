# frozen_string_literal: true

class CatalogController < ActionController::Base
  def index
    field = params.fetch(:field, "title")
    return head(:bad_request) unless ["title", "creator_name", "search_text"].include?(field)

    entries = CatalogEntry.where(collection_id: params.require(:collection_id))
      .tinkick_search(params[:q].presence || "*", fields: [field], misspellings: false,
        per_page: params.fetch(:per_page, 20), page: params[:page], countless: true) do |query|
        query.where(restricted_content: false).reorder(id: :asc)
      end
    render json: { entries: entries.map { |entry| entry.attributes.slice("id", "title", "creator_name") },
                   has_next_page: entries.has_next_page? }
  end
end
