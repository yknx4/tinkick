# frozen_string_literal: true

Rails.application.routes.draw do
  root "characters#index"
  resources :characters, only: :index
  get "catalog", to: "catalog#index"
  get "documents", to: "documents#index"
end
