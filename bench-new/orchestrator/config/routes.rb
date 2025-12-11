Rails.application.routes.draw do
  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  # HTML Dashboard (no auth required)
  root "dashboard#index"
  get "tasks_frame", to: "dashboard#tasks_frame"

  # API Endpoints (require Bearer token auth)
  resources :runs, only: [:index, :create, :show] do
    member do
      post :stop
    end
    resources :tasks, only: [:index]
  end

  # Task endpoints (not nested under runs for simpler worker implementation)
  post "runs/:run_id/tasks/claim", to: "tasks#claim"
  post "tasks/:id/heartbeat", to: "tasks#heartbeat"
  post "tasks/:id/complete", to: "tasks#complete"
  post "tasks/:id/fail", to: "tasks#fail"
end
