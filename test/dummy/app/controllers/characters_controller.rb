# frozen_string_literal: true

class CharactersController < ActionController::Base
  rescue_from Tinkick::InvalidQueryError do |error|
    render plain: error.message, status: :bad_request
  end

  def index
    @query = params[:q].presence || "*"
    @keyset = params[:pagination] == "keyset"
    @characters = TolkienCharacter.tinkick_search(@query, limit: 10, countless: true)
    @characters = @characters.where(race: params[:race]) if params[:race].present?
    @characters = if @keyset
      @characters.keyset(after: params[:after].presence)
    else
      @characters.page(params[:page])
    end

    respond_to do |format|
      format.html
      format.json do
        render json: {
          characters: @characters.map { |character| character.attributes.slice("id", "name", "location", "race", "poem") },
          has_next_page: @characters.has_next_page?,
          next_cursor: @characters.next_cursor,
          next_page: @keyset ? nil : @characters.next_page,
        }
      end
    end
  end
end
