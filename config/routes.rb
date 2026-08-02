require "sidekiq/web"
require "sidekiq/cron/web"

Rails.application.routes.draw do
  resources :questrade_items, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end
  resources :indexa_capital_items, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end
  resources :mercury_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :wise_items, only: %i[index new create show edit update destroy] do
    collection do
      get :select_profiles
      post :link_profiles
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :brex_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts, to: "brex_items/account_flows#preload_accounts"
      get :select_accounts, to: "brex_items/account_flows#select_accounts"
      post :link_accounts, to: "brex_items/account_flows#link_accounts"
      get :select_existing_account, to: "brex_items/account_flows#select_existing_account"
      post :link_existing_account, to: "brex_items/account_flows#link_existing_account"
    end

    member do
      post :sync
      get :setup_accounts, to: "brex_items/account_setups#setup_accounts"
      post :complete_account_setup, to: "brex_items/account_setups#complete_account_setup"
    end
  end

  resources :coinbase_items, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :binance_items, only: [ :index, :new, :create, :show, :edit, :update, :destroy ] do
    collection do
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :kraken_items, only: [ :create, :update, :destroy ] do
    collection do
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :snaptrade_items, only: [ :index, :show, :destroy ] do
    collection do
      get :preload_accounts
      get :select_accounts
      get :select_existing_account
      post :link_existing_account
      get :callback
      get :oauth_authorize
      get :oauth_callback
    end

    member do
      post :sync
      get :connect
      get :setup_accounts
      post :complete_account_setup
      get :connections
      delete :delete_connection
    end
  end

  resources :ibkr_items, only: [ :create, :update, :destroy ] do
    collection do
      get :select_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :trading212_items, only: [ :create, :update, :destroy ] do
    collection do
      get :select_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  # CoinStats routes
  resources :coinstats_items, only: [ :index, :new, :create, :update, :destroy ] do
    collection do
      post :link_wallet
      post :link_exchange
    end
    member do
      post :sync
    end
  end

  resources :enable_banking_items, only: [ :new, :create, :update, :destroy ] do
    collection do
      get :callback
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end
    member do
      post :sync
      get :select_bank
      post :authorize
      post :reauthorize
      get :setup_accounts
      post :complete_account_setup
      post :new_connection
    end
  end
  get ".well-known/oauth-protected-resource", to: "oauth_metadata#protected_resource"
  get ".well-known/oauth-authorization-server", to: "oauth_metadata#authorization_server"
  get ".well-known/assetlinks.json", to: "android_asset_links#show"
  get ".well-known/apple-app-site-association", to: "apple_app_site_associations#show"
  post "register", to: "oauth_registration#create"
  use_doorkeeper
  # MFA routes
  resource :mfa, controller: "mfa", only: [ :new, :create ] do
    get :verify
    post :verify, to: "mfa#verify_code"
    post :webauthn_options
    post :verify_webauthn
    delete :disable
  end

  mount Lookbook::Engine, at: "/design-system" unless Rails.env.production?

  if Rails.env.development?
    mount Rswag::Api::Engine => "/api-docs"
    mount Rswag::Ui::Engine => "/api-docs"
  end

  # Break-glass queue tooling. Development mounts it open for convenience;
  # everywhere else (production, staging, test) the route only exists for a
  # signed-in super admin — see app/constraints/super_admin_constraint.rb.
  # An optional basic-auth second layer can be enabled via SIDEKIQ_WEB_USERNAME
  # and SIDEKIQ_WEB_PASSWORD (config/initializers/sidekiq.rb).
  if Rails.env.development?
    mount Sidekiq::Web => "/sidekiq"
  else
    constraints SuperAdminConstraint.new do
      mount Sidekiq::Web => "/sidekiq"
    end
  end

  # AI chats
  resources :chats do
    resources :messages, only: :create do
      member do
        # Client-side watchdog reports a "Thinking…" bubble that never received
        # a response (e.g. the background worker is down) so it can be failed.
        post :report_timeout
      end
    end

    member do
      post :retry
    end
  end

  resources :family_exports, only: %i[new create index destroy] do
    member do
      get :download
      post :cancel
    end
  end

  resources :syncs, only: [] do
    member do
      post :cancel
    end
  end

  get "exports/archive/:token", to: "archived_exports#show", as: :archived_export

  get "changelog", to: "pages#changelog"
  get "feedback", to: "pages#feedback"
  patch "dashboard/preferences", to: "pages#update_preferences"

  resource :current_session, only: %i[update]

  resource :registration, only: %i[new create]
  resources :sessions, only: %i[index new create destroy]
  # Desktop app SSO: opens the flow in the system browser (so passkeys/WebAuthn
  # work), then hands a single-use, PKCE-bound code back via the sure:// scheme
  # which the desktop webview exchanges for a normal web session.
  post "/sessions/desktop_exchange", to: "sessions#desktop_exchange", as: :desktop_sso_exchange
  get "/auth/desktop/:provider", to: "sessions#desktop_sso_start"
  get "/auth/mobile/:provider", to: "sessions#mobile_sso_start"
  match "/auth/:provider/callback", to: "sessions#openid_connect", via: %i[get post]
  match "/auth/failure", to: "sessions#failure", via: %i[get post]
  get "/auth/logout/callback", to: "sessions#post_logout"
  resource :oidc_account, only: [] do
    get :link, on: :collection
    post :create_link, on: :collection
    get :new_user, on: :collection
    post :create_user, on: :collection
  end
  resource :password_reset, only: %i[new create edit update]
  resource :password, only: %i[edit update]
  resource :email_confirmation, only: :new

  resources :users, only: %i[update destroy] do
    delete :reset, on: :member
    delete :reset_with_sample_data, on: :member
    patch :rule_prompt_settings, on: :member
    get :resend_confirmation_email, on: :member
  end

  resource :onboarding, only: :show do
    collection do
      get :preferences
      get :goals
      get :trial
    end
  end

  namespace :settings do
    resource :profile, only: [ :show, :destroy ]
    resource :preferences, only: %i[show update]
    resource :appearance, only: %i[show update]
    resource :debug, only: :show
    resource :background_jobs, controller: "background_jobs", only: :show do
      post :cancel
    end
    resource :hosting, only: %i[show update] do
      delete :clear_cache, on: :collection
      delete :disconnect_external_assistant, on: :collection
    end
    resource :payment, only: :show
    resource :security, only: :show
    resources :webauthn_credentials, only: %i[create destroy] do
      post :options, on: :collection
    end
    resources :sso_identities, only: :destroy
    resources :api_keys, only: [ :index, :show, :new, :create, :destroy ]
    resource :mcp, controller: "mcp", only: :show do
      delete "tokens/:token_id", to: "mcp#revoke", as: :revoke_token
    end
    resource :ai_prompts, only: :show
    resource :llm_usage, only: :show
    resource :guides, only: :show
    get "bank_sync", to: redirect("/settings/providers", status: 301)
    resource :providers, only: %i[show update] do
      collection do
        post :sync_all
        post ":provider_key/sync", action: :sync, as: :sync_provider
        get ":provider_key/connect_form", action: :connect_form, as: :connect_form
      end
    end
  end

  resource :subscription, only: %i[new show create] do
    collection do
      get :upgrade
      get :success
    end
  end

  resources :tags, except: :show do
    resources :deletions, only: %i[new create], module: :tag
    delete :destroy_all, on: :collection
  end

  namespace :category do
    resource :dropdown, only: :show
  end

  resources :categories, except: :show do
    resources :deletions, only: %i[new create], module: :category

    get :merge, on: :collection
    post :perform_merge, on: :collection
    post :bootstrap, on: :collection
    delete :destroy_all, on: :collection
  end

  resources :reports, only: %i[index] do
    patch :update_preferences, on: :collection
    get :export_transactions, on: :collection
    get :google_sheets_instructions, on: :collection
    get :print, on: :collection
    get :picker, on: :collection
  end

  resources :budgets, only: %i[index show edit update], param: :month_year do
    post :copy_previous, on: :member
    get :picker, on: :collection

    resources :budget_categories, only: %i[index show update]
  end

  resources :goals do
    member do
      patch :pause
      patch :resume
      patch :complete
      patch :archive
      patch :unarchive
      patch :reopen
    end

    resources :pledges, only: %i[new create destroy], controller: "goal_pledges" do
      member do
        patch :renew
      end
    end
  end

  resources :family_merchants, only: %i[index new create edit update destroy] do
    collection do
      get :merge
      post :perform_merge
      post :enhance
    end
  end

  get :exchange_rate, to: "exchange_rates#show"

  resources :transfers, only: %i[new create destroy show update] do
    member do
      post :mark_as_recurring
    end
  end

  resources :imports, only: %i[index new show create update destroy] do
    member do
      post :publish
      put :revert
      put :apply_template
      post :cancel
    end

    resource :upload, only: %i[show update], module: :import
    resource :configuration, only: %i[show update], module: :import
    resource :clean, only: :show, module: :import
    resource :confirm, only: :show, module: :import
    resource :qif_category_selection, only: %i[show update], module: :import

    resources :rows, only: %i[show update], module: :import
    resources :mappings, only: :update, module: :import
  end

  resources :holdings, only: %i[index new show update destroy] do
    member do
      post :unlock_cost_basis
      patch :remap_security
      post :reset_security
      post :sync_prices
    end
  end
  resources :trades, only: %i[show new create update destroy] do
    member do
      post :unlock
    end
  end
  resources :valuations, only: %i[show new create update destroy] do
    post :confirm_create, on: :collection
    post :confirm_update, on: :member
  end

  namespace :transactions do
    resource :bulk_deletion, only: :create
    resource :bulk_update, only: %i[new create]
    resource :categorize, only: %i[show create] do
      patch :assign_entry, on: :collection
      get :preview_rule, on: :collection
    end
  end

  resources :transactions, only: %i[index new create show update destroy] do
    resource :split, only: %i[new create edit update destroy]
    resource :transfer_match, only: %i[new create]
    resource :pending_duplicate_merges, only: %i[new create]
    resource :category, only: :update, controller: :transaction_categories
    resources :attachments, only: %i[show create destroy], controller: :transaction_attachments

    collection do
      delete :clear_filter
      patch :update_preferences
    end

    member do
      get :convert_to_trade
      post :create_trade_from_transaction
      post :mark_as_recurring
      post :merge_duplicate
      post :dismiss_duplicate
      post :unlock
      patch :tags, action: :update_tags
    end
  end

  resources :recurring_transactions, only: %i[index destroy] do
    collection do
      match :identify, via: [ :get, :post ]
      match :cleanup, via: [ :get, :post ]
      patch :update_settings
    end

    member do
      match :toggle_status, via: [ :get, :post ]
    end
  end

  resources :insights, only: %i[index] do
    collection do
      post :refresh
    end

    member do
      patch :dismiss
      patch :undismiss
    end
  end

  resources :accountable_sparklines, only: :show, param: :accountable_type

  direct :entry do |entry, options|
    if entry.new_record?
      route_for entry.entryable_name.pluralize, options
    else
      route_for entry.entryable_name, entry, options
    end
  end

  resources :rules, except: :show do
    member do
      get :confirm
      post :apply
    end

    collection do
      delete :destroy_all
      get :confirm_all
      post :apply_all
      post :clear_ai_cache
    end
  end

  resources :accounts, only: %i[index new show destroy], shallow: true do
    member do
      post :sync
      get :sparkline
      patch :toggle_active
      patch :toggle_exclude_from_reports
      patch :set_default
      patch :remove_default
      get :select_provider
      get :confirm_unlink
      delete :unlink
    end

    collection do
      post :sync_all
    end

    resource :sharing, only: [ :show, :update ], controller: "account_sharings"
  end

  resources :account_statements, only: %i[index show create update destroy] do
    member do
      patch :link
      patch :unlink
      patch :reject
    end
  end

  # Convenience routes for polymorphic paths
  # Example: account_path(Account.new(accountable: Depository.new)) => /depositories/123
  direct :edit_account do |model, options|
    route_for "edit_#{model.accountable_name}", model, options
  end

  resources :depositories, only: %i[new create edit update]
  resources :investments, only: %i[new create edit update]
  resources :properties, only: %i[new create edit update] do
    member do
      get :balances
      patch :update_balances

      get :address
      patch :update_address
    end
  end
  resources :vehicles, only: %i[new create edit update]
  resources :credit_cards, only: %i[new create edit update]
  resources :loans, only: %i[new create edit update]
  resources :cryptos, only: %i[new create edit update]
  resources :other_assets, only: %i[new create edit update]
  resources :other_liabilities, only: %i[new create edit update]

  resources :securities, only: :index

  resources :invite_codes, only: %i[index create destroy]

  resources :invitations, only: [ :new, :create, :destroy ] do
    get :accept, on: :member
  end

  # API routes
  namespace :api do
    namespace :v1 do
      # Authentication endpoints
      post "auth/signup", to: "auth#signup"
      post "auth/login", to: "auth#login"
      post "auth/webauthn_options", to: "auth#webauthn_options"
      post "auth/webauthn_verify", to: "auth#webauthn_verify"
      post "auth/refresh", to: "auth#refresh"
      post "auth/sso_exchange", to: "auth#sso_exchange"
      post "auth/sso_link", to: "auth#sso_link"
      post "auth/sso_create_account", to: "auth#sso_create_account"
      post "auth/password_reset", to: "auth#request_password_reset"
      patch "auth/password_reset", to: "auth#reset_password"
      post "auth/email_confirmation", to: "auth#confirm_email"
      post "auth/email_confirmation/resend", to: "auth#resend_email_confirmation"
      patch "auth/enable_ai", to: "auth#enable_ai"

      resource :app_info, only: [ :show ], controller: :app_info do
        get :changelog
        get :feedback
      end

      # Production API endpoints
      resources :accounts, only: [ :index, :show, :create, :update, :destroy ] do
        member do
          post :sync
          get :series
          delete :unlink
          patch :toggle_active
          patch :toggle_exclude_from_reports
          patch :set_default
          patch :remove_default
        end

        resource :sharing, controller: "account_sharings", only: [ :show, :update ]
      end
      resources :account_types, only: [ :index ]
      resources :balances, only: [ :index, :show ]
      resources :budgets, only: [ :index, :show, :create, :update ] do
        post :copy_previous, on: :member
      end
      resources :budget_categories, only: [ :index, :show, :update ]
      resources :categories, only: [ :index, :show, :create, :update, :destroy ] do
        post :bootstrap, on: :collection
        delete :destroy_all, on: :collection
        post :merge, on: :collection
        post :replace_and_destroy, on: :member
      end
      resources :merchants, only: [ :index, :show, :create, :update, :destroy ] do
        collection do
          post :merge
          post :enhance
        end
      end
      resources :rules, only: [ :index, :show, :create, :update, :destroy ] do
        collection do
          post :apply_all
          delete :destroy_all
          post :clear_ai_cache
        end

        post :apply, on: :member
      end
      resources :rule_runs, only: [ :index, :show ]
      resources :securities, only: [ :index, :show ]
      resources :security_prices, only: [ :index, :show ]
      resources :tags, only: [ :index, :show, :create, :update, :destroy ] do
        post :replace_and_destroy, on: :member
        delete :destroy_all, on: :collection
      end

      resources :transactions, only: [ :index, :show, :create, :update, :destroy ] do
        collection do
          patch :bulk_update
          delete :bulk_delete
          get "categorize", to: "transaction_categorizations#show"
          post "categorize", to: "transaction_categorizations#create"
          get "categorize/preview_rule", to: "transaction_categorizations#preview_rule"
          patch "categorize/assign_entry", to: "transaction_categorizations#assign_entry"
        end

        member do
          get :duplicate_candidates
          post :merge_duplicate
          post :dismiss_duplicate
          post :mark_as_recurring
          post :convert_to_trade
          post :unlock
          patch :tags, action: :update_tags
        end

        resources :attachments, controller: "transaction_attachments", only: [ :index, :show, :create, :destroy ]
        resource :split, controller: "transaction_splits", only: [ :show, :create, :update, :destroy ]
        resource :transfer_match, controller: "transfer_matches", only: [ :show, :create ]
      end
      resources :trades, only: [ :index, :show, :create, :update, :destroy ] do
        post :unlock, on: :member
      end
      resources :holdings, only: [ :index, :show, :update, :destroy ] do
        post :unlock_cost_basis, on: :member
        patch :remap_security, on: :member
        post :reset_security, on: :member
        post :sync_prices, on: :member
      end
      resources :transfers, only: [ :index, :show, :create, :update, :destroy ] do
        post :mark_as_recurring, on: :member
      end
      resources :rejected_transfers, only: [ :index, :show ]
      resources :valuations, only: [ :index, :create, :update, :show, :destroy ] do
        post :preview, on: :collection, action: :preview_create
        post :preview, on: :member, action: :preview_update
      end
      resources :recurring_transactions, only: [ :index, :show, :create, :update, :destroy ] do
        collection do
          post :identify
          post :cleanup
          patch :update_settings
        end

        patch :toggle_status, on: :member
      end
      resources :goals, only: [ :index, :show, :create, :update, :destroy ] do
        member do
          patch :pause
          patch :resume
          patch :complete
          patch :archive
          patch :unarchive
          patch :reopen
        end

        resources :pledges, controller: "goal_pledges", only: [ :create, :destroy ] do
          patch :renew, on: :member
        end
      end
      resource :savings_challenge,
               only: [ :show, :create ],
               controller: :savings_challenges
      resources :family_exports, only: [ :index, :show, :create, :destroy ] do
        get :download, on: :member
      end
      resources :family_documents, only: [ :index, :show, :create, :destroy ] do
        get :search, on: :collection
      end
      resources :account_statements, only: [ :index, :show, :create, :update, :destroy ] do
        member do
          get :download
          patch :link
          patch :unlink
          patch :reject
        end
      end
      resources :family_members, only: [ :index, :destroy ]
      resources :invitations, only: [ :index, :create, :destroy ] do
        collection do
          get "accept/:token", action: :accept_details, as: :accept_details
          post "accept/:token", action: :accept, as: :accept
        end
      end
      resources :invite_codes, only: [ :index, :create, :destroy ]
      resources :imports, only: [ :index, :show, :create, :update, :destroy ] do
        post :preflight, on: :collection
        member do
          patch :configuration, action: :update_configuration
          post :apply_template
          get :qif_category_selection
          patch :qif_category_selection, action: :update_qif_category_selection
          get :sample_csv
          get :rows
          get :mappings
          patch "rows/:row_id", action: :update_row, as: :row
          patch "mappings/:mapping_id", action: :update_mapping, as: :mapping
          post :publish
          post :revert
        end
      end
      resources :import_sessions, only: [ :show, :create ] do
        post :chunks, on: :member, action: :create_chunk
        post :publish, on: :member
      end
      resource :usage, only: [ :show ], controller: :usage
      resource :balance_sheet, only: [ :show ], controller: :balance_sheet
      resource :reports, only: [ :show ], controller: :reports do
        get :export_transactions
      end
      resource :financial_replay, only: [ :show ], controller: :financial_replays do
        get :availability
      end
      # Legacy alias for app builds that predate the Financial Replay rebrand.
      resource :monthly_dump, only: [ :show ], controller: :financial_replays
      resource :family_settings, only: [ :show, :update ], controller: :family_settings
      resource :preferences, only: [ :show, :update ], controller: :preferences
      resource :hosting, only: [ :show, :update ], controller: :hosting do
        delete :clear_cache
        delete :disconnect_external_assistant
      end
      resource :provider_settings, only: [ :show, :update ], controller: :provider_settings
      resource :ai_settings, only: [ :show ], controller: :ai_settings
      resource :llm_usage, only: [ :show ], controller: :llm_usages
      resource :onboarding, only: [ :show ], controller: :onboarding do
        patch :profile
        patch :preferences
        patch :goals
        post :complete
        post :start_trial
      end
      resource :subscription, only: [ :show ], controller: :subscriptions do
        post :start_trial
        post :checkout
        post :portal
      end
      resources :api_keys, only: [ :index, :show, :create, :destroy ]
      resources :mobile_devices, only: [ :index, :show, :destroy ]
      resource :mobile_delta_sync, only: [ :create ], controller: :mobile_delta_sync
      resource :security, only: [ :show ], controller: :security
      resource :mfa, only: [ :show, :destroy ], controller: :mfa do
        post :setup
        post :verify
      end
      resources :webauthn_credentials, only: [ :create, :destroy ] do
        post :options, on: :collection
      end
      resources :sso_identities, only: [ :destroy ]
      resource :mcp, only: [ :show ], controller: :mcp do
        delete "tokens/:token_id", action: :revoke_token, as: :token
      end
      resource :guide, only: [ :show ], controller: :guides
      namespace :admin do
        resources :users, only: [ :index, :update ]
        resources :invitations, only: [ :destroy ]
        resources :families, only: [] do
          delete :invitations, on: :member, to: "invitations#destroy_all"
        end
        resources :sso_providers, only: [ :index, :show, :create, :update, :destroy ] do
          patch :toggle, on: :member
          post :test_connection, on: :member
        end
      end
      resources :debug_logs, only: [ :index, :show ]
      resources :currencies, only: [ :index, :show ]
      get :exchange_rate, to: "exchange_rates#show"
      get "accountable_sparklines/:accountable_type", to: "accountable_sparklines#show", as: :accountable_sparkline
      post :sync, to: "sync#create", as: :sync_job
      resources :syncs, only: [ :index, :show ] do
        get :latest, on: :collection
      end
      resources :provider_connections, only: [ :index ] do
        collection do
          post :sync_all
          post "plaid/link_token", action: :plaid_link_token, as: :plaid_link_token
          post "plaid/:id/link_token", action: :plaid_update_link_token, as: :plaid_update_link_token
          post "snaptrade/oauth_device_flow", action: :snaptrade_start_oauth_device_flow, as: :snaptrade_start_oauth_device_flow
          post "snaptrade/:id/oauth_device_flow/complete", action: :snaptrade_complete_oauth_device_flow, as: :snaptrade_complete_oauth_device_flow
          get "coinstats/:id/options", action: :coinstats_options, as: :coinstats_options
          post "coinstats/:id/wallets", action: :coinstats_link_wallet, as: :coinstats_link_wallet
          post "coinstats/:id/exchanges", action: :coinstats_link_exchange, as: :coinstats_link_exchange
          get "enable_banking/:id/banks", action: :enable_banking_banks, as: :enable_banking_banks
          post "enable_banking/:id/authorization", action: :enable_banking_start_authorization, as: :enable_banking_start_authorization
          post "enable_banking/:id/authorization/complete", action: :enable_banking_complete_authorization, as: :enable_banking_complete_authorization
          get "sophtron/:id/institutions", action: :sophtron_institutions, as: :sophtron_institutions
          post "sophtron/:id/institution", action: :sophtron_connect_institution, as: :sophtron_connect_institution
          get "sophtron/:id/connection_status", action: :sophtron_connection_status, as: :sophtron_connection_status
          post "sophtron/:id/mfa", action: :sophtron_submit_mfa, as: :sophtron_submit_mfa
          patch "sophtron/:id/manual_sync", action: :sophtron_toggle_manual_sync, as: :sophtron_toggle_manual_sync
          post ":provider_key", action: :create, as: :create_provider
          post ":provider_key/sync", action: :sync, as: :sync_provider
          get ":provider_key/:id/accounts", action: :provider_accounts, as: :provider_accounts
          post ":provider_key/:id/accounts/:provider_account_id/link", action: :link_provider_account, as: :link_provider_account
          post ":provider_key/:id/sync", action: :sync_connection, as: :sync_connection
          post ":provider_key/:id/replacement_suggestions/dismiss", action: :dismiss_replacement_suggestion, as: :dismiss_replacement_suggestion
          patch ":provider_key/:id", action: :update, as: :update_provider
          delete ":provider_key/:id", action: :destroy, as: :destroy_provider
        end
      end

      resources :chats, only: [ :index, :show, :create, :update, :destroy ] do
        get :updates, on: :member
        resources :messages, only: [ :create ] do
          post :retry, on: :collection
          post :report_timeout, on: :member
          get :attachment, on: :member
        end
      end

      get "users/reset/status", to: "users#reset_status"
      delete "users/reset", to: "users#reset"
      delete "users/reset_with_sample_data", to: "users#reset_with_sample_data"
      get "users/me", to: "users#show"
      patch "users/me", to: "users#update"
      patch "users/me/password", to: "users#update_password"
      patch "users/me/rule_prompt_settings", to: "users#rule_prompt_settings"
      delete "users/me", to: "users#destroy"

      # Test routes for API controller testing (only available in test environment)
      if Rails.env.test?
        get "test", to: "test#index"
        get "test_not_found", to: "test#not_found"
        get "test_family_access", to: "test#family_access"
        get "test_scope_required", to: "test#scope_required"
        get "test_multiple_scopes_required", to: "test#multiple_scopes_required"
      end
    end
  end



  resources :currencies, only: %i[show]

  resources :impersonation_sessions, only: [ :create ] do
    post :join, on: :collection
    delete :leave, on: :collection

    member do
      put :approve
      put :reject
      put :complete
    end
  end

  resources :plaid_items, only: %i[new edit create destroy] do
    collection do
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
    end
  end

  resources :simplefin_items, only: %i[index new create show edit update destroy] do
    collection do
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      post :balances
      get :setup_accounts
      post :complete_account_setup
      post :dismiss_replacement_suggestion
    end
  end

  resources :lunchflow_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :redbark_items, only: %i[create update destroy] do
    collection do
      get :select_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :akahu_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :up_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :sync
      get :setup_accounts
      post :complete_account_setup
    end
  end

  resources :sophtron_items, only: %i[index new create show edit update destroy] do
    collection do
      get :preload_accounts
      get :select_accounts
      post :link_accounts
      get :select_existing_account
      post :link_existing_account
    end

    member do
      post :connect_institution
      post :sync
      post :toggle_manual_sync
      post :balances
      get :connection_status
      post :submit_mfa
      get :setup_accounts
      post :complete_account_setup
    end
  end

  namespace :webhooks do
    post "plaid"
    post "plaid_eu"
    post "stripe"
  end

  get "redis-configuration-error", to: "pages#redis_configuration_error"

  # MCP server endpoint for external AI assistants (JSON-RPC 2.0)
  post "mcp", to: "mcp#handle"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "pwa#service_worker", as: :pwa_service_worker, defaults: { format: :js }
  get "manifest" => "pwa#manifest", as: :pwa_manifest, defaults: { format: :json }

  get "imports/:import_id/upload/sample_csv", to: "import/uploads#sample_csv", as: :import_upload_sample_csv

  privacy_url = ENV["LEGAL_PRIVACY_URL"].presence
  terms_url = ENV["LEGAL_TERMS_URL"].presence
  get "privacy", to: privacy_url ? redirect(privacy_url) : "pages#privacy"
  get "terms", to: terms_url ? redirect(terms_url) : "pages#terms"
  get "intro", to: "pages#intro"

  # Admin namespace for super admin functionality
  namespace :admin do
    resources :sso_providers do
      member do
        patch :toggle
        post :test_connection
      end
    end
    resources :users, only: [ :index, :update ]
    resources :invitations, only: [ :destroy ]
    resources :families, only: [] do
      member do
        delete :invitations, to: "invitations#destroy_all"
      end
    end
  end

  # Defines the root path route ("/")
  root "pages#dashboard"
end
