Rails.application.routes.draw do

  unless Rails.env.production?
    mount Rswag::Ui::Engine => '/api-docs'
    mount Rswag::Api::Engine => '/api-docs'
  end

  root to: "application#application"
  post '/ipnlistener', to: 'paypal#notify'
  post '/mailtrap_listener', to: 'mailtrap#webhooks', defaults: { format: :json }

  namespace :billing do
    post '/braintree_listener', to: 'braintree#webhooks'
  end

  # Slack inbound slash commands (outside :api scope — Slack posts form-encoded)
  namespace :slack do
    post '/commands/checkout',  to: 'commands#checkout'
    post '/commands/volunteer', to: 'commands#volunteer'
  end

  # Public volunteer pages — unauthenticated, token gated via SystemConfig
  namespace :volunteer do
    get '/bounties',    to: 'bounties#index'
    get '/leaderboard', to: 'leaderboard#index'
  end

  scope :api, defaults: { format: :json } do
    devise_for :members, skip: [:registrations], controllers: {
      sessions: 'sessions'
    }
    devise_scope :member do
      post 'members',            to: 'registrations#create'
      post '/send_registration', to: 'registrations#new'
    end

    resources :invoice_options, only: [:index, :show]
    resources :client_error_handler, only: [:create]

    # Public shop/tool listing
    resources :shops, only: [:index]
    resources :tools, only: [:index]

    namespace :billing do
      resources :plans,     only: [:index]
      resources :discounts, only: [:index]
    end

    authenticate :member do
      put '/members/change_password', to: 'members/passwords#update'

      resources :members, only: [:show, :index, :update] do
        scope module: :members do
          resources :permissions, only: [:index]
        end
      end

      # Member self-service tool checkouts
      resources :tool_checkouts, only: [:index]

      # Member self-service rentals
      resources :rentals, only: [:show, :index, :update, :create] do
        member do
          put :cancel
        end
      end

      # Member self-service invoices / billing
      resources :invoices, only: [:index, :show] do
        member do
          post :pay
          post :request_refund
        end
      end

      # TOTP
      resource :totp_session, only: [:create, :destroy]
      resource :totp_setup,   only: [:show, :create, :destroy]

      # Firebase auth
      namespace :auth do
        post '/firebase_login', to: 'firebase#login'
      end

      # Member earned memberships
      resources :earned_memberships, only: [:show, :update]

      # Volunteer credits
      resources :volunteer_credits, only: [:index]
    end

    namespace :admin do
      resources :members do
        collection do
          post :send_set_password_email
        end
        member do
          put  :update_password
          post :membership_revoked
        end
        # Admin-only email delivery log for a member — feeds the Email Log tab
        resources :mailtrap_events, only: [:index],
                  module: :members,
                  controller: 'mailtrap_events'
      end

      resources :invoices do
        member do
          post :force_cancel
        end
      end

      resources :rentals do
        member do
          post :approve
          post :deny
        end
      end

      resources :invoice_options

      resources :earned_memberships

      resources :tool_checkouts do
        collection do
          get  :approvers
          post :add_approver
          delete :remove_approver
        end
      end

      resources :tools do
        member do
          post :certify
        end
        collection do
          get :certifications
        end
      end

      resources :shops

      namespace :billing do
        resources :plans,     only: [:index]
        resources :discounts, only: [:index]
      end

      resources :system_configs, only: [] do
        collection do
          put  :update_flag
          put  :update_setting
          post :run_job
        end
      end

      resources :audit_logs, only: [:index, :show]

      resources :volunteer_tasks do
        member do
          post :complete
        end
      end

      resources :volunteer_events do
        member do
          post :close
        end
      end

      resources :volunteer_credits, only: [:index, :create, :destroy]

      namespace :checkins do
        get '/', to: 'checkins#index'
      end

      resources :checkins,   only: [:index]
      resources :rejections, only: [:index]
    end

    # Client config (Firebase keys etc.) — authenticated read
    authenticate :member do
      get '/config', to: 'client_config#show'
    end
  end
end
