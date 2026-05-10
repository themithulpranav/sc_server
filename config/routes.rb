Rails.application.routes.draw do
  # For details on the DSL available within this file, see https://guides.rubyonrails.org/routing.html
  resources :shipments, only: [:index]
  resources :controls, only: [] do
    collection do
      post :process_request
    end
  end
end
