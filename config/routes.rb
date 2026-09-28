Rails.application.routes.draw do
  mount MissionControl::Jobs::Engine, at: "/jobs"

  root "dashboard#show"

  resource :dashboard, only: :show, controller: "dashboard"

  resources :account_backups do
    member do
      post :preview
      post :activate
      post :discover
      patch :pause
    end
    resources :buckets, only: :update, module: :account_backups
  end

  resources :providers do
    scope module: :providers do
      resource :connection_test, only: :create
      resources :buckets, only: [ :index, :create ]
    end
  end

  resources :storages

  resources :notifiers do
    scope module: :notifiers do
      resource :test, only: :create
    end
  end

  resources :backups do
    scope module: :backups do
      resource :execution, only: :create
      resource :cancellation, only: :create
      resource :enablement, only: [ :create, :destroy ]
      resource :dry_run, only: :create
      resources :runs, only: [ :index, :show ] do
        resource :cancellation, only: :create, module: :runs
      end
    end
  end

  resource :health, only: :show, controller: "health"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check
end
