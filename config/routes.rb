Rails.application.routes.draw do
  root "sessions#new"

  post "/locale", to: "application#set_locale", as: :set_locale

  get  "/login",  to: "sessions#new"
  post "/login",  to: "sessions#create"
  get  "/logout", to: "sessions#destroy"
  post "/logout", to: "sessions#destroy"

  get "/menu", to: "menu#index"

  # Delete user flow
  get  "/users/delete",        to: "users#delete_form"
  get  "/users/autocomplete",  to: "users#autocomplete"
  post "/users/confirm_delete", to: "users#confirm_delete"
  post "/users/perform_delete", to: "users#perform_delete"

  # Add user flow
  get  "/users/new", to: "users#new"
  post "/users",     to: "users#create"

  # User info flow
  get  "/users/info", to: "users#info_form"
  post "/users/info", to: "users#info"

  # Edit user flow
  get  "/users/edit",          to: "users#edit_form"
  post "/users/edit",          to: "users#edit"
  post "/users/edit_confirm",  to: "users#edit_confirm"
  post "/users/perform_edit",  to: "users#perform_edit"
end
