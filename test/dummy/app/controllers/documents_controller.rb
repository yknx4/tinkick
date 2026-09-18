# frozen_string_literal: true

class DocumentsController < ActionController::Base
  rescue_from ArgumentError do |error|
    render plain: error.message, status: :bad_request
  end

  def index
    expression = {
      near: [params.require(:left), params.require(:right)],
      distance: Integer(params.fetch(:distance, 0)),
    }
    documents = SearchDocument.tinkick_search(tinql: expression, limit: 10, countless: true)
    documents = documents.where(category: params[:category]) if params[:category].present?
    render json: {
      documents: documents.map { |record| record.attributes.slice("id", "title") },
      has_next_page: documents.has_next_page?,
    }
  end
end
