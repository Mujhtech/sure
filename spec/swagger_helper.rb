# frozen_string_literal: true

require 'rails_helper'

RSpec.configure do |config|
  config.openapi_root = Rails.root.join('docs', 'api').to_s
  reset_count_keys = Family::FinancialDataReset::STATUS_COUNT_KEYS.map(&:to_s)

  config.openapi_specs = {
    'openapi.yaml' => {
      openapi: '3.0.3',
      info: {
        title: 'Sure API',
        version: 'v1',
        description: 'OpenAPI documentation generated from executable request specs.'
      },
      servers: [
        {
          url: 'https://app.sure.am',
          description: 'Production'
        },
        {
          url: 'http://localhost:3000',
          description: 'Local development'
        }
      ],
      components: {
        securitySchemes: {
          apiKeyAuth: {
            type: :apiKey,
            name: 'X-Api-Key',
            in: :header,
            description: 'API key for authentication. Generate one from your account settings.'
          }
        },
        schemas: {
          Pagination: {
            type: :object,
            required: %w[page per_page total_count total_pages],
            properties: {
              page: { type: :integer, minimum: 1 },
              per_page: { type: :integer, minimum: 1 },
              total_count: { type: :integer, minimum: 0 },
              total_pages: { type: :integer, minimum: 0 }
            }
          },
          SavingsChallengeCampaign: {
            type: :object,
            required: %w[id name short_description start_date end_date duration_days phase days_remaining],
            properties: {
              id: { type: :string },
              name: { type: :string },
              short_description: { type: :string },
              start_date: { type: :string, format: :date },
              end_date: { type: :string, format: :date },
              duration_days: { type: :integer, minimum: 1 },
              phase: { type: :string, enum: %w[upcoming active ended] },
              day_number: { type: :integer, minimum: 1, nullable: true },
              days_remaining: { type: :integer, minimum: 0 }
            }
          },
          SavingsChallengeEnrollment: {
            type: :object,
            required: %w[id goal_id joined_at currency target_amount target_amount_cents starting_balance
                         starting_balance_cents saved_amount saved_amount_cents progress_percent completed],
            properties: {
              id: { type: :string, format: :uuid },
              goal_id: { type: :string, format: :uuid },
              joined_at: { type: :string, format: :'date-time' },
              currency: { type: :string },
              target_amount: { type: :string },
              target_amount_cents: { type: :integer },
              starting_balance: { type: :string },
              starting_balance_cents: { type: :integer },
              saved_amount: { type: :string },
              saved_amount_cents: { type: :integer },
              progress_percent: { type: :integer, minimum: 0, maximum: 100 },
              completed: { type: :boolean }
            }
          },
          SavingsChallengeResponse: {
            type: :object,
            required: %w[campaign enrollment],
            properties: {
              campaign: { '$ref' => '#/components/schemas/SavingsChallengeCampaign' },
              enrollment: {
                allOf: [ { '$ref' => '#/components/schemas/SavingsChallengeEnrollment' } ],
                nullable: true
              }
            }
          },
          FamilyExportFile: {
            type: :object,
            required: %w[attached],
            properties: {
              attached: { type: :boolean },
              byte_size: { type: :integer, nullable: true, minimum: 0 },
              content_type: { type: :string, nullable: true }
            }
          },
          FamilyExport: {
            type: :object,
            required: %w[id status filename downloadable file created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              status: { type: :string, enum: %w[pending processing completed failed] },
              filename: { type: :string },
              downloadable: { type: :boolean },
              download_path: { type: :string, nullable: true },
              file: { '$ref' => '#/components/schemas/FamilyExportFile' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          FamilyExportResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/FamilyExport' }
            }
          },
          FamilyExportCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                maxItems: 100,
                items: { '$ref' => '#/components/schemas/FamilyExport' }
              },
              meta: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          ErrorResponse: {
            type: :object,
            required: %w[error],
            properties: {
              error: { type: :string },
              message: { type: :string, nullable: true },
              details: {
                oneOf: [
                  { type: :array, items: { type: :string } },
                  { type: :object }
                ],
                nullable: true
              },
              errors: {
                type: :array,
                items: { type: :string },
                nullable: true,
                description: 'Validation error messages (alternative to details used by trades, valuations, etc.)'
              }
            }
          },
          ErrorResponseWithImportId: {
            type: :object,
            required: %w[error import_id],
            properties: {
              error: { type: :string },
              message: { type: :string, nullable: true },
              import_id: {
                type: :string,
                format: :uuid,
                description: 'Import ID preserved for retry or inspection after upload succeeds but publish fails'
              }
            }
          },
          GenericMessageResponse: {
            type: :object,
            required: %w[message],
            properties: {
              message: { type: :string }
            }
          },
          PersonalApiKey: {
            type: :object,
            required: %w[id name scopes source active current created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              scopes: {
                type: :array,
                items: { type: :string, enum: %w[read read_write] }
              },
              source: { type: :string, enum: %w[web mobile monitoring] },
              active: { type: :boolean },
              current: { type: :boolean, description: 'True when the request is authenticated with this API key.' },
              last_used_at: { type: :string, format: :'date-time', nullable: true },
              expires_at: { type: :string, format: :'date-time', nullable: true },
              revoked_at: { type: :string, format: :'date-time', nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          PersonalApiKeyCollection: {
            type: :object,
            required: %w[api_keys options],
            properties: {
              api_keys: {
                type: :array,
                items: { '$ref' => '#/components/schemas/PersonalApiKey' }
              },
              options: {
                type: :object,
                required: %w[scopes sources],
                properties: {
                  scopes: {
                    type: :array,
                    items: { type: :string, enum: %w[read read_write] }
                  },
                  sources: {
                    type: :array,
                    items: { type: :string, enum: %w[mobile] }
                  }
                }
              }
            }
          },
          PersonalApiKeyResponse: {
            type: :object,
            required: %w[api_key],
            properties: {
              api_key: { '$ref' => '#/components/schemas/PersonalApiKey' }
            }
          },
          PersonalApiKeyCreateResponse: {
            type: :object,
            required: %w[api_key],
            properties: {
              api_key: {
                allOf: [
                  { '$ref' => '#/components/schemas/PersonalApiKey' },
                  {
                    type: :object,
                    required: %w[plain_key],
                    properties: {
                      plain_key: {
                        type: :string,
                        description: 'Plain API key secret. Returned only at creation time.'
                      }
                    }
                  }
                ]
              }
            }
          },
          PersonalApiKeyRevokeResponse: {
            type: :object,
            required: %w[message api_key],
            properties: {
              message: { type: :string },
              api_key: { '$ref' => '#/components/schemas/PersonalApiKey' }
            }
          },
          BulkOperationResponse: {
            type: :object,
            required: %w[message requested_count skipped_count],
            properties: {
              message: { type: :string },
              requested_count: { type: :integer, minimum: 0 },
              matched_count: { type: :integer, minimum: 0 },
              updated_count: { type: :integer, minimum: 0 },
              deleted_count: { type: :integer, minimum: 0 },
              skipped_count: { type: :integer, minimum: 0 }
            }
          },
          TransactionAttachment: {
            type: :object,
            required: %w[id filename content_type byte_size inline_path download_path created_at],
            properties: {
              id: { type: :string },
              filename: { type: :string },
              content_type: { type: :string },
              byte_size: { type: :integer, minimum: 0 },
              inline_path: { type: :string },
              download_path: { type: :string },
              created_at: { type: :string, format: :'date-time' }
            }
          },
          TransactionAttachmentCollection: {
            type: :object,
            required: %w[attachments],
            properties: {
              attachments: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionAttachment' }
              }
            }
          },
          AccountStatementAccount: {
            type: :object,
            required: %w[id name account_type],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              account_type: { type: :string }
            }
          },
          AccountStatementReconciliationCheck: {
            type: :object,
            required: %w[key statement_amount ledger_amount difference status],
            properties: {
              key: { type: :string },
              statement_amount: { type: :string },
              ledger_amount: { type: :string },
              difference: { type: :string },
              status: { type: :string, enum: %w[matched mismatched] }
            }
          },
          AccountStatement: {
            type: :object,
            required: %w[id filename content_type byte_size source upload_status review_status currency manageable download_path account suggested_account reconciliation_checks created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              filename: { type: :string },
              content_type: { type: :string },
              byte_size: { type: :integer, minimum: 0 },
              source: { type: :string },
              upload_status: { type: :string, enum: %w[stored failed] },
              review_status: { type: :string, enum: %w[unmatched linked rejected] },
              institution_name_hint: { type: :string, nullable: true },
              account_name_hint: { type: :string, nullable: true },
              account_last4_hint: { type: :string, nullable: true },
              period_start_on: { type: :string, format: :date, nullable: true },
              period_end_on: { type: :string, format: :date, nullable: true },
              opening_balance: { type: :string, nullable: true },
              closing_balance: { type: :string, nullable: true },
              currency: { type: :string },
              parser_confidence: { type: :string, nullable: true },
              match_confidence: { type: :string, nullable: true },
              manageable: { type: :boolean },
              download_path: { type: :string },
              account: {
                allOf: [ { '$ref' => '#/components/schemas/AccountStatementAccount' } ],
                nullable: true
              },
              suggested_account: {
                allOf: [ { '$ref' => '#/components/schemas/AccountStatementAccount' } ],
                nullable: true
              },
              reconciliation_checks: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AccountStatementReconciliationCheck' }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          AccountStatementCollection: {
            type: :object,
            required: %w[account_statements pagination],
            properties: {
              account_statements: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AccountStatement' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          AccountStatementUploadResponse: {
            type: :object,
            required: %w[account_statements duplicates errors],
            properties: {
              account_statements: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AccountStatement' }
              },
              duplicates: {
                type: :array,
                items: {
                  type: :object,
                  required: %w[id filename],
                  properties: {
                    id: { type: :string, format: :uuid },
                    filename: { type: :string }
                  }
                }
              },
              errors: {
                type: :array,
                items: { type: :string }
              }
            }
          },
          FamilyDocument: {
            type: :object,
            required: %w[id filename content_type file_size status metadata created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              filename: { type: :string },
              content_type: { type: :string },
              file_size: { type: :integer, minimum: 0 },
              status: { type: :string, enum: %w[pending processing ready error] },
              metadata: { type: :object, additionalProperties: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          FamilyDocumentResponse: {
            type: :object,
            required: %w[family_document],
            properties: {
              family_document: { '$ref' => '#/components/schemas/FamilyDocument' }
            }
          },
          FamilyDocumentVectorStoreCapabilities: {
            type: :object,
            required: %w[configured supported_upload_extensions max_upload_size],
            properties: {
              configured: { type: :boolean },
              supported_upload_extensions: {
                type: :array,
                items: { type: :string }
              },
              max_upload_size: { type: :integer, minimum: 0 }
            }
          },
          FamilyDocumentCollection: {
            type: :object,
            required: %w[family_documents pagination vector_store],
            properties: {
              family_documents: {
                type: :array,
                items: { '$ref' => '#/components/schemas/FamilyDocument' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' },
              vector_store: { '$ref' => '#/components/schemas/FamilyDocumentVectorStoreCapabilities' }
            }
          },
          FamilyDocumentSearchResult: {
            type: :object,
            required: %w[filename content score],
            properties: {
              filename: { type: :string },
              content: { type: :string },
              score: { type: :number, nullable: true }
            }
          },
          FamilyDocumentSearchResponse: {
            type: :object,
            required: %w[query result_count results],
            properties: {
              query: { type: :string },
              result_count: { type: :integer, minimum: 0 },
              results: {
                type: :array,
                items: { '$ref' => '#/components/schemas/FamilyDocumentSearchResult' }
              }
            }
          },
          MfaRequiredResponse: {
            type: :object,
            required: %w[error mfa_required],
            properties: {
              error: { type: :string },
              mfa_required: { type: :boolean }
            }
          },
          ToolCall: {
            type: :object,
            required: %w[id function_name function_arguments created_at],
            properties: {
              id: { type: :string, format: :uuid },
              function_name: { type: :string },
              function_arguments: { type: :object, additionalProperties: true },
              function_result: { type: :object, additionalProperties: true, nullable: true },
              created_at: { type: :string, format: :'date-time' }
            }
          },
          Message: {
            type: :object,
            required: %w[id type role content created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              type: { type: :string, enum: %w[user_message assistant_message] },
              role: { type: :string, enum: %w[user assistant] },
              content: { type: :string },
              model: { type: :string, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' },
              tool_calls: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ToolCall' },
                nullable: true
              }
            }
          },
          MessageResponse: {
            allOf: [
              { '$ref' => '#/components/schemas/Message' },
              {
                type: :object,
                required: %w[chat_id],
                properties: {
                  chat_id: { type: :string, format: :uuid },
                  ai_response_status: { type: :string, enum: %w[pending complete failed], nullable: true },
                  ai_response_message: { type: :string, nullable: true }
                }
              }
            ]
          },
          ChatResource: {
            type: :object,
            required: %w[id title created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              title: { type: :string },
              error: { type: :string, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          ChatSummary: {
            allOf: [
              { '$ref' => '#/components/schemas/ChatResource' },
              {
                type: :object,
                required: %w[message_count],
                properties: {
                  message_count: { type: :integer, minimum: 0 },
                  last_message_at: { type: :string, format: :'date-time', nullable: true }
                }
              }
            ]
          },
          ChatDetail: {
            allOf: [
              { '$ref' => '#/components/schemas/ChatResource' },
              {
                type: :object,
                required: %w[messages],
                properties: {
                  messages: {
                    type: :array,
                    items: { '$ref' => '#/components/schemas/Message' }
                  },
                  pagination: {
                    '$ref' => '#/components/schemas/Pagination',
                    nullable: true
                  }
                }
              }
            ]
          },
          ChatCollection: {
            type: :object,
            required: %w[chats pagination],
            properties: {
              chats: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ChatSummary' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          RetryResponse: {
            type: :object,
            required: %w[message message_id chat_id],
            properties: {
              message: { type: :string },
              message_id: { type: :string, format: :uuid },
              chat_id: { type: :string, format: :uuid }
            }
          },
          MessageTimeoutReportResponse: {
            type: :object,
            required: %w[message resolved chat_id message_id],
            properties: {
              message: { type: :string },
              resolved: { type: :boolean },
              chat_id: { type: :string, format: :uuid },
              message_id: { type: :string, format: :uuid }
            }
          },
          Account: {
            type: :object,
            required: %w[id name account_type],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              account_type: { type: :string, nullable: true },
              status: { type: :string }
            }
          },
          UserSummary: {
            type: :object,
            required: %w[id email display_name initials],
            properties: {
              id: { type: :string, format: :uuid },
              email: { type: :string, format: :email },
              display_name: { type: :string },
              initials: { type: :string }
            }
          },
          UserProfile: {
            type: :object,
            required: %w[id email pending_email_change display_name initials role active theme default_period default_account_order show_sidebar show_ai_sidebar ai_enabled ai_available rule_prompts_disabled goals created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              email: { type: :string, format: :email },
              unconfirmed_email: { type: :string, format: :email, nullable: true },
              pending_email_change: { type: :boolean },
              first_name: { type: :string, nullable: true },
              last_name: { type: :string, nullable: true },
              display_name: { type: :string },
              initials: { type: :string },
              role: { type: :string, enum: %w[guest member admin super_admin] },
              active: { type: :boolean },
              locale: { type: :string, nullable: true },
              theme: { type: :string, nullable: true },
              default_period: { type: :string },
              default_account_order: { type: :string },
              show_sidebar: { type: :boolean },
              show_ai_sidebar: { type: :boolean },
              ai_enabled: { type: :boolean },
              ai_available: { type: :boolean },
              rule_prompts_disabled: { type: :boolean, nullable: true },
              rule_prompt_dismissed_at: { type: :string, format: :'date-time', nullable: true },
              onboarded_at: { type: :string, format: :'date-time', nullable: true },
              set_onboarding_preferences_at: { type: :string, format: :'date-time', nullable: true },
              set_onboarding_goals_at: { type: :string, format: :'date-time', nullable: true },
              goals: { type: :array, items: { type: :string } },
              default_account_id: { type: :string, format: :uuid, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          UserProfileFamily: {
            type: :object,
            required: %w[id currency locale date_format month_start_day moniker default_account_sharing custom_enabled_currencies enabled_currencies created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string, nullable: true },
              currency: { type: :string },
              locale: { type: :string },
              date_format: { type: :string },
              country: { type: :string, nullable: true },
              timezone: { type: :string, nullable: true },
              month_start_day: { type: :integer },
              moniker: { type: :string },
              default_account_sharing: { type: :string, enum: %w[shared private] },
              custom_enabled_currencies: { type: :boolean },
              enabled_currencies: { type: :array, items: { type: :string } },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          UserProfileOptions: {
            type: :object,
            required: %w[default_periods default_account_orders themes locales family_sharing_modes],
            properties: {
              default_periods: { type: :array, items: { type: :string } },
              default_account_orders: { type: :array, items: { type: :string } },
              themes: { type: :array, items: { type: :string, enum: %w[light dark system] } },
              locales: { type: :array, items: { type: :string } },
              family_sharing_modes: { type: :array, items: { type: :string, enum: %w[shared private] } }
            }
          },
          UserProfileResponse: {
            type: :object,
            required: %w[user family options email_change_requested],
            properties: {
              user: { '$ref' => '#/components/schemas/UserProfile' },
              family: { '$ref' => '#/components/schemas/UserProfileFamily' },
              options: { '$ref' => '#/components/schemas/UserProfileOptions' },
              email_change_requested: { type: :boolean }
            }
          },
          AiSettingsResponse: {
            type: :object,
            required: %w[ai prompts functions],
            properties: {
              ai: {
                type: :object,
                required: %w[enabled requested_enabled available show_sidebar assistant_type available_assistant_types default_model rule_prompts_disabled],
                properties: {
                  enabled: { type: :boolean, description: 'Effective AI enabled state after availability checks.' },
                  requested_enabled: { type: :boolean, description: 'Raw user preference before provider availability checks.' },
                  available: { type: :boolean },
                  show_sidebar: { type: :boolean },
                  assistant_type: { type: :string, enum: %w[builtin external] },
                  available_assistant_types: { type: :array, items: { type: :string, enum: %w[builtin external] } },
                  default_model: { type: :string },
                  rule_prompts_disabled: { type: :boolean },
                  rule_prompt_dismissed_at: { type: :string, format: :'date-time', nullable: true }
                }
              },
              prompts: {
                type: :array,
                items: {
                  type: :object,
                  required: %w[key model instructions],
                  properties: {
                    key: { type: :string, enum: %w[main_system_prompt transaction_categorizer merchant_detector] },
                    model: { type: :string },
                    instructions: { type: :string }
                  }
                }
              },
              functions: {
                type: :array,
                items: {
                  type: :object,
                  required: %w[key class_name],
                  properties: {
                    key: { type: :string },
                    class_name: { type: :string }
                  }
                }
              }
            }
          },
          LlmUsage: {
            type: :object,
            required: %w[id provider model operation prompt_tokens completion_tokens total_tokens formatted_cost failed created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              provider: { type: :string },
              model: { type: :string },
              operation: { type: :string },
              prompt_tokens: { type: :integer, minimum: 0 },
              completion_tokens: { type: :integer, minimum: 0 },
              total_tokens: { type: :integer, minimum: 0 },
              cache_creation_tokens: { type: :integer, minimum: 0, nullable: true },
              cache_read_tokens: { type: :integer, minimum: 0, nullable: true },
              estimated_cost: { type: :string, nullable: true },
              formatted_cost: { type: :string },
              failed: { type: :boolean },
              http_status_code: { type: :integer, nullable: true },
              error_message: { type: :string, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          LlmUsageStatistics: {
            type: :object,
            required: %w[total_requests requests_with_cost total_prompt_tokens total_completion_tokens total_tokens total_cost avg_cost by_operation by_model],
            properties: {
              total_requests: { type: :integer, minimum: 0 },
              requests_with_cost: { type: :integer, minimum: 0 },
              total_prompt_tokens: { type: :integer, minimum: 0 },
              total_completion_tokens: { type: :integer, minimum: 0 },
              total_tokens: { type: :integer, minimum: 0 },
              total_cost: { type: :number, format: :float },
              avg_cost: { type: :number, format: :float },
              by_operation: { type: :object, additionalProperties: { type: :number, format: :float } },
              by_model: { type: :object, additionalProperties: { type: :number, format: :float } }
            }
          },
          LlmUsageResponse: {
            type: :object,
            required: %w[period statistics llm_usages meta],
            properties: {
              period: {
                type: :object,
                required: %w[start_date end_date],
                properties: {
                  start_date: { type: :string, format: :date },
                  end_date: { type: :string, format: :date }
                }
              },
              statistics: { '$ref' => '#/components/schemas/LlmUsageStatistics' },
              llm_usages: {
                type: :array,
                items: { '$ref' => '#/components/schemas/LlmUsage' }
              },
              meta: {
                type: :object,
                required: %w[limit count],
                properties: {
                  limit: { type: :integer, minimum: 1, maximum: 100 },
                  count: { type: :integer, minimum: 0 }
                }
              }
            }
          },
          HostingCredentialStatus: {
            type: :object,
            required: %w[configured env_locked],
            properties: {
              configured: { type: :boolean },
              env_locked: { type: :boolean }
            }
          },
          HostingBudget: {
            type: :object,
            required: %w[value minimum env_locked],
            properties: {
              value: { type: :integer, nullable: true },
              minimum: { type: :integer },
              env_locked: { type: :boolean }
            }
          },
          HostingState: {
            type: :object,
            required: %w[mode onboarding brand_fetch market_data sync llm assistant],
            properties: {
              mode: {
                type: :object,
                required: %w[self_hosted app_mode admin super_admin],
                properties: {
                  self_hosted: { type: :boolean },
                  app_mode: { type: :string },
                  admin: { type: :boolean },
                  super_admin: { type: :boolean }
                }
              },
              onboarding: {
                type: :object,
                required: %w[state require_email_confirmation],
                properties: {
                  state: { type: :string, enum: %w[open closed invite_only] },
                  require_email_confirmation: { type: :boolean },
                  invite_only_default_family_id: { type: :string, format: :uuid, nullable: true }
                }
              },
              brand_fetch: {
                type: :object,
                required: %w[client_id_configured client_id_env_locked high_res_logos high_res_logos_env_locked logo_size],
                properties: {
                  client_id_configured: { type: :boolean },
                  client_id_env_locked: { type: :boolean },
                  high_res_logos: { type: :boolean },
                  high_res_logos_env_locked: { type: :boolean },
                  logo_size: { type: :integer }
                }
              },
              market_data: {
                type: :object,
                required: %w[exchange_rate_provider exchange_rate_provider_env_locked securities_providers securities_providers_env_locked api_keys],
                properties: {
                  exchange_rate_provider: { type: :string },
                  exchange_rate_provider_env_locked: { type: :boolean },
                  securities_providers: { type: :array, items: { type: :string } },
                  securities_providers_env_locked: { type: :boolean },
                  api_keys: {
                    type: :object,
                    properties: {
                      twelve_data: { '$ref' => '#/components/schemas/HostingCredentialStatus' },
                      tiingo: { '$ref' => '#/components/schemas/HostingCredentialStatus' },
                      eodhd: { '$ref' => '#/components/schemas/HostingCredentialStatus' },
                      alpha_vantage: { '$ref' => '#/components/schemas/HostingCredentialStatus' },
                      tinkoff_invest: { '$ref' => '#/components/schemas/HostingCredentialStatus' }
                    }
                  }
                }
              },
              sync: {
                type: :object,
                required: %w[include_pending include_pending_env_locked auto_sync_enabled auto_sync_enabled_env_locked auto_sync_time auto_sync_time_env_locked auto_sync_timezone],
                properties: {
                  include_pending: { type: :boolean },
                  include_pending_env_locked: { type: :boolean },
                  auto_sync_enabled: { type: :boolean },
                  auto_sync_enabled_env_locked: { type: :boolean },
                  auto_sync_time: { type: :string },
                  auto_sync_time_env_locked: { type: :boolean },
                  auto_sync_timezone: { type: :string }
                }
              },
              llm: {
                type: :object,
                required: %w[provider provider_env_locked openai anthropic budgets],
                properties: {
                  provider: { type: :string, enum: %w[openai anthropic] },
                  provider_env_locked: { type: :boolean },
                  openai: { type: :object },
                  anthropic: { type: :object },
                  budgets: {
                    type: :object,
                    properties: {
                      context_window: { '$ref' => '#/components/schemas/HostingBudget' },
                      max_response_tokens: { '$ref' => '#/components/schemas/HostingBudget' },
                      max_items_per_call: { '$ref' => '#/components/schemas/HostingBudget' }
                    }
                  }
                }
              },
              assistant: {
                type: :object,
                required: %w[type type_env_locked external],
                properties: {
                  type: { type: :string, enum: %w[builtin external] },
                  type_env_locked: { type: :boolean },
                  external: { type: :object }
                }
              }
            }
          },
          HostingOptions: {
            type: :object,
            required: %w[onboarding_states llm_providers assistant_types exchange_rate_providers securities_providers openai_json_modes llm_budget_minimums],
            properties: {
              onboarding_states: { type: :array, items: { type: :string, enum: %w[open closed invite_only] } },
              llm_providers: { type: :array, items: { type: :string, enum: %w[openai anthropic] } },
              assistant_types: { type: :array, items: { type: :string, enum: %w[builtin external] } },
              exchange_rate_providers: { type: :array, items: { type: :string } },
              securities_providers: { type: :array, items: { type: :string } },
              openai_json_modes: { type: :array, items: { type: :string, nullable: true } },
              llm_budget_minimums: { type: :object }
            }
          },
          HostingResponse: {
            type: :object,
            required: %w[hosting options],
            properties: {
              hosting: { '$ref' => '#/components/schemas/HostingState' },
              options: { '$ref' => '#/components/schemas/HostingOptions' }
            }
          },
          HostingMutationResponse: {
            type: :object,
            required: %w[message hosting],
            properties: {
              message: { type: :string },
              hosting: { '$ref' => '#/components/schemas/HostingState' },
              options: { '$ref' => '#/components/schemas/HostingOptions' }
            }
          },
          OnboardingResponse: {
            type: :object,
            required: %w[onboarding user family subscription options],
            properties: {
              message: { type: :string },
              onboarding: {
                type: :object,
                required: %w[onboarded next_step steps invitation],
                properties: {
                  onboarded: { type: :boolean },
                  next_step: { type: :string, enum: %w[profile preferences goals trial complete] },
                  steps: {
                    type: :array,
                    items: {
                      type: :object,
                      required: %w[key complete],
                      properties: {
                        key: { type: :string },
                        complete: { type: :boolean }
                      }
                    }
                  },
                  invitation: {
                    type: :object,
                    required: %w[accepted],
                    properties: {
                      accepted: { type: :boolean },
                      id: { type: :string, format: :uuid },
                      inviter_id: { type: :string, format: :uuid },
                      accepted_at: { type: :string, format: :'date-time', nullable: true }
                    }
                  }
                }
              },
              user: {
                type: :object,
                required: %w[id email display_name goals],
                properties: {
                  id: { type: :string, format: :uuid },
                  email: { type: :string, format: :email },
                  first_name: { type: :string, nullable: true },
                  last_name: { type: :string, nullable: true },
                  display_name: { type: :string },
                  locale: { type: :string, nullable: true },
                  theme: { type: :string, nullable: true },
                  goals: { type: :array, items: { type: :string } },
                  onboarded_at: { type: :string, format: :'date-time', nullable: true },
                  set_onboarding_preferences_at: { type: :string, format: :'date-time', nullable: true },
                  set_onboarding_goals_at: { type: :string, format: :'date-time', nullable: true }
                }
              },
              family: {
                type: :object,
                required: %w[id currency locale date_format],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string, nullable: true },
                  country: { type: :string, nullable: true },
                  moniker: { type: :string, enum: %w[Family Group] },
                  currency: { type: :string },
                  locale: { type: :string },
                  date_format: { type: :string }
                }
              },
              subscription: {
                type: :object,
                required: %w[self_hosted can_start_trial needs_subscription trialing],
                properties: {
                  self_hosted: { type: :boolean },
                  can_start_trial: { type: :boolean },
                  needs_subscription: { type: :boolean },
                  status: { type: :string, nullable: true },
                  trialing: { type: :boolean },
                  trial_ends_at: { type: :string, format: :'date-time', nullable: true },
                  days_left_in_trial: { type: :integer, nullable: true }
                }
              },
              options: {
                type: :object,
                required: %w[themes locales currencies date_formats monikers countries goals],
                properties: {
                  themes: { type: :array, items: { type: :string, enum: %w[system light dark] } },
                  locales: { type: :array, items: { type: :string } },
                  currencies: {
                    type: :array,
                    items: {
                      type: :object,
                      required: %w[code name],
                      properties: {
                        code: { type: :string },
                        name: { type: :string },
                        symbol: { type: :string, nullable: true }
                      }
                    }
                  },
                  date_formats: {
                    type: :array,
                    items: {
                      type: :object,
                      required: %w[label value],
                      properties: {
                        label: { type: :string },
                        value: { type: :string }
                      }
                    }
                  },
                  monikers: { type: :array, items: { type: :string, enum: %w[Family Group] } },
                  countries: {
                    type: :array,
                    items: {
                      type: :object,
                      required: %w[code name],
                      properties: {
                        code: { type: :string },
                        name: { type: :string }
                      }
                    }
                  },
                  goals: {
                    type: :array,
                    items: {
                      type: :object,
                      required: %w[value icon label],
                      properties: {
                        value: { type: :string },
                        icon: { type: :string },
                        label: { type: :string }
                      }
                    }
                  }
                }
              }
            }
          },
          SubscriptionStatus: {
            type: :object,
            required: %w[self_hosted upgrade_required needs_subscription can_start_trial trialing active can_manage_subscription pending_cancellation],
            properties: {
              self_hosted: { type: :boolean },
              upgrade_required: { type: :boolean },
              needs_subscription: { type: :boolean },
              can_start_trial: { type: :boolean },
              trialing: { type: :boolean },
              active: { type: :boolean },
              can_manage_subscription: { type: :boolean },
              status: {
                type: :string,
                nullable: true,
                enum: %w[incomplete incomplete_expired trialing active past_due canceled unpaid paused]
              },
              name: { type: :string, nullable: true },
              amount: { type: :string, nullable: true },
              currency: { type: :string, nullable: true },
              interval: { type: :string, nullable: true },
              trial_ends_at: { type: :string, format: :'date-time', nullable: true },
              current_period_ends_at: { type: :string, format: :'date-time', nullable: true },
              days_left_in_trial: { type: :integer, nullable: true },
              percentage_of_trial_remaining: { type: :number, format: :float, nullable: true },
              percentage_of_trial_completed: { type: :number, format: :float, nullable: true },
              pending_cancellation: { type: :boolean },
              cancel_at_period_end: { type: :boolean, nullable: true },
              created_at: { type: :string, format: :'date-time', nullable: true },
              updated_at: { type: :string, format: :'date-time', nullable: true }
            }
          },
          SubscriptionOptions: {
            type: :object,
            required: %w[plans default_plan checkout_available portal_available],
            properties: {
              plans: {
                type: :array,
                items: {
                  type: :object,
                  required: %w[key interval],
                  properties: {
                    key: { type: :string, enum: %w[monthly annual] },
                    interval: { type: :string, enum: %w[month year] }
                  }
                }
              },
              default_plan: { type: :string, enum: %w[annual] },
              checkout_available: { type: :boolean },
              portal_available: { type: :boolean }
            }
          },
          SubscriptionResponse: {
            type: :object,
            required: %w[subscription options],
            properties: {
              message: { type: :string },
              subscription: { '$ref' => '#/components/schemas/SubscriptionStatus' },
              options: { '$ref' => '#/components/schemas/SubscriptionOptions' }
            }
          },
          SubscriptionCheckoutResponse: {
            type: :object,
            required: %w[checkout_url subscription options],
            properties: {
              checkout_url: { type: :string, format: :uri },
              subscription: { '$ref' => '#/components/schemas/SubscriptionStatus' },
              options: { '$ref' => '#/components/schemas/SubscriptionOptions' }
            }
          },
          SubscriptionPortalResponse: {
            type: :object,
            required: %w[portal_url subscription options],
            properties: {
              portal_url: { type: :string, format: :uri },
              subscription: { '$ref' => '#/components/schemas/SubscriptionStatus' },
              options: { '$ref' => '#/components/schemas/SubscriptionOptions' }
            }
          },
          MobileDevice: {
            type: :object,
            required: %w[id name device_type active current active_token_count created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              device_type: { type: :string, enum: %w[ios android web] },
              os_version: { type: :string, nullable: true },
              app_version: { type: :string, nullable: true },
              active: { type: :boolean },
              current: { type: :boolean, description: 'True when the request OAuth token belongs to this device. API-key requests return false.' },
              active_token_count: { type: :integer, minimum: 0 },
              last_seen_at: { type: :string, format: :'date-time', nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          MobileDeviceCollection: {
            type: :object,
            required: %w[mobile_devices],
            properties: {
              mobile_devices: {
                type: :array,
                items: { '$ref' => '#/components/schemas/MobileDevice' }
              }
            }
          },
          MobileDeviceRevokeResponse: {
            type: :object,
            required: %w[message mobile_device revoked_token_count],
            properties: {
              message: { type: :string },
              mobile_device: { '$ref' => '#/components/schemas/MobileDevice' },
              revoked_token_count: { type: :integer, minimum: 0 }
            }
          },
          MfaState: {
            type: :object,
            required: %w[enabled setup_pending webauthn_enabled backup_codes_remaining],
            properties: {
              enabled: { type: :boolean },
              setup_pending: { type: :boolean },
              webauthn_enabled: { type: :boolean },
              backup_codes_remaining: { type: :integer, minimum: 0 }
            }
          },
          MfaResponse: {
            type: :object,
            required: %w[mfa],
            properties: {
              mfa: { '$ref' => '#/components/schemas/MfaState' }
            }
          },
          MfaSetup: {
            type: :object,
            required: %w[issuer account_name otp_secret provisioning_uri],
            properties: {
              issuer: { type: :string },
              account_name: { type: :string, format: :email },
              otp_secret: { type: :string, description: 'Plain TOTP secret returned only during pending setup.' },
              provisioning_uri: { type: :string, description: 'otpauth URI for authenticator enrollment.' }
            }
          },
          MfaSetupResponse: {
            type: :object,
            required: %w[mfa setup],
            properties: {
              mfa: { '$ref' => '#/components/schemas/MfaState' },
              setup: { '$ref' => '#/components/schemas/MfaSetup' }
            }
          },
          MfaMutationResponse: {
            type: :object,
            required: %w[message mfa],
            properties: {
              message: { type: :string },
              mfa: { '$ref' => '#/components/schemas/MfaState' }
            }
          },
          MfaVerifyResponse: {
            type: :object,
            required: %w[message mfa backup_codes],
            properties: {
              message: { type: :string },
              mfa: { '$ref' => '#/components/schemas/MfaState' },
              backup_codes: {
                type: :array,
                description: 'Plain backup codes returned only once when MFA is enabled.',
                items: { type: :string }
              }
            }
          },
          WebauthnCredential: {
            type: :object,
            required: %w[id nickname transports created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              nickname: { type: :string },
              transports: {
                type: :array,
                items: { type: :string }
              },
              last_used_at: { type: :string, format: :'date-time', nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          WebauthnRegistrationOptionsResponse: {
            type: :object,
            required: %w[challenge_id expires_in_seconds public_key],
            properties: {
              challenge_id: { type: :string, format: :uuid },
              expires_in_seconds: { type: :integer, minimum: 1 },
              public_key: {
                type: :object,
                description: 'PublicKeyCredentialCreationOptions returned by the WebAuthn library.',
                required: %w[challenge rp user pubKeyCredParams],
                properties: {
                  challenge: { type: :string },
                  rp: { type: :object },
                  user: { type: :object },
                  pubKeyCredParams: { type: :array, items: { type: :object } },
                  excludeCredentials: { type: :array, items: { type: :object } },
                  authenticatorSelection: { type: :object },
                  attestation: { type: :string }
                },
                additionalProperties: true
              }
            }
          },
          WebauthnCredentialCreateResponse: {
            type: :object,
            required: %w[message webauthn_credential],
            properties: {
              message: { type: :string },
              webauthn_credential: { '$ref' => '#/components/schemas/WebauthnCredential' }
            }
          },
          SsoIdentity: {
            type: :object,
            required: %w[id provider label icon can_unlink created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              provider: { type: :string },
              label: { type: :string },
              icon: { type: :string },
              email: { type: :string, format: :email, nullable: true },
              last_authenticated_at: { type: :string, format: :'date-time', nullable: true },
              can_unlink: { type: :boolean },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          AdminUser: {
            type: :object,
            required: %w[id email display_name initials role active current_user sessions_count family_id created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              email: { type: :string, format: :email },
              display_name: { type: :string },
              initials: { type: :string },
              role: { type: :string, enum: %w[guest member admin super_admin] },
              active: { type: :boolean },
              current_user: { type: :boolean },
              last_login_at: { type: :string, format: :'date-time', nullable: true },
              sessions_count: { type: :integer, minimum: 0 },
              family_id: { type: :string, format: :uuid },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          AdminUserPendingInvitation: {
            type: :object,
            required: %w[id email role expires_at created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              email: { type: :string, format: :email },
              role: { type: :string, enum: %w[guest member admin] },
              expires_at: { type: :string, format: :'date-time' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          AdminUserSubscription: {
            type: :object,
            required: %w[id status trialing active cancel_at_period_end created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              status: { type: :string, enum: %w[incomplete incomplete_expired trialing active past_due canceled unpaid paused] },
              trialing: { type: :boolean },
              active: { type: :boolean },
              trial_ends_at: { type: :string, format: :'date-time', nullable: true },
              cancel_at_period_end: { type: :boolean },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          AdminUserFamilyGroup: {
            type: :object,
            required: %w[id name currency users_count accounts_count entries_count pending_invitations users],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              currency: { type: :string },
              users_count: { type: :integer, minimum: 0 },
              accounts_count: { type: :integer, minimum: 0 },
              entries_count: { type: :integer, minimum: 0 },
              subscription: {
                allOf: [ { '$ref' => '#/components/schemas/AdminUserSubscription' } ],
                nullable: true
              },
              pending_invitations: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AdminUserPendingInvitation' }
              },
              users: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AdminUser' }
              }
            }
          },
          AdminUserCollection: {
            type: :object,
            required: %w[families filters summary],
            properties: {
              families: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AdminUserFamilyGroup' }
              },
              filters: {
                type: :object,
                required: %w[roles trial_statuses],
                properties: {
                  roles: {
                    type: :array,
                    items: { type: :string, enum: %w[guest member admin super_admin] }
                  },
                  trial_statuses: {
                    type: :array,
                    items: { type: :string, enum: %w[expiring_soon trialing] }
                  }
                }
              },
              summary: {
                type: :object,
                required: %w[trials_expiring_in_7_days],
                properties: {
                  trials_expiring_in_7_days: { type: :integer, minimum: 0 }
                }
              }
            }
          },
          AdminUserResponse: {
            type: :object,
            required: %w[message user],
            properties: {
              message: { type: :string },
              user: { '$ref' => '#/components/schemas/AdminUser' }
            }
          },
          AdminUserUpdateRequest: {
            type: :object,
            required: %w[user],
            properties: {
              user: {
                type: :object,
                required: %w[role],
                properties: {
                  role: { type: :string, enum: %w[guest member admin super_admin] }
                }
              }
            }
          },
          AdminInvitationDeleteResponse: {
            type: :object,
            required: %w[message invitation_id],
            properties: {
              message: { type: :string },
              invitation_id: { type: :string, format: :uuid }
            }
          },
          AdminFamilyInvitationsDeleteResponse: {
            type: :object,
            required: %w[message family_id deleted_count],
            properties: {
              message: { type: :string },
              family_id: { type: :string, format: :uuid },
              deleted_count: { type: :integer, minimum: 0 }
            }
          },
          AdminSsoProvider: {
            type: :object,
            required: %w[id strategy name label enabled client_secret_present settings source manageable created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              strategy: { type: :string, enum: %w[openid_connect google_oauth2 github saml] },
              name: { type: :string },
              label: { type: :string },
              icon: { type: :string, nullable: true },
              enabled: { type: :boolean },
              issuer: { type: :string, nullable: true },
              client_id: { type: :string, nullable: true },
              client_secret_present: { type: :boolean },
              redirect_uri: { type: :string, nullable: true },
              callback_url: { type: :string },
              settings: { type: :object, additionalProperties: true },
              source: { type: :string, enum: %w[database] },
              manageable: { type: :boolean },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          AdminRuntimeSsoProvider: {
            type: :object,
            required: %w[name enabled source manageable],
            properties: {
              name: { type: :string },
              strategy: { type: :string, nullable: true },
              label: { type: :string, nullable: true },
              icon: { type: :string, nullable: true },
              enabled: { type: :boolean },
              callback_url: { type: :string },
              source: { type: :string, enum: %w[runtime] },
              manageable: { type: :boolean }
            }
          },
          AdminSsoProviderResponse: {
            type: :object,
            required: %w[sso_provider],
            properties: {
              message: { type: :string },
              sso_provider: { '$ref' => '#/components/schemas/AdminSsoProvider' }
            }
          },
          AdminSsoProviderCollection: {
            type: :object,
            required: %w[sso_providers legacy_providers configuration],
            properties: {
              sso_providers: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AdminSsoProvider' }
              },
              legacy_providers: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AdminRuntimeSsoProvider' }
              },
              configuration: {
                type: :object,
                required: %w[database_providers_enabled supported_strategies],
                properties: {
                  database_providers_enabled: { type: :boolean },
                  supported_strategies: {
                    type: :array,
                    items: { type: :string, enum: %w[openid_connect google_oauth2 github saml] }
                  }
                }
              }
            }
          },
          AdminSsoProviderMutation: {
            type: :object,
            properties: {
              strategy: { type: :string, enum: %w[openid_connect google_oauth2 github saml] },
              name: { type: :string },
              label: { type: :string },
              icon: { type: :string, nullable: true },
              enabled: { type: :boolean },
              issuer: { type: :string, nullable: true },
              client_id: { type: :string, nullable: true },
              client_secret: { type: :string, nullable: true },
              redirect_uri: { type: :string, nullable: true },
              settings: { type: :object, additionalProperties: true }
            }
          },
          AdminSsoProviderCreateRequest: {
            type: :object,
            required: %w[sso_provider],
            properties: {
              sso_provider: {
                allOf: [
                  { '$ref' => '#/components/schemas/AdminSsoProviderMutation' },
                  {
                    type: :object,
                    required: %w[strategy name label]
                  }
                ]
              }
            }
          },
          AdminSsoProviderUpdateRequest: {
            type: :object,
            required: %w[sso_provider],
            properties: {
              sso_provider: { '$ref' => '#/components/schemas/AdminSsoProviderMutation' }
            }
          },
          AdminSsoProviderTestResponse: {
            type: :object,
            required: %w[success message details],
            properties: {
              success: { type: :boolean },
              message: { type: :string },
              details: { type: :object, additionalProperties: true }
            }
          },
          SsoProvider: {
            type: :object,
            required: %w[name label icon mobile_sso_start_path],
            properties: {
              name: { type: :string },
              label: { type: :string },
              icon: { type: :string },
              strategy: { type: :string, nullable: true },
              mobile_sso_start_path: { type: :string }
            }
          },
          SecurityOverviewResponse: {
            type: :object,
            required: %w[security],
            properties: {
              security: {
                type: :object,
                required: %w[mfa local_authentication webauthn_credentials sso_identities sso_providers encryption],
                properties: {
                  mfa: {
                    type: :object,
                    required: %w[enabled webauthn_enabled backup_codes_remaining],
                    properties: {
                      enabled: { type: :boolean },
                      webauthn_enabled: { type: :boolean },
                      backup_codes_remaining: { type: :integer, minimum: 0 }
                    }
                  },
                  local_authentication: {
                    type: :object,
                    required: %w[password_enabled sso_only],
                    properties: {
                      password_enabled: { type: :boolean },
                      sso_only: { type: :boolean }
                    }
                  },
                  webauthn_credentials: {
                    type: :array,
                    items: { '$ref' => '#/components/schemas/WebauthnCredential' }
                  },
                  sso_identities: {
                    type: :array,
                    items: { '$ref' => '#/components/schemas/SsoIdentity' }
                  },
                  sso_providers: {
                    type: :array,
                    items: { '$ref' => '#/components/schemas/SsoProvider' }
                  },
                  encryption: {
                    type: :object,
                    required: %w[unconfigured],
                    properties: {
                      unconfigured: { type: :boolean }
                    }
                  }
                }
              }
            }
          },
          WebauthnCredentialDeleteResponse: {
            type: :object,
            required: %w[message webauthn_credential_id],
            properties: {
              message: { type: :string },
              webauthn_credential_id: { type: :string, format: :uuid }
            }
          },
          SsoIdentityDeleteResponse: {
            type: :object,
            required: %w[message sso_identity_id provider],
            properties: {
              message: { type: :string },
              sso_identity_id: { type: :string, format: :uuid },
              provider: { type: :string }
            }
          },
          FamilyMember: {
            type: :object,
            required: %w[id email display_name initials role active current_user can_remove created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              email: { type: :string, format: :email },
              display_name: { type: :string },
              initials: { type: :string },
              role: { type: :string, enum: %w[guest member admin super_admin] },
              active: { type: :boolean },
              current_user: { type: :boolean },
              can_remove: { type: :boolean },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          Invitation: {
            type: :object,
            required: %w[id email role pending accepted_existing_user expires_at created_at updated_at family inviter token accept_url],
            properties: {
              id: { type: :string, format: :uuid },
              email: { type: :string, format: :email },
              role: { type: :string, enum: %w[guest member admin] },
              pending: { type: :boolean },
              accepted_existing_user: { type: :boolean },
              accepted_at: { type: :string, format: :'date-time', nullable: true },
              expires_at: { type: :string, format: :'date-time', nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' },
              family: {
                type: :object,
                required: %w[id name],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string }
                }
              },
              inviter: { '$ref' => '#/components/schemas/UserSummary' },
              token: { type: :string, nullable: true },
              accept_url: { type: :string, nullable: true }
            }
          },
          FamilyMembersResponse: {
            type: :object,
            required: %w[family_members pending_invitations],
            properties: {
              family_members: {
                type: :array,
                items: { '$ref' => '#/components/schemas/FamilyMember' }
              },
              pending_invitations: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Invitation' }
              }
            }
          },
          InvitationCollection: {
            type: :object,
            required: %w[invitations],
            properties: {
              invitations: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Invitation' }
              }
            }
          },
          AccountSharingSummary: {
            type: :object,
            required: %w[shared owned_by_current_user current_user_permission include_in_finances],
            properties: {
              shared: { type: :boolean },
              owned_by_current_user: { type: :boolean },
              current_user_permission: { type: :string, nullable: true, enum: %w[owner full_control read_write read_only] },
              include_in_finances: { type: :boolean }
            }
          },
          AccountableAddress: {
            type: :object,
            required: %w[id],
            properties: {
              id: { type: :string, format: :uuid },
              line1: { type: :string, nullable: true },
              line2: { type: :string, nullable: true },
              county: { type: :string, nullable: true },
              locality: { type: :string, nullable: true },
              region: { type: :string, nullable: true },
              country: { type: :string, nullable: true },
              postal_code: { type: :string, nullable: true }
            }
          },
          AccountableDetail: {
            type: :object,
            required: %w[id type key subtype],
            properties: {
              id: { type: :string, format: :uuid, nullable: true },
              type: { type: :string, enum: Accountable::TYPES, nullable: true },
              key: { type: :string, nullable: true },
              subtype: { type: :string, nullable: true },
              tax_treatment: { type: :string, nullable: true, enum: %w[taxable tax_deferred tax_exempt tax_advantaged] },
              available_credit: { type: :string, nullable: true },
              minimum_payment: { type: :string, nullable: true },
              apr: { type: :string, nullable: true },
              annual_fee: { type: :string, nullable: true },
              expiration_date: { type: :string, format: :date, nullable: true },
              rate_type: { type: :string, nullable: true },
              interest_rate: { type: :string, nullable: true },
              term_months: { type: :integer, nullable: true },
              initial_balance: { type: :string, nullable: true },
              year_built: { type: :integer, nullable: true },
              area_value: { type: :integer, nullable: true },
              area_unit: { type: :string, nullable: true },
              address: { '$ref' => '#/components/schemas/AccountableAddress', nullable: true },
              make: { type: :string, nullable: true },
              model: { type: :string, nullable: true },
              year: { type: :integer, nullable: true },
              mileage_value: { type: :integer, nullable: true },
              mileage_unit: { type: :string, nullable: true }
            }
          },
          AccountDetail: {
            type: :object,
            required: %w[id name balance balance_cents cash_balance cash_balance_cents currency classification account_type accountable status exclude_from_reports default transaction_default_eligible syncing linked manual deletable created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              balance: { type: :string },
              balance_cents: { type: :integer, description: 'Signed balance in minor currency units' },
              cash_balance: { type: :string },
              cash_balance_cents: { type: :integer, description: 'Signed cash balance in minor currency units' },
              currency: { type: :string },
              classification: { type: :string },
              account_type: { type: :string, nullable: true },
              subtype: { type: :string, nullable: true },
              accountable: { '$ref' => '#/components/schemas/AccountableDetail' },
              status: { type: :string, enum: %w[active draft disabled pending_deletion] },
              institution_name: { type: :string, nullable: true },
              institution_domain: { type: :string, nullable: true },
              exclude_from_reports: { type: :boolean },
              default: { type: :boolean },
              transaction_default_eligible: { type: :boolean },
              syncing: { type: :boolean },
              linked: { type: :boolean },
              manual: { type: :boolean },
              deletable: { type: :boolean },
              owner: { '$ref' => '#/components/schemas/UserSummary', nullable: true },
              sharing: { '$ref' => '#/components/schemas/AccountSharingSummary' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          AccountSharingShare: {
            type: :object,
            required: %w[shared],
            properties: {
              id: { type: :string, format: :uuid, nullable: true },
              shared: { type: :boolean },
              permission: { type: :string, nullable: true, enum: %w[full_control read_write read_only] },
              include_in_finances: { type: :boolean, nullable: true },
              created_at: { type: :string, format: :'date-time', nullable: true },
              updated_at: { type: :string, format: :'date-time', nullable: true }
            }
          },
          AccountSharingMember: {
            allOf: [
              { '$ref' => '#/components/schemas/UserSummary' },
              {
                type: :object,
                required: %w[active share],
                properties: {
                  active: { type: :boolean },
                  share: { '$ref' => '#/components/schemas/AccountSharingShare' }
                }
              }
            ]
          },
          AccountSharingResponse: {
            type: :object,
            required: %w[account permissions current_user_share family_members],
            properties: {
              account: {
                type: :object,
                required: %w[id name owner_id owned_by_current_user current_user_permission owner],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string },
                  owner_id: { type: :string, format: :uuid, nullable: true },
                  owned_by_current_user: { type: :boolean },
                  current_user_permission: { type: :string, nullable: true, enum: %w[owner full_control read_write read_only] },
                  owner: { '$ref' => '#/components/schemas/UserSummary', nullable: true }
                }
              },
              permissions: {
                type: :array,
                items: { type: :string, enum: %w[full_control read_write read_only] }
              },
              current_user_share: {
                type: :object,
                nullable: true,
                properties: {
                  id: { type: :string, format: :uuid },
                  permission: { type: :string, enum: %w[full_control read_write read_only] },
                  include_in_finances: { type: :boolean }
                }
              },
              family_members: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AccountSharingMember' }
              }
            }
          },
          AccountCollection: {
            type: :object,
            required: %w[accounts pagination],
            properties: {
              accounts: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AccountDetail' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          FamilySettings: {
            type: :object,
            required: %w[id currency locale date_format month_start_day moniker default_account_sharing custom_enabled_currencies enabled_currencies created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string, nullable: true },
              currency: { type: :string },
              locale: { type: :string },
              date_format: { type: :string },
              country: { type: :string, nullable: true },
              timezone: { type: :string, nullable: true },
              month_start_day: { type: :integer, minimum: 1, maximum: 28 },
              moniker: { type: :string, enum: Family::MONIKERS },
              default_account_sharing: { type: :string, enum: %w[shared private] },
              custom_enabled_currencies: { type: :boolean },
              enabled_currencies: {
                type: :array,
                items: { type: :string }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          UserPreferencesResponse: {
            type: :object,
            required: %w[preferences options],
            properties: {
              preferences: {
                type: :object,
                required: %w[raw appearance preview_features_enabled dashboard reports transactions],
                properties: {
                  raw: { type: :object, description: 'Raw stored user preferences for forward compatibility.' },
                  appearance: {
                    type: :object,
                    required: %w[dashboard_two_column show_split_grouped],
                    properties: {
                      dashboard_two_column: { type: :boolean },
                      show_split_grouped: { type: :boolean }
                    }
                  },
                  preview_features_enabled: { type: :boolean },
                  dashboard: {
                    type: :object,
                    required: %w[collapsed_sections section_order section_layout],
                    properties: {
                      collapsed_sections: { type: :object, additionalProperties: { type: :boolean } },
                      section_order: { type: :array, items: { type: :string } },
                      section_layout: { type: :object }
                    }
                  },
                  reports: {
                    type: :object,
                    required: %w[collapsed_sections section_order],
                    properties: {
                      collapsed_sections: { type: :object, additionalProperties: { type: :boolean } },
                      section_order: { type: :array, items: { type: :string } }
                    }
                  },
                  transactions: {
                    type: :object,
                    required: %w[collapsed_sections],
                    properties: {
                      collapsed_sections: { type: :object, additionalProperties: { type: :boolean } }
                    }
                  }
                }
              },
              options: {
                type: :object,
                required: %w[dashboard_sections dashboard_height_presets dashboard_default_height_preset dashboard_widths default_dashboard_section_order report_sections default_reports_section_order],
                properties: {
                  dashboard_sections: { type: :array, items: { type: :string } },
                  dashboard_height_presets: { type: :object, additionalProperties: { type: :integer } },
                  dashboard_default_height_preset: { type: :string },
                  dashboard_widths: { type: :array, items: { type: :string, enum: %w[single full] } },
                  default_dashboard_section_order: { type: :array, items: { type: :string } },
                  report_sections: { type: :array, items: { type: :string } },
                  default_reports_section_order: { type: :array, items: { type: :string } }
                }
              }
            }
          },
          InviteCode: {
            type: :object,
            required: %w[id token created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              token: { type: :string },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          InviteCodeResponse: {
            type: :object,
            required: %w[invite_code],
            properties: {
              invite_code: { '$ref' => '#/components/schemas/InviteCode' }
            }
          },
          InviteCodeCollection: {
            type: :object,
            required: %w[invite_codes],
            properties: {
              invite_codes: {
                type: :array,
                items: { '$ref' => '#/components/schemas/InviteCode' }
              }
            }
          },
          Currency: {
            type: :object,
            required: %w[iso_code name symbol priority minor_unit_conversion default_precision step enabled primary],
            properties: {
              iso_code: { type: :string, example: 'USD' },
              name: { type: :string, example: 'United States Dollar' },
              symbol: { type: :string, nullable: true, example: '$' },
              priority: { type: :integer, nullable: true },
              iso_numeric: { type: :string, nullable: true },
              html_code: { type: :string, nullable: true },
              minor_unit: { type: :string, nullable: true },
              minor_unit_conversion: { type: :integer },
              smallest_denomination: { type: :integer, nullable: true },
              separator: { type: :string, nullable: true },
              delimiter: { type: :string, nullable: true },
              default_format: { type: :string, nullable: true },
              default_precision: { type: :integer },
              step: { type: :number, format: :double },
              enabled: { type: :boolean, description: 'Whether this currency is enabled for the authenticated family.' },
              primary: { type: :boolean, description: 'Whether this currency is the authenticated family primary currency.' }
            }
          },
          CurrencyCollection: {
            type: :object,
            required: %w[currencies meta],
            properties: {
              currencies: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Currency' }
              },
              meta: {
                type: :object,
                required: %w[enabled_only primary_currency enabled_currencies],
                properties: {
                  enabled_only: { type: :boolean },
                  primary_currency: { type: :string },
                  enabled_currencies: {
                    type: :array,
                    items: { type: :string }
                  }
                }
              }
            }
          },
          ExchangeRateResponse: {
            type: :object,
            required: %w[from_currency to_currency date rate same_currency],
            properties: {
              from_currency: { type: :string },
              to_currency: { type: :string },
              date: { type: :string, format: :date },
              rate: { type: :number, format: :double },
              same_currency: { type: :boolean }
            }
          },
          BudgetSummary: {
            type: :object,
            required: %w[id start_date end_date name currency initialized current created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              start_date: { type: :string, format: :date },
              end_date: { type: :string, format: :date },
              name: { type: :string },
              currency: { type: :string },
              initialized: { type: :boolean },
              current: { type: :boolean },
              budgeted_spending: { type: :string, nullable: true },
              budgeted_spending_cents: { type: :integer, nullable: true },
              expected_income: { type: :string, nullable: true },
              expected_income_cents: { type: :integer, nullable: true },
              allocated_spending: { type: :string },
              allocated_spending_cents: { type: :integer },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          Budget: {
            type: :object,
            required: %w[id start_date end_date name currency initialized current created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              start_date: { type: :string, format: :date },
              end_date: { type: :string, format: :date },
              name: { type: :string },
              currency: { type: :string },
              initialized: { type: :boolean },
              current: { type: :boolean },
              budgeted_spending: { type: :string, nullable: true },
              budgeted_spending_cents: { type: :integer, nullable: true },
              expected_income: { type: :string, nullable: true },
              expected_income_cents: { type: :integer, nullable: true },
              allocated_spending: { type: :string },
              allocated_spending_cents: { type: :integer },
              actual_spending: { type: :string },
              actual_spending_cents: { type: :integer },
              actual_income: { type: :string },
              actual_income_cents: { type: :integer },
              available_to_spend: { type: :string },
              available_to_spend_cents: { type: :integer },
              available_to_allocate: { type: :string },
              available_to_allocate_cents: { type: :integer },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          BudgetCollection: {
            type: :object,
            required: %w[currency budgets pagination],
            properties: {
              currency: { type: :string, description: 'Family primary currency' },
              budgets: {
                type: :array,
                items: { '$ref' => '#/components/schemas/BudgetSummary' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          BudgetCategorySummary: {
            type: :object,
            required: %w[id budget_id currency subcategory inherits_parent_budget category created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              budget_id: { type: :string, format: :uuid },
              currency: { type: :string },
              subcategory: { type: :boolean },
              inherits_parent_budget: { type: :boolean },
              budgeted_spending: { type: :string },
              budgeted_spending_cents: { type: :integer },
              display_budgeted_spending: { type: :string },
              display_budgeted_spending_cents: { type: :integer },
              actual_spending: { type: :string },
              actual_spending_cents: { type: :integer },
              available_to_spend: { type: :string },
              available_to_spend_cents: { type: :integer },
              avg_monthly_expense: { type: :string },
              avg_monthly_expense_cents: { type: :integer },
              median_monthly_expense: { type: :string },
              median_monthly_expense_cents: { type: :integer },
              category: {
                type: :object,
                required: %w[id name color lucide_icon],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string },
                  color: { type: :string },
                  lucide_icon: { type: :string },
                  parent_id: { type: :string, format: :uuid, nullable: true }
                }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          BudgetCategory: {
            type: :object,
            required: %w[id budget_id currency subcategory inherits_parent_budget category created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              budget_id: { type: :string, format: :uuid },
              currency: { type: :string },
              subcategory: { type: :boolean },
              inherits_parent_budget: { type: :boolean },
              budgeted_spending: { type: :string },
              budgeted_spending_cents: { type: :integer },
              display_budgeted_spending: { type: :string },
              display_budgeted_spending_cents: { type: :integer },
              actual_spending: { type: :string },
              actual_spending_cents: { type: :integer },
              available_to_spend: { type: :string },
              available_to_spend_cents: { type: :integer },
              avg_monthly_expense: { type: :string },
              avg_monthly_expense_cents: { type: :integer },
              median_monthly_expense: { type: :string },
              median_monthly_expense_cents: { type: :integer },
              category: {
                type: :object,
                required: %w[id name color lucide_icon],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string },
                  color: { type: :string },
                  lucide_icon: { type: :string },
                  parent_id: { type: :string, format: :uuid, nullable: true }
                }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          BudgetCategoryCollection: {
            type: :object,
            required: %w[budget_categories pagination],
            properties: {
              budget_categories: {
                type: :array,
                items: { '$ref' => '#/components/schemas/BudgetCategorySummary' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Balance: {
            type: :object,
            required: %w[id date currency flows_factor balance balance_cents start_balance start_balance_cents end_balance end_balance_cents account created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              currency: { type: :string },
              flows_factor: { type: :number, format: :float },
              balance: { type: :string },
              balance_cents: { type: :integer, description: 'Balance in currency minor units' },
              cash_balance: { type: :string, nullable: true },
              cash_balance_cents: { type: :integer, nullable: true, description: 'Cash balance in currency minor units' },
              start_cash_balance: { type: :string },
              start_cash_balance_cents: { type: :integer, description: 'Starting cash balance in currency minor units' },
              start_non_cash_balance: { type: :string },
              start_non_cash_balance_cents: { type: :integer, description: 'Starting non-cash balance in currency minor units' },
              start_balance: { type: :string },
              start_balance_cents: { type: :integer, description: 'Starting total balance in currency minor units' },
              cash_inflows: { type: :string },
              cash_inflows_cents: { type: :integer, description: 'Cash inflows in currency minor units' },
              cash_outflows: { type: :string },
              cash_outflows_cents: { type: :integer, description: 'Cash outflows in currency minor units' },
              non_cash_inflows: { type: :string },
              non_cash_inflows_cents: { type: :integer, description: 'Non-cash inflows in currency minor units' },
              non_cash_outflows: { type: :string },
              non_cash_outflows_cents: { type: :integer, description: 'Non-cash outflows in currency minor units' },
              net_market_flows: { type: :string },
              net_market_flows_cents: { type: :integer, description: 'Net market flows in currency minor units' },
              cash_adjustments: { type: :string },
              cash_adjustments_cents: { type: :integer, description: 'Cash adjustments in currency minor units' },
              non_cash_adjustments: { type: :string },
              non_cash_adjustments_cents: { type: :integer, description: 'Non-cash adjustments in currency minor units' },
              end_cash_balance: { type: :string },
              end_cash_balance_cents: { type: :integer, description: 'Ending cash balance in currency minor units' },
              end_non_cash_balance: { type: :string },
              end_non_cash_balance_cents: { type: :integer, description: 'Ending non-cash balance in currency minor units' },
              end_balance: { type: :string },
              end_balance_cents: { type: :integer, description: 'Ending total balance in currency minor units' },
              account: { '$ref' => '#/components/schemas/BalanceAccount' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          BalanceAccount: {
            type: :object,
            required: %w[id name account_type],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              account_type: { type: :string, nullable: true }
            }
          },
          BalanceCollection: {
            type: :object,
            required: %w[currency balances pagination],
            properties: {
              currency: { type: :string, nullable: true, description: 'Family primary currency, or account currency when filtering by account_id' },
              balances: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Balance' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Category: {
            type: :object,
            required: %w[id name color icon],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              color: { type: :string },
              icon: { type: :string }
            }
          },
          CategoryParent: {
            type: :object,
            required: %w[id name],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string }
            }
          },
          CategoryDetail: {
            type: :object,
            required: %w[id name color icon subcategories_count created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              color: { type: :string },
              icon: { type: :string },
              parent: { '$ref' => '#/components/schemas/CategoryParent', nullable: true },
              subcategories_count: { type: :integer, minimum: 0 },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          CategoryCollection: {
            type: :object,
            required: %w[categories pagination],
            properties: {
              categories: {
                type: :array,
                items: { '$ref' => '#/components/schemas/CategoryDetail' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          CategoryCreateRequest: {
            type: :object,
            required: %w[category],
            properties: {
              category: {
                type: :object,
                required: %w[name],
                properties: {
                  name: { type: :string, description: 'Category name (required, unique within family)' },
                  color: { type: :string, description: 'Hex color code (e.g. #22c55e). Defaults to #6172F3 if omitted; subcategories inherit parent color.' },
                  icon: { type: :string, description: 'Lucide icon name (e.g. "coffee"). Auto-suggested from the name when omitted.' },
                  parent_id: { type: :string, format: :uuid, nullable: true, description: 'Parent category ID. Must belong to the same family. Categories support up to 2 levels of nesting.' }
                }
              }
            }
          },
          CategoryMergeRequest: {
            type: :object,
            required: %w[target_id source_ids],
            properties: {
              target_id: { type: :string, format: :uuid },
              source_ids: {
                type: :array,
                items: { type: :string, format: :uuid },
                minItems: 1
              }
            }
          },
          CategoryMergeResponse: {
            type: :object,
            required: %w[message merged_count category],
            properties: {
              message: { type: :string },
              merged_count: { type: :integer, minimum: 1 },
              category: { '$ref' => '#/components/schemas/CategoryDetail' }
            }
          },
          CategoryReplaceAndDestroyRequest: {
            type: :object,
            properties: {
              replacement_category_id: {
                type: :string,
                format: :uuid,
                nullable: true,
                description: 'Optional family category that receives transactions from the deleted source category. Omit to leave transactions uncategorized.'
              }
            }
          },
          CategoryReplaceAndDestroyResponse: {
            type: :object,
            required: %w[message reassigned_transactions_count deleted_category replacement_category],
            properties: {
              message: { type: :string },
              reassigned_transactions_count: { type: :integer, minimum: 0 },
              deleted_category: { '$ref' => '#/components/schemas/CategoryDetail' },
              replacement_category: { '$ref' => '#/components/schemas/CategoryDetail', nullable: true }
            }
          },
          Merchant: {
            type: :object,
            required: %w[id name],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string }
            }
          },
          MerchantDetail: {
            type: :object,
            required: %w[id name type created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              type: { type: :string, enum: %w[FamilyMerchant ProviderMerchant] },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          MerchantImportResult: {
            type: :object,
            required: %w[imported skipped merchants],
            properties: {
              imported: { type: :integer, description: 'Number of merchants successfully created' },
              skipped: { type: :integer, description: 'Number of rows skipped (duplicates or invalid)' },
              merchants: { type: :array, items: { '$ref' => '#/components/schemas/MerchantDetail' } }
            }
          },
          MerchantMergeRequest: {
            type: :object,
            required: %w[target_id source_ids],
            properties: {
              target_id: { type: :string, format: :uuid },
              source_ids: {
                type: :array,
                items: { type: :string, format: :uuid },
                minItems: 1
              }
            }
          },
          MerchantMergeResponse: {
            type: :object,
            required: %w[message merged_count merchant],
            properties: {
              message: { type: :string },
              merged_count: { type: :integer, minimum: 1 },
              merchant: { '$ref' => '#/components/schemas/MerchantDetail' }
            }
          },
          MerchantEnhanceResponse: {
            type: :object,
            required: %w[message enhanceable_count],
            properties: {
              message: { type: :string },
              enhanceable_count: { type: :integer, minimum: 0 }
            }
          },
          Tag: {
            type: :object,
            required: %w[id name color],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              color: { type: :string }
            }
          },
          TagDetail: {
            type: :object,
            required: %w[id name color created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              color: { type: :string },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          TagCollection: {
            type: :array,
            items: { '$ref' => '#/components/schemas/TagDetail' }
          },
          TagDestroyAllResponse: {
            type: :object,
            required: %w[message tags_count],
            properties: {
              message: { type: :string },
              tags_count: { type: :integer, minimum: 0 }
            }
          },
          TagReplaceAndDestroyRequest: {
            type: :object,
            required: %w[replacement_tag_id],
            properties: {
              replacement_tag_id: {
                type: :string,
                format: :uuid,
                description: 'Family tag that receives all taggings from the deleted source tag.'
              }
            }
          },
          TagReplaceAndDestroyResponse: {
            type: :object,
            required: %w[message replaced_taggings_count deleted_tag replacement_tag],
            properties: {
              message: { type: :string },
              replaced_taggings_count: { type: :integer, minimum: 0 },
              deleted_tag: {
                type: :object,
                required: %w[id name],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string }
                }
              },
              replacement_tag: { '$ref' => '#/components/schemas/TagDetail' }
            }
          },
          RuleAction: {
            type: :object,
            required: %w[id action_type created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              action_type: { type: :string },
              value: { type: :string, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RuleActionInput: {
            type: :object,
            required: %w[action_type],
            properties: {
              id: { type: :string, format: :uuid, nullable: true },
              action_type: { type: :string },
              value: { type: :string, nullable: true },
              _destroy: { type: :boolean, nullable: true }
            }
          },
          RuleCondition: {
            type: :object,
            required: %w[id condition_type operator sub_conditions created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              condition_type: { type: :string },
              operator: { type: :string },
              value: { type: :string, nullable: true },
              sub_conditions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleCondition' }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RuleConditionInput: {
            type: :object,
            required: %w[condition_type operator],
            properties: {
              id: { type: :string, format: :uuid, nullable: true },
              condition_type: { type: :string },
              operator: { type: :string },
              value: { type: :string, nullable: true },
              _destroy: { type: :boolean, nullable: true },
              sub_conditions_attributes: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleConditionInput' }
              }
            }
          },
          Rule: {
            type: :object,
            required: %w[id resource_type active conditions actions created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string, nullable: true },
              resource_type: { type: :string, enum: %w[transaction] },
              active: { type: :boolean },
              effective_date: { type: :string, format: :date, nullable: true },
              conditions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleCondition' }
              },
              actions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleAction' }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RuleResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/Rule' }
            }
          },
          RuleCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Rule' }
              },
              meta: {
                type: :object,
                required: %w[current_page total_pages total_count per_page],
                properties: {
                  current_page: { type: :integer },
                  next_page: { type: :integer, nullable: true },
                  prev_page: { type: :integer, nullable: true },
                  total_pages: { type: :integer },
                  total_count: { type: :integer },
                  per_page: { type: :integer }
                }
              }
            }
          },
          RuleRun: {
            type: :object,
            required: %w[id rule_id rule_name execution_type status transactions_queued transactions_processed transactions_modified pending_jobs_count executed_at rule created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              rule_id: { type: :string, format: :uuid },
              rule_name: { type: :string, nullable: true },
              execution_type: { type: :string, enum: %w[manual scheduled] },
              status: { type: :string, enum: %w[pending success failed] },
              transactions_queued: { type: :integer, minimum: 0 },
              transactions_processed: { type: :integer, minimum: 0 },
              transactions_modified: { type: :integer, minimum: 0 },
              pending_jobs_count: { type: :integer, minimum: 0 },
              executed_at: { type: :string, format: :'date-time' },
              error_message: { type: :string, nullable: true },
              rule: {
                type: :object,
                nullable: true,
                required: %w[id resource_type active],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string, nullable: true },
                  resource_type: { type: :string },
                  active: { type: :boolean }
                }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RuleRunResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/RuleRun' }
            }
          },
          RuleRunCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleRun' }
              },
              meta: {
                type: :object,
                required: %w[current_page total_pages total_count per_page],
                properties: {
                  current_page: { type: :integer },
                  next_page: { type: :integer, nullable: true },
                  prev_page: { type: :integer, nullable: true },
                  total_pages: { type: :integer },
                  total_count: { type: :integer },
                  per_page: { type: :integer }
                }
              }
            }
          },
          Transfer: {
            type: :object,
            required: %w[id amount currency],
            properties: {
              id: { type: :string, format: :uuid },
              amount: { type: :string },
              currency: { type: :string },
              other_account: { '$ref' => '#/components/schemas/Account', nullable: true }
            }
          },
          RecurringTransaction: {
            type: :object,
            required: %w[id amount amount_cents currency expected_day_of_month last_occurrence_date next_expected_date status occurrence_count manual created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              amount: { type: :string },
              amount_cents: { type: :integer, description: 'Amount in currency minor units' },
              currency: { type: :string },
              expected_day_of_month: { type: :integer, minimum: 1, maximum: 31 },
              last_occurrence_date: { type: :string, format: :date },
              next_expected_date: { type: :string, format: :date },
              status: { type: :string, enum: %w[active inactive] },
              occurrence_count: { type: :integer, minimum: 0 },
              name: { type: :string, nullable: true },
              manual: { type: :boolean },
              expected_amount_min: { type: :string, nullable: true },
              expected_amount_min_cents: { type: :integer, nullable: true, description: 'Minimum expected amount in currency minor units' },
              expected_amount_max: { type: :string, nullable: true },
              expected_amount_max_cents: { type: :integer, nullable: true, description: 'Maximum expected amount in currency minor units' },
              expected_amount_avg: { type: :string, nullable: true },
              expected_amount_avg_cents: { type: :integer, nullable: true, description: 'Average expected amount in currency minor units' },
              account: { '$ref' => '#/components/schemas/Account', nullable: true },
              merchant: { '$ref' => '#/components/schemas/Merchant', nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RecurringTransactionCollection: {
            type: :object,
            required: %w[recurring_transactions pagination],
            properties: {
              recurring_transactions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RecurringTransaction' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          TransactionSplitInput: {
            type: :object,
            required: %w[name amount],
            properties: {
              name: { type: :string },
              amount: {
                type: :string,
                description: 'Signed display amount. Expense split lines are negative, income split lines are positive.'
              },
              category_id: { type: :string, format: :uuid, nullable: true },
              excluded: { type: :boolean, nullable: true }
            }
          },
          TransactionSplitLine: {
            type: :object,
            required: %w[entry_id transaction_id name date amount amount_cents signed_amount_cents currency excluded category],
            properties: {
              entry_id: { type: :string, format: :uuid },
              transaction_id: { type: :string, format: :uuid },
              name: { type: :string },
              date: { type: :string, format: :date },
              amount: { type: :string },
              amount_cents: { type: :integer },
              signed_amount_cents: { type: :integer },
              currency: { type: :string },
              excluded: { type: :boolean },
              category: { '$ref' => '#/components/schemas/Category', nullable: true }
            }
          },
          TransactionSplit: {
            type: :object,
            required: %w[parent child splittable parent_entry_id parent_transaction_id lines],
            properties: {
              parent: { type: :boolean },
              child: { type: :boolean },
              splittable: { type: :boolean },
              parent_entry_id: { type: :string, format: :uuid, nullable: true },
              parent_transaction_id: { type: :string, format: :uuid, nullable: true },
              lines: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionSplitLine' }
              }
            }
          },
          TransactionProtection: {
            type: :object,
            required: %w[protected locked_fields user_modified import_locked],
            properties: {
              protected: { type: :boolean },
              reason: { type: :string, nullable: true, enum: %w[excluded user_modified import_locked] },
              locked_fields: {
                type: :array,
                items: { type: :string }
              },
              user_modified: { type: :boolean },
              import_locked: { type: :boolean }
            }
          },
          TransactionDuplicateSuggestion: {
            type: :object,
            required: %w[posted_entry_id posted_transaction_id reason confidence],
            nullable: true,
            properties: {
              posted_entry_id: { type: :string, format: :uuid, nullable: true },
              posted_transaction_id: { type: :string, format: :uuid, nullable: true },
              reason: { type: :string, nullable: true },
              confidence: { type: :string, nullable: true },
              posted_amount: { type: :string, nullable: true }
            }
          },
          TransactionDuplicateCandidate: {
            type: :object,
            required: %w[entry_id transaction_id date name amount amount_cents signed_amount_cents currency account category merchant],
            properties: {
              entry_id: { type: :string, format: :uuid },
              transaction_id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              name: { type: :string },
              amount: { type: :string },
              amount_cents: { type: :integer },
              signed_amount_cents: { type: :integer },
              currency: { type: :string },
              account: { '$ref' => '#/components/schemas/Account' },
              category: { '$ref' => '#/components/schemas/Category', nullable: true },
              merchant: { '$ref' => '#/components/schemas/Merchant', nullable: true }
            }
          },
          TransactionDuplicateCandidatesResponse: {
            type: :object,
            required: %w[duplicate_candidates pagination],
            properties: {
              duplicate_candidates: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionDuplicateCandidate' }
              },
              pagination: {
                type: :object,
                required: %w[limit offset has_more],
                properties: {
                  limit: { type: :integer },
                  offset: { type: :integer },
                  has_more: { type: :boolean }
                }
              }
            }
          },
          TransactionCategorizationCategory: {
            type: :object,
            required: %w[id name color icon subcategories_count],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              color: { type: :string },
              icon: { type: :string },
              parent: { '$ref' => '#/components/schemas/CategoryParent', nullable: true },
              subcategories_count: { type: :integer, minimum: 0 }
            }
          },
          TransactionCategorizationEntry: {
            type: :object,
            required: %w[entry_id transaction_id date name amount amount_cents signed_amount_cents currency classification excluded account category merchant],
            properties: {
              entry_id: { type: :string, format: :uuid },
              transaction_id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              name: { type: :string },
              amount: { type: :string },
              amount_cents: { type: :integer },
              signed_amount_cents: { type: :integer },
              currency: { type: :string },
              classification: { type: :string },
              excluded: { type: :boolean },
              account: {
                type: :object,
                required: %w[id name account_type],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string },
                  account_type: { type: :string, nullable: true }
                }
              },
              category: { '$ref' => '#/components/schemas/TransactionCategorizationCategory', nullable: true },
              merchant: { '$ref' => '#/components/schemas/Merchant', nullable: true }
            }
          },
          TransactionCategorizationGroup: {
            type: :object,
            required: %w[grouping_key display_name transaction_type merchant entry_ids entries],
            properties: {
              grouping_key: { type: :string },
              display_name: { type: :string },
              transaction_type: { type: :string, enum: %w[income expense] },
              merchant: { '$ref' => '#/components/schemas/Merchant', nullable: true },
              entry_ids: { type: :array, items: { type: :string, format: :uuid } },
              entries: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionCategorizationEntry' }
              }
            }
          },
          TransactionCategorizationRemaining: {
            type: :object,
            required: %w[entry_ids entries all_done],
            properties: {
              entry_ids: { type: :array, items: { type: :string, format: :uuid } },
              entries: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionCategorizationEntry' }
              },
              all_done: { type: :boolean }
            }
          },
          TransactionCategorizationRuleResult: {
            type: :object,
            required: %w[requested created],
            properties: {
              requested: { type: :boolean },
              created: { type: :boolean },
              id: { type: :string, format: :uuid, nullable: true },
              name: { type: :string, nullable: true },
              resource_type: { type: :string, nullable: true },
              error: { type: :string, nullable: true }
            }
          },
          TransactionCategorizationShowResponse: {
            type: :object,
            required: %w[position all_done total_uncategorized categories group],
            properties: {
              position: { type: :integer },
              all_done: { type: :boolean },
              total_uncategorized: { type: :integer, minimum: 0 },
              categories: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionCategorizationCategory' }
              },
              group: { '$ref' => '#/components/schemas/TransactionCategorizationGroup', nullable: true }
            }
          },
          TransactionCategorizationPreviewResponse: {
            type: :object,
            required: %w[filter transaction_type total_matching pagination categories entries],
            properties: {
              filter: { type: :string },
              transaction_type: { type: :string, enum: %w[income expense], nullable: true },
              total_matching: { type: :integer, minimum: 0 },
              pagination: {
                type: :object,
                required: %w[limit offset has_more],
                properties: {
                  limit: { type: :integer },
                  offset: { type: :integer },
                  has_more: { type: :boolean }
                }
              },
              categories: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionCategorizationCategory' }
              },
              entries: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionCategorizationEntry' }
              }
            }
          },
          TransactionCategorizationCreateRequest: {
            type: :object,
            required: %w[categorization],
            properties: {
              categorization: {
                type: :object,
                required: %w[entry_ids category_id],
                properties: {
                  entry_ids: { type: :array, items: { type: :string, format: :uuid } },
                  all_entry_ids: { type: :array, items: { type: :string, format: :uuid } },
                  category_id: { type: :string, format: :uuid },
                  create_rule: { type: :boolean },
                  grouping_key: { type: :string },
                  transaction_type: { type: :string, enum: %w[income expense] }
                }
              }
            }
          },
          TransactionCategorizationCreateResponse: {
            type: :object,
            required: %w[message requested_count matched_count updated_count skipped_count category rule remaining total_uncategorized],
            properties: {
              message: { type: :string },
              requested_count: { type: :integer },
              matched_count: { type: :integer },
              updated_count: { type: :integer },
              skipped_count: { type: :integer },
              category: { '$ref' => '#/components/schemas/TransactionCategorizationCategory' },
              rule: { '$ref' => '#/components/schemas/TransactionCategorizationRuleResult' },
              remaining: { '$ref' => '#/components/schemas/TransactionCategorizationRemaining' },
              total_uncategorized: { type: :integer, minimum: 0 }
            }
          },
          TransactionCategorizationAssignmentRequest: {
            type: :object,
            required: %w[assignment],
            properties: {
              assignment: {
                type: :object,
                required: %w[entry_id category_id],
                properties: {
                  entry_id: { type: :string, format: :uuid },
                  category_id: { type: :string, format: :uuid },
                  all_entry_ids: { type: :array, items: { type: :string, format: :uuid } }
                }
              }
            }
          },
          TransactionCategorizationAssignmentResponse: {
            type: :object,
            required: %w[message entry_id transaction_id updated_count category remaining total_uncategorized],
            properties: {
              message: { type: :string },
              entry_id: { type: :string, format: :uuid },
              transaction_id: { type: :string, format: :uuid },
              updated_count: { type: :integer },
              category: { '$ref' => '#/components/schemas/TransactionCategorizationCategory' },
              remaining: { '$ref' => '#/components/schemas/TransactionCategorizationRemaining' },
              total_uncategorized: { type: :integer, minimum: 0 }
            }
          },
          DebugLogRelatedFamily: {
            type: :object,
            required: %w[id name],
            nullable: true,
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string }
            }
          },
          DebugLogRelatedAccount: {
            type: :object,
            required: %w[id name account_type],
            nullable: true,
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              account_type: { type: :string, nullable: true }
            }
          },
          DebugLogRelatedUser: {
            type: :object,
            required: %w[id email name role],
            nullable: true,
            properties: {
              id: { type: :string, format: :uuid },
              email: { type: :string, format: :email },
              name: { type: :string, nullable: true },
              role: { type: :string }
            }
          },
          DebugLogRelatedAccountProvider: {
            type: :object,
            required: %w[id account_id provider_type provider_id],
            nullable: true,
            properties: {
              id: { type: :string, format: :uuid },
              account_id: { type: :string, format: :uuid },
              provider_type: { type: :string },
              provider_id: { type: :string, format: :uuid }
            }
          },
          DebugLog: {
            type: :object,
            required: %w[id category level message source metadata family account user account_provider created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              category: { type: :string },
              level: { type: :string, enum: %w[debug info warn error] },
              message: { type: :string },
              source: { type: :string },
              provider_key: { type: :string, nullable: true },
              metadata: { type: :object },
              family: { '$ref' => '#/components/schemas/DebugLogRelatedFamily' },
              account: { '$ref' => '#/components/schemas/DebugLogRelatedAccount' },
              user: { '$ref' => '#/components/schemas/DebugLogRelatedUser' },
              account_provider: { '$ref' => '#/components/schemas/DebugLogRelatedAccountProvider' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          DebugLogFilterOptions: {
            type: :object,
            required: %w[categories levels sources provider_keys],
            properties: {
              categories: { type: :array, items: { type: :string } },
              levels: { type: :array, items: { type: :string, enum: %w[debug info warn error] } },
              sources: { type: :array, items: { type: :string } },
              provider_keys: { type: :array, items: { type: :string } }
            }
          },
          DebugLogCollection: {
            type: :object,
            required: %w[debug_logs filters pagination],
            properties: {
              debug_logs: {
                type: :array,
                items: { '$ref' => '#/components/schemas/DebugLog' }
              },
              filters: { '$ref' => '#/components/schemas/DebugLogFilterOptions' },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          DebugLogResponse: {
            type: :object,
            required: %w[debug_log],
            properties: {
              debug_log: { '$ref' => '#/components/schemas/DebugLog' }
            }
          },
          McpApplication: {
            type: :object,
            nullable: true,
            required: %w[id name uid redirect_uri confidential],
            properties: {
              id: { type: :integer },
              name: { type: :string },
              uid: { type: :string },
              redirect_uri: { type: :string },
              confidential: { type: :boolean }
            }
          },
          McpToken: {
            type: :object,
            required: %w[id scopes expires_in_seconds expires_at expired revoked_at created_at application],
            properties: {
              id: { type: :integer },
              scopes: { type: :array, items: { type: :string } },
              expires_in_seconds: { type: :integer, nullable: true },
              expires_at: { type: :string, format: :'date-time', nullable: true },
              expired: { type: :boolean },
              revoked_at: { type: :string, format: :'date-time', nullable: true },
              created_at: { type: :string, format: :'date-time' },
              application: { '$ref' => '#/components/schemas/McpApplication' }
            }
          },
          McpSettingsResponse: {
            type: :object,
            required: %w[mcp_url connected_tokens],
            properties: {
              mcp_url: { type: :string },
              connected_tokens: {
                type: :array,
                items: { '$ref' => '#/components/schemas/McpToken' }
              }
            }
          },
          McpTokenRevokeResponse: {
            type: :object,
            required: %w[message token],
            properties: {
              message: { type: :string },
              token: { '$ref' => '#/components/schemas/McpToken' }
            }
          },
          AppInfo: {
            type: :object,
            required: %w[name mode self_hosted],
            properties: {
              name: { type: :string },
              mode: { type: :string, enum: %w[managed self_hosted] },
              self_hosted: { type: :boolean }
            }
          },
          AppInfoLegalLink: {
            type: :object,
            required: %w[title url external placeholder],
            properties: {
              title: { type: :string },
              url: { type: :string },
              external: { type: :boolean },
              placeholder: { type: :string }
            }
          },
          AppInfoSupport: {
            type: :object,
            required: %w[changelog_url feature_requests_url bug_reports_url community_url],
            properties: {
              changelog_url: { type: :string },
              feature_requests_url: { type: :string },
              bug_reports_url: { type: :string },
              community_url: { type: :string }
            }
          },
          AppInfoResponse: {
            type: :object,
            required: %w[app legal support links],
            properties: {
              app: { '$ref' => '#/components/schemas/AppInfo' },
              legal: {
                type: :object,
                required: %w[privacy terms],
                properties: {
                  privacy: { '$ref' => '#/components/schemas/AppInfoLegalLink' },
                  terms: { '$ref' => '#/components/schemas/AppInfoLegalLink' }
                }
              },
              support: { '$ref' => '#/components/schemas/AppInfoSupport' },
              links: {
                type: :object,
                required: %w[changelog feedback],
                properties: {
                  changelog: { type: :string },
                  feedback: { type: :string }
                }
              }
            }
          },
          AppInfoRelease: {
            type: :object,
            required: %w[name username author_url avatar_url published_at body_html source_url],
            properties: {
              name: { type: :string },
              username: { type: :string, nullable: true },
              author_url: { type: :string, nullable: true },
              avatar_url: { type: :string, nullable: true },
              published_at: { type: :string, nullable: true },
              body_html: { type: :string },
              source_url: { type: :string }
            }
          },
          AppInfoChangelogResponse: {
            type: :object,
            required: %w[release],
            properties: {
              release: { '$ref' => '#/components/schemas/AppInfoRelease' }
            }
          },
          AppInfoFeedbackResponse: {
            type: :object,
            required: %w[support],
            properties: {
              support: { '$ref' => '#/components/schemas/AppInfoSupport' }
            }
          },
          Guide: {
            type: :object,
            required: %w[slug title format markdown byte_size updated_at],
            properties: {
              slug: { type: :string },
              title: { type: :string },
              format: { type: :string, enum: %w[markdown] },
              markdown: { type: :string },
              byte_size: { type: :integer },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          GuideResponse: {
            type: :object,
            required: %w[guide],
            properties: {
              guide: { '$ref' => '#/components/schemas/Guide' }
            }
          },
          Transaction: {
            type: :object,
            required: %w[id entry_id date amount currency name classification account tags created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              entry_id: { type: :string, format: :uuid, description: 'Ledger entry ID used by bulk transaction endpoints' },
              date: { type: :string, format: :date },
              amount: { type: :string },
              amount_cents: { type: :integer },
              signed_amount_cents: { type: :integer },
              converted_amount_cents: { type: :integer, description: 'Signed amount converted to family primary currency minor units' },
              converted_currency: { type: :string, description: 'Family primary currency used for converted_amount_cents' },
              currency: { type: :string },
              name: { type: :string },
              notes: { type: :string, nullable: true },
              external_id: { type: :string, nullable: true },
              source: { type: :string, nullable: true },
              classification: { type: :string },
              pending: { type: :boolean },
              protection: { '$ref' => '#/components/schemas/TransactionProtection' },
              duplicate_suggestion: { '$ref' => '#/components/schemas/TransactionDuplicateSuggestion' },
              account: { '$ref' => '#/components/schemas/Account' },
              category: { '$ref' => '#/components/schemas/Category', nullable: true },
              merchant: { '$ref' => '#/components/schemas/Merchant', nullable: true },
              tags: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Tag' }
              },
              attachments: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionAttachment' }
              },
              transfer: { '$ref' => '#/components/schemas/Transfer', nullable: true },
              split: { '$ref' => '#/components/schemas/TransactionSplit' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          TransactionCollection: {
            type: :object,
            required: %w[currency transactions pagination],
            properties: {
              currency: { type: :string, description: 'Family primary currency used by converted_amount_cents' },
              transactions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Transaction' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          TransferTransactionSide: {
            type: :object,
            required: %w[id entry_id date amount amount_cents currency name kind account],
            properties: {
              id: { type: :string, format: :uuid },
              entry_id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              amount: { type: :string },
              amount_cents: { type: :integer, description: 'Signed amount in currency minor units' },
              currency: { type: :string },
              name: { type: :string },
              kind: { type: :string },
              account: {
                type: :object,
                required: %w[id name account_type],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string },
                  account_type: { type: :string, nullable: true }
                }
              }
            }
          },
          TransferDecision: {
            type: :object,
            required: %w[id status date amount amount_cents currency transfer_type inflow_transaction outflow_transaction created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              status: { type: :string, enum: %w[pending confirmed] },
              date: { type: :string, format: :date },
              amount: { type: :string },
              amount_cents: { type: :integer, description: 'Absolute transfer amount in currency minor units' },
              currency: { type: :string },
              transfer_type: { type: :string, enum: %w[transfer liability_payment loan_payment] },
              notes: { type: :string, nullable: true },
              source_fee_amount: { type: :string, nullable: true, description: 'Fee charged to the source account' },
              source_fee_currency: { type: :string, nullable: true },
              destination_fee_amount: { type: :string, nullable: true, description: 'Fee deducted from the destination account' },
              destination_fee_currency: { type: :string, nullable: true },
              inflow_transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' },
              outflow_transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          TransferDecisionCollection: {
            type: :object,
            required: %w[transfers pagination],
            properties: {
              transfers: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransferDecision' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          TransferMatchTargetAccount: {
            type: :object,
            required: %w[id name account_type currency],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              account_type: { type: :string, nullable: true },
              currency: { type: :string }
            }
          },
          TransferMatchCandidate: {
            type: :object,
            required: %w[date_diff rejected inflow_transaction outflow_transaction],
            properties: {
              date_diff: { type: :integer, description: 'Absolute day difference between the two transaction dates' },
              rejected: { type: :boolean, description: 'Whether this pair was previously rejected as an auto-match suggestion' },
              inflow_transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' },
              outflow_transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' }
            }
          },
          TransferMatchOptions: {
            type: :object,
            required: %w[transaction target_accounts transfer_match_candidates],
            properties: {
              transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' },
              target_accounts: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransferMatchTargetAccount' }
              },
              transfer_match_candidates: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransferMatchCandidate' }
              }
            }
          },
          RejectedTransfer: {
            type: :object,
            required: %w[id inflow_transaction outflow_transaction created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              inflow_transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' },
              outflow_transaction: { '$ref' => '#/components/schemas/TransferTransactionSide' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          RejectedTransferCollection: {
            type: :object,
            required: %w[rejected_transfers pagination],
            properties: {
              rejected_transfers: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RejectedTransfer' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Valuation: {
            type: :object,
            required: %w[id date amount currency kind account created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              amount: { type: :string },
              currency: { type: :string },
              notes: { type: :string, nullable: true },
              kind: { type: :string },
              account: { '$ref' => '#/components/schemas/Account' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          ValuationCollection: {
            type: :object,
            required: %w[valuations pagination],
            properties: {
              valuations: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Valuation' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          ValuationPreviewMoney: {
            type: :object,
            nullable: true,
            required: %w[amount currency formatted],
            properties: {
              amount: { type: :string },
              currency: { type: :string },
              formatted: { type: :string }
            }
          },
          ValuationPreviewResponse: {
            type: :object,
            required: %w[preview],
            properties: {
              preview: {
                type: :object,
                required: %w[account valuation reconciliation],
                properties: {
                  account: {
                    type: :object,
                    required: %w[id name account_type currency balance_type],
                    properties: {
                      id: { type: :string, format: :uuid },
                      name: { type: :string },
                      account_type: { type: :string },
                      currency: { type: :string },
                      balance_type: { type: :string, enum: %w[cash non_cash investment] }
                    }
                  },
                  valuation: {
                    type: :object,
                    properties: {
                      id: { type: :string, format: :uuid },
                      account_id: { type: :string, format: :uuid },
                      date: { type: :string, format: :date },
                      amount: { type: :string },
                      notes: { type: :string, nullable: true }
                    }
                  },
                  reconciliation: {
                    type: :object,
                    required: %w[old_cash_balance old_balance new_cash_balance new_balance balance_delta cash_balance_delta],
                    properties: {
                      old_cash_balance: { '$ref' => '#/components/schemas/ValuationPreviewMoney' },
                      old_balance: { '$ref' => '#/components/schemas/ValuationPreviewMoney' },
                      new_cash_balance: { '$ref' => '#/components/schemas/ValuationPreviewMoney' },
                      new_balance: { '$ref' => '#/components/schemas/ValuationPreviewMoney' },
                      balance_delta: { '$ref' => '#/components/schemas/ValuationPreviewMoney' },
                      cash_balance_delta: { '$ref' => '#/components/schemas/ValuationPreviewMoney' }
                    }
                  }
                }
              }
            }
          },
          DeleteResponse: {
            type: :object,
            required: %w[message],
            properties: {
              message: { type: :string }
            }
          },
          TransactionResponse: {
            type: :object,
            required: %w[id date amount currency name entryable_type account],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              amount: { type: :string },
              currency: { type: :string },
              name: { type: :string },
              entryable_type: { type: :string },
              account: {
                type: :object,
                required: %w[id name account_type],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string },
                  account_type: { type: :string, nullable: true }
                }
              }
            }
          },
          ImportConfiguration: {
            type: :object,
            properties: {
              date_col_label: { type: :string, nullable: true },
              amount_col_label: { type: :string, nullable: true },
              name_col_label: { type: :string, nullable: true },
              category_col_label: { type: :string, nullable: true },
              tags_col_label: { type: :string, nullable: true },
              notes_col_label: { type: :string, nullable: true },
              account_col_label: { type: :string, nullable: true },
              date_format: { type: :string, nullable: true },
              number_format: { type: :string, nullable: true },
              signage_convention: { type: :string, nullable: true }
            }
          },
          ImportStats: {
            type: :object,
            required: %w[rows_count valid_rows_count invalid_rows_count mappings_count unassigned_mappings_count],
            properties: {
              rows_count: { type: :integer, minimum: 0 },
              valid_rows_count: { type: :integer, minimum: 0 },
              invalid_rows_count: { type: :integer, minimum: 0 },
              mappings_count: { type: :integer, minimum: 0 },
              unassigned_mappings_count: { type: :integer, minimum: 0 }
            }
          },
          ImportVerificationReadback: {
            type: :object,
            description: 'SureImport only. Expected NDJSON counts compared to family-scoped database readback after publish.',
            properties: {
              status: { type: :string, enum: %w[not_verified matched mismatch failed reverted] },
              checked_at: { type: :string, format: :'date-time', nullable: true },
              expected_record_counts: {
                type: :object,
                additionalProperties: { type: :integer }
              },
              before_counts: {
                type: :object,
                additionalProperties: { type: :integer }
              },
              after_counts: {
                type: :object,
                additionalProperties: { type: :integer }
              },
              actual_delta_counts: {
                type: :object,
                additionalProperties: { type: :integer }
              },
              checked_counts: {
                type: :object,
                additionalProperties: { type: :integer }
              },
              mismatches: {
                type: :object,
                additionalProperties: {
                  type: :object,
                  required: %w[expected actual],
                  properties: {
                    expected: { type: :integer },
                    actual: { type: :integer }
                  }
                }
              },
              error: { type: :string, nullable: true }
            }
          },
          ImportVerification: {
            type: :object,
            description: 'SureImport only. Captured at upload and completed after import publish.',
            required: %w[expected_record_counts readback],
            properties: {
              expected_record_counts: {
                type: :object,
                additionalProperties: { type: :integer }
              },
              readback: { '$ref' => '#/components/schemas/ImportVerificationReadback' }
            }
          },
          ImportPreflightContent: {
            type: :object,
            required: %w[filename content_type byte_size],
            properties: {
              filename: { type: :string },
              content_type: { type: :string },
              byte_size: { type: :integer, minimum: 0 }
            }
          },
          ImportPreflightError: {
            type: :object,
            required: %w[code message],
            properties: {
              code: { type: :string },
              message: { type: :string }
            }
          },
          ImportPreflightStats: {
            type: :object,
            required: %w[rows_count],
            properties: {
              rows_count: {
                type: :integer,
                minimum: 0,
                description: 'CSV parsed non-header rows, or nonblank Sure NDJSON lines.'
              },
              valid_rows_count: {
                type: :integer,
                minimum: 0,
                description: 'SureImport only. Valid NDJSON records.'
              },
              invalid_rows_count: {
                type: :integer,
                minimum: 0,
                description: 'SureImport only. Invalid NDJSON records. CSV malformed content returns a 422 instead.'
              },
              entity_counts: {
                type: :object,
                additionalProperties: { type: :integer },
                nullable: true
              },
              record_type_counts: {
                type: :object,
                additionalProperties: { type: :integer },
                nullable: true
              }
            }
          },
          ImportPreflight: {
            type: :object,
            required: %w[type valid content stats errors warnings],
            properties: {
              type: { type: :string, enum: Import::TYPES },
              valid: { type: :boolean },
              content: { '$ref' => '#/components/schemas/ImportPreflightContent' },
              stats: { '$ref' => '#/components/schemas/ImportPreflightStats' },
              headers: {
                type: :array,
                items: { type: :string },
                nullable: true
              },
              required_headers: {
                type: :array,
                items: { type: :string },
                nullable: true
              },
              missing_required_headers: {
                type: :array,
                items: { type: :string },
                nullable: true
              },
              errors: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ImportPreflightError' }
              },
              warnings: {
                type: :array,
                items: { type: :string }
              }
            }
          },
          ImportPreflightResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/ImportPreflight' }
            }
          },
          ImportStatusSummary: {
            type: :object,
            required: %w[uploaded configured terminal],
            properties: {
              uploaded: { type: :boolean },
              configured: { type: :boolean },
              terminal: { type: :boolean }
            }
          },
          ImportStatusDetail: {
            allOf: [
              { '$ref' => '#/components/schemas/ImportStatusSummary' },
              {
                type: :object,
                required: %w[cleaned publishable revertable],
                properties: {
                  cleaned: { type: :boolean },
                  publishable: { type: :boolean },
                  revertable: { type: :boolean }
                }
              }
            ]
          },
          ImportSummary: {
            type: :object,
            required: %w[id type status created_at updated_at status_detail],
            properties: {
              id: { type: :string, format: :uuid },
              type: { type: :string, enum: Import::TYPES },
              status: { type: :string, enum: %w[pending complete importing reverting revert_failed failed] },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' },
              account_id: { type: :string, format: :uuid, nullable: true },
              rows_count: { type: :integer, minimum: 0 },
              error: { type: :string, nullable: true },
              status_detail: { '$ref' => '#/components/schemas/ImportStatusSummary' }
            }
          },
          ImportPdfDetail: {
            type: :object,
            required: %w[pdf_uploaded ai_processed statement_with_transactions has_extracted_transactions extracted_transactions_count rows_ready_for_review account_statement],
            properties: {
              pdf_uploaded: { type: :boolean },
              pdf_filename: { type: :string, nullable: true },
              ai_processed: { type: :boolean },
              document_type: { type: :string, enum: Import::DOCUMENT_TYPES, nullable: true },
              ai_summary: { type: :string, nullable: true },
              statement_with_transactions: { type: :boolean },
              has_extracted_transactions: { type: :boolean },
              extracted_transactions_count: { type: :integer, minimum: 0 },
              rows_ready_for_review: { type: :boolean },
              account_statement: {
                allOf: [ { '$ref' => '#/components/schemas/AccountStatement' } ],
                nullable: true
              }
            }
          },
          ImportDetail: {
            type: :object,
            required: %w[id type status created_at updated_at status_detail configuration stats],
            properties: {
              id: { type: :string, format: :uuid },
              type: { type: :string, enum: Import::TYPES },
              status: { type: :string, enum: %w[pending complete importing reverting revert_failed failed] },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' },
              account_id: { type: :string, format: :uuid, nullable: true },
              error: { type: :string, nullable: true },
              status_detail: { '$ref' => '#/components/schemas/ImportStatusDetail' },
              configuration: { '$ref' => '#/components/schemas/ImportConfiguration' },
              stats: { '$ref' => '#/components/schemas/ImportStats' },
              verification: { '$ref' => '#/components/schemas/ImportVerification' },
              pdf_import: { '$ref' => '#/components/schemas/ImportPdfDetail' }
            }
          },
          ImportCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ImportSummary' }
              },
              meta: {
                type: :object,
                required: %w[current_page total_pages total_count per_page],
                properties: {
                  current_page: { type: :integer, minimum: 1 },
                  next_page: { type: :integer, nullable: true },
                  prev_page: { type: :integer, nullable: true },
                  total_pages: { type: :integer, minimum: 0 },
                  total_count: { type: :integer, minimum: 0 },
                  per_page: { type: :integer, minimum: 1 }
                }
              }
            }
          },
          ImportResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/ImportDetail' }
            }
          },
          QifDateFormatOption: {
            type: :object,
            required: %w[label format preview selected],
            properties: {
              label: { type: :string },
              format: { type: :string },
              preview: { type: :string, format: :date },
              selected: { type: :boolean }
            }
          },
          QifCategorySelectionCategory: {
            type: :object,
            required: %w[name count split recommended_selected],
            properties: {
              name: { type: :string },
              count: { type: :integer, minimum: 0 },
              split: { type: :boolean },
              recommended_selected: { type: :boolean }
            }
          },
          QifCategorySelectionTag: {
            type: :object,
            required: %w[name count recommended_selected],
            properties: {
              name: { type: :string },
              count: { type: :integer, minimum: 0 },
              recommended_selected: { type: :boolean }
            }
          },
          QifCategorySelectionStats: {
            type: :object,
            required: %w[rows_count categories_count tags_count],
            properties: {
              rows_count: { type: :integer, minimum: 0 },
              categories_count: { type: :integer, minimum: 0 },
              tags_count: { type: :integer, minimum: 0 }
            }
          },
          QifCategorySelection: {
            type: :object,
            required: %w[
              import_id account_id qif_account_type qif_date_format categories_selected
              has_split_transactions date_formats categories tags stats
            ],
            properties: {
              import_id: { type: :string, format: :uuid },
              account_id: { type: :string, format: :uuid, nullable: true },
              qif_account_type: { type: :string, nullable: true },
              qif_date_format: { type: :string },
              categories_selected: { type: :boolean },
              has_split_transactions: { type: :boolean },
              date_formats: {
                type: :array,
                items: { '$ref' => '#/components/schemas/QifDateFormatOption' }
              },
              categories: {
                type: :array,
                items: { '$ref' => '#/components/schemas/QifCategorySelectionCategory' }
              },
              tags: {
                type: :array,
                items: { '$ref' => '#/components/schemas/QifCategorySelectionTag' }
              },
              stats: { '$ref' => '#/components/schemas/QifCategorySelectionStats' }
            }
          },
          QifCategorySelectionResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/QifCategorySelection' }
            }
          },
          ImportSessionChunk: {
            type: :object,
            required: %w[id sequence status rows_count summary created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              sequence: { type: :integer, minimum: 1 },
              client_chunk_id: { type: :string, nullable: true },
              status: { type: :string, enum: %w[pending importing complete failed] },
              rows_count: { type: :integer, minimum: 0 },
              summary: {
                type: :object,
                additionalProperties: {
                  type: :object,
                  additionalProperties: { type: :integer }
                }
              },
              error: {
                type: :object,
                nullable: true,
                additionalProperties: true
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          ImportSession: {
            type: :object,
            required: %w[id type status chunks_count summary chunks created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              type: { type: :string, enum: %w[SureImport] },
              status: { type: :string, enum: %w[pending importing complete failed] },
              client_session_id: { type: :string, nullable: true },
              expected_chunks: { type: :integer, nullable: true, minimum: 1 },
              chunks_count: { type: :integer, minimum: 0 },
              summary: {
                type: :object,
                additionalProperties: {
                  type: :object,
                  additionalProperties: { type: :integer }
                }
              },
              error: {
                type: :object,
                nullable: true,
                additionalProperties: true
              },
              chunks: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ImportSessionChunk' }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          ImportSessionResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/ImportSession' }
            }
          },
          ProviderSettingField: {
            type: :object,
            required: %w[name setting_key label required secret env_present configured value_source errors],
            properties: {
              name: { type: :string },
              setting_key: { type: :string },
              label: { type: :string },
              description: { type: :string, nullable: true },
              required: { type: :boolean },
              secret: { type: :boolean },
              env_key: { type: :string, nullable: true },
              env_present: { type: :boolean },
              configured: { type: :boolean },
              value_source: { type: :string, enum: %w[setting environment default blank] },
              default: { type: :string, nullable: true },
              value: { type: :string, nullable: true, description: "Present only for non-secret fields." },
              errors: { type: :array, items: { type: :string } }
            }
          },
          ProviderSetting: {
            type: :object,
            required: %w[provider name configured fields],
            properties: {
              provider: { type: :string },
              name: { type: :string },
              description: { type: :string, nullable: true },
              configured: { type: :boolean },
              metadata: {
                type: :object,
                properties: {
                  region: { type: :string, nullable: true },
                  kinds: { type: :array, items: { type: :string } },
                  maturity: { type: :string, nullable: true },
                  tier: { type: :string, nullable: true }
                }
              },
              fields: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderSettingField' }
              }
            }
          },
          ProviderSettingsOptions: {
            type: :object,
            required: %w[redacted_secret_placeholder],
            properties: {
              redacted_secret_placeholder: { type: :string }
            }
          },
          ProviderSettingsResponse: {
            type: :object,
            required: %w[provider_settings options],
            properties: {
              provider_settings: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderSetting' }
              },
              options: { '$ref' => '#/components/schemas/ProviderSettingsOptions' }
            }
          },
          ProviderSettingsMutationResponse: {
            type: :object,
            required: %w[message provider_settings options updated_fields],
            properties: {
              message: { type: :string },
              provider_settings: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderSetting' }
              },
              options: { '$ref' => '#/components/schemas/ProviderSettingsOptions' },
              updated_fields: { type: :array, items: { type: :string } }
            }
          },
          ProviderConnectionInstitution: {
            type: :object,
            required: %w[name],
            properties: {
              name: { type: :string, nullable: true },
              domain: { type: :string, nullable: true },
              url: { type: :string, nullable: true }
            }
          },
          ProviderConnectionAccounts: {
            type: :object,
            required: %w[total_count linked_count unlinked_count],
            properties: {
              total_count: { type: :integer, minimum: 0 },
              linked_count: { type: :integer, minimum: 0 },
              unlinked_count: { type: :integer, minimum: 0 }
            }
          },
          ProviderConnectionSyncLatest: {
            type: :object,
            required: %w[id status created_at],
            properties: {
              id: { type: :string, format: :uuid },
              status: { type: :string },
              created_at: { type: :string, format: :'date-time' },
              syncing_at: { type: :string, format: :'date-time', nullable: true },
              completed_at: { type: :string, format: :'date-time', nullable: true },
              failed_at: { type: :string, format: :'date-time', nullable: true },
              error: {
                type: :object,
                nullable: true,
                description: "Sanitized latest sync error summary. Null when the latest sync is not failed or stale.",
                required: %w[present],
                properties: {
                  present: { type: :boolean, description: "Always true when this object is present." },
                  message: { type: :string, nullable: true, description: "Stable sanitized error category message; raw provider error text is never exposed." }
                }
              }
            }
          },
          ProviderConnectionSync: {
            type: :object,
            required: %w[syncing],
            properties: {
              syncing: { type: :boolean },
              status_summary: { type: :string, nullable: true },
              last_synced_at: { type: :string, format: :'date-time', nullable: true },
              latest: {
                allOf: [ { '$ref' => '#/components/schemas/ProviderConnectionSyncLatest' } ],
                nullable: true
              }
            }
          },
          ProviderConnection: {
            type: :object,
            required: %w[id provider provider_type name status requires_update credentials_configured scheduled_for_deletion pending_account_setup institution accounts sync created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              provider: { type: :string },
              provider_type: { type: :string },
              name: { type: :string },
              status: { type: :string, nullable: true },
              requires_update: { type: :boolean, nullable: true, description: "False when the provider item does not expose this status." },
              credentials_configured: { type: :boolean, nullable: true, description: "False when credential readiness is unknown." },
              scheduled_for_deletion: { type: :boolean, nullable: true, description: "False when the provider item does not expose this status." },
              pending_account_setup: { type: :boolean, nullable: true, description: "False when account setup state is unknown." },
              institution: { '$ref' => '#/components/schemas/ProviderConnectionInstitution' },
              accounts: { '$ref' => '#/components/schemas/ProviderConnectionAccounts' },
              sync: { '$ref' => '#/components/schemas/ProviderConnectionSync' },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          ProviderConnectionCollection: {
            type: :object,
            required: %w[data],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnection' }
              }
            }
          },
          ProviderConnectionSyncAction: {
            type: :object,
            required: %w[provider status scheduled total_count scheduled_count skipped_count retry_after_seconds],
            properties: {
              provider: { type: :string, nullable: true, description: "Provider key for provider-specific syncs. Null for sync_all." },
              provider_connection_id: { type: :string, format: :uuid, nullable: true, description: "Specific provider connection ID for item-level syncs." },
              mode: { type: :string, enum: %w[full balances_only], nullable: true },
              status: { type: :string, enum: %w[scheduled throttled already_syncing no_items] },
              scheduled: { type: :boolean },
              total_count: { type: :integer, minimum: 0, nullable: true },
              scheduled_count: { type: :integer, minimum: 0, nullable: true },
              skipped_count: { type: :integer, minimum: 0, nullable: true },
              retry_after_seconds: { type: :integer, minimum: 1, nullable: true }
            }
          },
          ProviderConnectionSyncActionResponse: {
            type: :object,
            required: %w[message sync data],
            properties: {
              message: { type: :string },
              sync: { '$ref' => '#/components/schemas/ProviderConnectionSyncAction' },
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnection' }
              }
            }
          },
          ProviderConnectionReplacementSuggestionDismissalResponse: {
            type: :object,
            required: %w[message provider_connection replacement_suggestion dismissed_replacement_suggestions],
            properties: {
              message: { type: :string },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              replacement_suggestion: {
                type: :object,
                required: %w[dormant_sfa_id active_sfa_id dismissal_key dismissed persisted],
                properties: {
                  dormant_sfa_id: { type: :string, format: :uuid },
                  active_sfa_id: { type: :string, format: :uuid },
                  dismissal_key: { type: :string },
                  dismissed: { type: :boolean },
                  persisted: { type: :boolean, description: "False when the connection has no sync yet, so there is no sync_stats record to update." }
                }
              },
              dismissed_replacement_suggestions: {
                type: :array,
                items: { type: :string }
              }
            }
          },
          ProviderConnectionMutationSync: {
            type: :object,
            required: %w[scheduled status],
            properties: {
              scheduled: { type: :boolean },
              status: { type: :string, enum: %w[scheduled not_scheduled] }
            }
          },
          ProviderConnectionMutationResponse: {
            type: :object,
            required: %w[message provider_connection sync data],
            properties: {
              message: { type: :string },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              sync: { '$ref' => '#/components/schemas/ProviderConnectionMutationSync' },
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnection' }
              }
            }
          },
          ProviderConnectionCoinstatsBlockchainOption: {
            type: :object,
            required: %w[label value],
            properties: {
              label: { type: :string },
              value: { type: :string }
            }
          },
          ProviderConnectionCoinstatsExchangeField: {
            type: :object,
            required: %w[key name],
            properties: {
              key: { type: :string },
              name: { type: :string }
            }
          },
          ProviderConnectionCoinstatsExchangeOption: {
            type: :object,
            required: %w[connection_id name connection_fields],
            properties: {
              connection_id: { type: :string },
              name: { type: :string },
              icon: { type: :string, nullable: true },
              connection_fields: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnectionCoinstatsExchangeField' }
              }
            }
          },
          ProviderConnectionCoinstatsOptionsResponse: {
            type: :object,
            required: %w[provider provider_connection blockchains exchanges],
            properties: {
              provider: { type: :string, enum: %w[coinstats] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              blockchains: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnectionCoinstatsBlockchainOption' }
              },
              exchanges: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnectionCoinstatsExchangeOption' }
              }
            }
          },
          ProviderConnectionCoinstatsWalletLinkResponse: {
            type: :object,
            required: %w[message provider_connection wallet data],
            properties: {
              message: { type: :string },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              wallet: {
                type: :object,
                required: %w[address blockchain created_count],
                properties: {
                  address: { type: :string },
                  blockchain: { type: :string },
                  created_count: { type: :integer, minimum: 0 }
                }
              },
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnection' }
              }
            }
          },
          ProviderConnectionCoinstatsExchangeLinkResponse: {
            type: :object,
            required: %w[message provider_connection exchange data],
            properties: {
              message: { type: :string },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              exchange: {
                type: :object,
                required: %w[connection_id name created_count],
                properties: {
                  connection_id: { type: :string },
                  name: { type: :string },
                  created_count: { type: :integer, minimum: 0 }
                }
              },
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnection' }
              }
            }
          },
          ProviderConnectionEnableBankingBank: {
            type: :object,
            required: %w[name beta psu_types auth_methods],
            properties: {
              name: { type: :string },
              country: { type: :string, nullable: true },
              bic: { type: :string, nullable: true },
              beta: { type: :boolean },
              logo: { type: :string, nullable: true },
              psu_types: {
                type: :array,
                items: { type: :string }
              },
              auth_methods: {
                type: :array,
                items: { type: :object }
              }
            }
          },
          ProviderConnectionEnableBankingBanksResponse: {
            type: :object,
            required: %w[provider provider_connection country banks],
            properties: {
              provider: { type: :string, enum: %w[enable_banking] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              country: { type: :string },
              banks: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnectionEnableBankingBank' }
              }
            }
          },
          ProviderConnectionEnableBankingAuthorizationStartResponse: {
            type: :object,
            required: %w[provider provider_connection authorization],
            properties: {
              provider: { type: :string, enum: %w[enable_banking] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              authorization: {
                type: :object,
                required: %w[redirect_url state aspsp_name psu_type authorization_id],
                properties: {
                  redirect_url: { type: :string },
                  state: { type: :string, format: :uuid },
                  aspsp_name: { type: :string, nullable: true },
                  psu_type: { type: :string, nullable: true },
                  authorization_id: { type: :string, nullable: true }
                }
              }
            }
          },
          ProviderConnectionEnableBankingAuthorizationCompleteResponse: {
            type: :object,
            required: %w[message provider provider_connection authorization sync],
            properties: {
              message: { type: :string },
              provider: { type: :string, enum: %w[enable_banking] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              authorization: {
                type: :object,
                required: %w[completed session_id_present imported_accounts_count],
                properties: {
                  completed: { type: :boolean },
                  session_id_present: { type: :boolean },
                  session_expires_at: { type: :string, format: :'date-time', nullable: true },
                  imported_accounts_count: { type: :integer, minimum: 0 }
                }
              },
              sync: { '$ref' => '#/components/schemas/ProviderConnectionMutationSync' }
            }
          },
          ProviderConnectionSophtronInstitution: {
            type: :object,
            required: %w[id name],
            properties: {
              id: { type: :string },
              name: { type: :string },
              domain: { type: :string, nullable: true },
              url: { type: :string, nullable: true },
              city: { type: :string, nullable: true },
              state: { type: :string, nullable: true },
              country: { type: :string, nullable: true }
            }
          },
          ProviderConnectionSophtronInstitutionsResponse: {
            type: :object,
            required: %w[provider provider_connection query institutions],
            properties: {
              provider: { type: :string, enum: %w[sophtron] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              query: { type: :string },
              institutions: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnectionSophtronInstitution' }
              }
            }
          },
          ProviderConnectionSophtronConnection: {
            type: :object,
            required: %w[status],
            properties: {
              status: { type: :string, enum: %w[idle connected pending completed accounts_ready mfa_required mfa_submitted failed] },
              job_id: { type: :string, nullable: true },
              user_institution_id: { type: :string, nullable: true },
              institution_id: { type: :string, nullable: true },
              institution_name: { type: :string, nullable: true },
              job_status: { type: :string, nullable: true },
              next_poll_after_seconds: { type: :integer, nullable: true },
              error_message: { type: :string, nullable: true }
            }
          },
          ProviderConnectionSophtronMfaChallenge: {
            type: :object,
            required: %w[security_questions token_methods token_sent],
            properties: {
              security_questions: {
                type: :array,
                items: { type: :object }
              },
              token_methods: {
                type: :array,
                items: { type: :object }
              },
              token_sent: { type: :boolean },
              token_read: { type: :string, nullable: true },
              captcha_image: { type: :string, nullable: true }
            }
          },
          ProviderConnectionSophtronAccountSetup: {
            type: :object,
            required: %w[pending unlinked_count provider_accounts],
            properties: {
              pending: { type: :boolean },
              unlinked_count: { type: :integer, minimum: 0 },
              provider_accounts: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderAccount' }
              }
            }
          },
          ProviderConnectionSophtronConnectResponse: {
            type: :object,
            required: %w[provider provider_connection connection],
            properties: {
              provider: { type: :string, enum: %w[sophtron] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              connection: { '$ref' => '#/components/schemas/ProviderConnectionSophtronConnection' }
            }
          },
          ProviderConnectionSophtronStatusResponse: {
            type: :object,
            required: %w[provider provider_connection connection],
            properties: {
              provider: { type: :string, enum: %w[sophtron] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              connection: { '$ref' => '#/components/schemas/ProviderConnectionSophtronConnection' },
              mfa_challenge: { '$ref' => '#/components/schemas/ProviderConnectionSophtronMfaChallenge', nullable: true },
              account_setup: { '$ref' => '#/components/schemas/ProviderConnectionSophtronAccountSetup', nullable: true }
            }
          },
          ProviderConnectionSophtronMfaSubmitResponse: {
            type: :object,
            required: %w[message provider provider_connection connection],
            properties: {
              message: { type: :string },
              provider: { type: :string, enum: %w[sophtron] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              connection: { '$ref' => '#/components/schemas/ProviderConnectionSophtronConnection' }
            }
          },
          ProviderConnectionSophtronManualSyncState: {
            type: :object,
            required: %w[enabled provider_level_enabled scoped affected_account_ids manual_account_ids],
            properties: {
              enabled: { type: :boolean },
              provider_level_enabled: { type: :boolean },
              scoped: { type: :boolean },
              affected_account_ids: {
                type: :array,
                items: { type: :string, format: :uuid }
              },
              manual_account_ids: {
                type: :array,
                items: { type: :string, format: :uuid }
              }
            }
          },
          ProviderConnectionSophtronManualSyncResponse: {
            type: :object,
            required: %w[message provider provider_connection manual_sync],
            properties: {
              message: { type: :string },
              provider: { type: :string, enum: %w[sophtron] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              manual_sync: { '$ref' => '#/components/schemas/ProviderConnectionSophtronManualSyncState' }
            }
          },
          ProviderConnectionPlaidLinkToken: {
            type: :object,
            required: %w[provider mode region link_token],
            properties: {
              provider: { type: :string, enum: %w[plaid] },
              mode: { type: :string, enum: %w[create update] },
              region: { type: :string, enum: %w[us eu] },
              provider_connection_id: { type: :string, format: :uuid, nullable: true },
              link_token: { type: :string }
            }
          },
          ProviderConnectionSnaptradeDeviceAuthorization: {
            type: :object,
            required: %w[device_code user_code verification_uri expires_in interval],
            properties: {
              device_code: { type: :string },
              user_code: { type: :string },
              verification_uri: { type: :string },
              verification_uri_complete: { type: :string, nullable: true },
              expires_in: { type: :integer, nullable: true },
              interval: { type: :integer, nullable: true },
              scope: { type: :string, nullable: true }
            }
          },
          ProviderConnectionSnaptradeOAuthStartResponse: {
            type: :object,
            required: %w[provider provider_connection device_authorization],
            properties: {
              provider: { type: :string, enum: %w[snaptrade] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              device_authorization: { '$ref' => '#/components/schemas/ProviderConnectionSnaptradeDeviceAuthorization' }
            }
          },
          ProviderConnectionSnaptradeOAuthCompleteResponse: {
            type: :object,
            required: %w[provider provider_connection oauth account_setup],
            properties: {
              provider: { type: :string, enum: %w[snaptrade] },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              oauth: {
                type: :object,
                required: %w[token_type scope expires_in expires_at],
                properties: {
                  token_type: { type: :string, nullable: true },
                  scope: { type: :string, nullable: true },
                  expires_in: { type: :integer, nullable: true },
                  expires_at: { type: :string, format: :'date-time', nullable: true }
                }
              },
              account_setup: {
                type: :object,
                required: %w[ready sync_scheduled requires_api_credentials],
                properties: {
                  ready: { type: :boolean },
                  sync_scheduled: { type: :boolean },
                  requires_api_credentials: { type: :boolean }
                }
              }
            }
          },
          ProviderConnectionDestroyAction: {
            type: :object,
            required: %w[id provider provider_type scheduled_for_deletion],
            properties: {
              id: { type: :string, format: :uuid },
              provider: { type: :string },
              provider_type: { type: :string },
              scheduled_for_deletion: { type: :boolean }
            }
          },
          ProviderConnectionDestroyActionResponse: {
            type: :object,
            required: %w[message provider_connection data],
            properties: {
              message: { type: :string },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnectionDestroyAction' },
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderConnection' }
              }
            }
          },
          ProviderAccountLinkedAccount: {
            type: :object,
            required: %w[id name account_type classification currency balance cash_balance status manual],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              account_type: { type: :string },
              subtype: { type: :string, nullable: true },
              classification: { type: :string, enum: %w[asset liability], nullable: true },
              currency: { type: :string },
              balance: { type: :string, nullable: true },
              cash_balance: { type: :string, nullable: true },
              status: { type: :string },
              manual: { type: :boolean },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          ProviderAccount: {
            type: :object,
            required: %w[id provider provider_type provider_connection_id provider_connection_type name currency linked supported_account_types created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              provider: { type: :string },
              provider_type: { type: :string },
              provider_connection_id: { type: :string, format: :uuid },
              provider_connection_type: { type: :string },
              name: { type: :string, nullable: true },
              currency: { type: :string, nullable: true },
              current_balance: { type: :string, nullable: true },
              available_balance: { type: :string, nullable: true },
              cash_balance: { type: :string, nullable: true },
              account_status: { type: :string, nullable: true },
              account_type: { type: :string, nullable: true, description: "Provider-side account type value." },
              institution: { '$ref' => '#/components/schemas/ProviderConnectionInstitution' },
              supported_account_types: {
                type: :array,
                items: { type: :string, enum: %w[Depository CreditCard Loan Investment Crypto OtherAsset] }
              },
              suggested_accountable_type: { type: :string, nullable: true },
              suggested_subtype: { type: :string, nullable: true },
              linked: { type: :boolean },
              ignored: { type: :boolean, nullable: true },
              linked_account: {
                allOf: [ { '$ref' => '#/components/schemas/ProviderAccountLinkedAccount' } ],
                nullable: true
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          ProviderAccountCollectionMeta: {
            type: :object,
            required: %w[total_count linked_count unlinked_count unlinked_only],
            properties: {
              total_count: { type: :integer, minimum: 0 },
              linked_count: { type: :integer, minimum: 0 },
              unlinked_count: { type: :integer, minimum: 0 },
              unlinked_only: { type: :boolean }
            }
          },
          ProviderAccountCollection: {
            type: :object,
            required: %w[provider_connection supported_account_types data meta],
            properties: {
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              supported_account_types: {
                type: :array,
                items: { type: :string, enum: %w[Depository CreditCard Loan Investment Crypto OtherAsset] }
              },
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ProviderAccount' }
              },
              meta: { '$ref' => '#/components/schemas/ProviderAccountCollectionMeta' }
            }
          },
          ProviderAccountSetupResponse: {
            type: :object,
            required: %w[message provider_connection provider_account account sync],
            properties: {
              message: { type: :string },
              provider_connection: { '$ref' => '#/components/schemas/ProviderConnection' },
              provider_account: { '$ref' => '#/components/schemas/ProviderAccount' },
              account: {
                allOf: [ { '$ref' => '#/components/schemas/ProviderAccountLinkedAccount' } ],
                nullable: true
              },
              sync: { '$ref' => '#/components/schemas/ProviderConnectionMutationSync' }
            }
          },
          ImportRowMapping: {
            type: :object,
            required: %w[key type value create_when_empty creatable mappable],
            properties: {
              id: { type: :string, format: :uuid },
              key: { type: :string, nullable: true },
              type: { type: :string },
              value: { type: :string, nullable: true },
              create_when_empty: { type: :boolean },
              creatable: { type: :boolean },
              mappable: {
                type: :object,
                nullable: true,
                properties: {
                  id: { type: :string, format: :uuid },
                  type: { type: :string },
                  name: { type: :string, nullable: true }
                }
              }
            }
          },
          ImportRowDiagnostic: {
            type: :object,
            required: %w[id row_number valid errors fields mappings],
            properties: {
              id: { type: :string, format: :uuid },
              row_number: { type: :integer, minimum: 1 },
              valid: { type: :boolean },
              errors: {
                type: :array,
                items: { type: :string }
              },
              fields: {
                type: :object,
                properties: {
                  account: { type: :string, nullable: true },
                  date: { type: :string, nullable: true },
                  qty: { type: :string, nullable: true },
                  ticker: { type: :string, nullable: true },
                  exchange_operating_mic: { type: :string, nullable: true },
                  price: { type: :string, nullable: true },
                  amount: { type: :string, nullable: true },
                  currency: { type: :string, nullable: true },
                  name: { type: :string, nullable: true },
                  category: { type: :string, nullable: true },
                  tags: { type: :string, nullable: true },
                  entity_type: { type: :string, nullable: true },
                  notes: { type: :string, nullable: true },
                  active: { type: :boolean, nullable: true },
                  effective_date: { type: :string, nullable: true },
                  conditions: { type: :string, nullable: true },
                  actions: { type: :string, nullable: true }
                }
              },
              mappings: {
                type: :object,
                properties: {
                  account: { '$ref' => '#/components/schemas/ImportRowMapping' },
                  category: { '$ref' => '#/components/schemas/ImportRowMapping' },
                  account_type: { '$ref' => '#/components/schemas/ImportRowMapping' },
                  tags: {
                    type: :array,
                    items: { '$ref' => '#/components/schemas/ImportRowMapping' }
                  }
                }
              }
            }
          },
          ImportRowDiagnosticCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/ImportRowDiagnostic' }
              },
              meta: {
                type: :object,
                required: %w[current_page total_pages total_count per_page],
                properties: {
                  current_page: { type: :integer, minimum: 1 },
                  next_page: { type: :integer, nullable: true },
                  prev_page: { type: :integer, nullable: true },
                  total_pages: { type: :integer, minimum: 0 },
                  total_count: { type: :integer, minimum: 0 },
                  per_page: { type: :integer, minimum: 1 }
                }
              }
            }
          },
          ImportRowDiagnosticResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/ImportRowDiagnostic' }
            }
          },
          ImportMappingResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { '$ref' => '#/components/schemas/ImportRowMapping' }
            }
          },
          SyncableSummary: {
            type: :object,
            required: %w[type id],
            properties: {
              type: { type: :string },
              id: { type: :string, format: :uuid },
              name: { type: :string, nullable: true }
            }
          },
          SyncErrorSummary: {
            type: :object,
            required: %w[message],
            properties: {
              message: { type: :string }
            }
          },
          SyncResource: {
            type: :object,
            required: %w[id status in_progress terminal syncable children_count created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              status: { type: :string, enum: %w[pending syncing completed failed stale] },
              in_progress: { type: :boolean },
              terminal: { type: :boolean },
              syncable: { '$ref' => '#/components/schemas/SyncableSummary' },
              parent_id: { type: :string, format: :uuid, nullable: true },
              children_count: { type: :integer, minimum: 0 },
              window_start_date: { type: :string, format: :date, nullable: true },
              window_end_date: { type: :string, format: :date, nullable: true },
              pending_at: { type: :string, format: :'date-time', nullable: true },
              syncing_at: { type: :string, format: :'date-time', nullable: true },
              completed_at: { type: :string, format: :'date-time', nullable: true },
              failed_at: { type: :string, format: :'date-time', nullable: true },
              error: { nullable: true, allOf: [ { '$ref' => '#/components/schemas/SyncErrorSummary' } ] },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          SyncResponse: {
            type: :object,
            required: %w[data],
            properties: {
              data: { nullable: true, allOf: [ { '$ref' => '#/components/schemas/SyncResource' } ] }
            }
          },
          SyncCollection: {
            type: :object,
            required: %w[data meta],
            properties: {
              data: {
                type: :array,
                maxItems: 100,
                items: { '$ref' => '#/components/schemas/SyncResource' }
              },
              meta: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Trade: {
            type: :object,
            required: %w[id date amount currency name qty price account created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              amount: { type: :string },
              currency: { type: :string },
              name: { type: :string },
              notes: { type: :string, nullable: true },
              qty: { type: :string },
              price: { type: :string },
              investment_activity_label: { type: :string, nullable: true },
              account: { '$ref' => '#/components/schemas/Account' },
              security: {
                type: :object,
                nullable: true,
                properties: {
                  id: { type: :string, format: :uuid },
                  ticker: { type: :string },
                  name: { type: :string, nullable: true }
                }
              },
              category: {
                type: :object,
                nullable: true,
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string }
                }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          TradeCollection: {
            type: :object,
            required: %w[trades pagination],
            properties: {
              trades: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Trade' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Holding: {
            type: :object,
            required: %w[id date qty price amount currency account security created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              qty: { type: :string, description: 'Quantity of shares held' },
              price: { type: :string, description: 'Formatted price per share' },
              amount: { type: :string },
              currency: { type: :string },
              cost_basis: { type: :string, nullable: true },
              cost_basis_source: { type: :string, nullable: true },
              cost_basis_locked: { type: :boolean },
              security_locked: { type: :boolean },
              can_delete: { type: :boolean },
              can_sync_prices: { type: :boolean },
              account: { '$ref' => '#/components/schemas/Account' },
              security: {
                type: :object,
                required: %w[id ticker name offline],
                properties: {
                  id: { type: :string, format: :uuid },
                  ticker: { type: :string },
                  name: { type: :string, nullable: true },
                  exchange_operating_mic: { type: :string, nullable: true },
                  offline: { type: :boolean }
                }
              },
              provider_security: {
                type: :object,
                nullable: true,
                properties: {
                  id: { type: :string, format: :uuid },
                  ticker: { type: :string },
                  name: { type: :string, nullable: true },
                  exchange_operating_mic: { type: :string, nullable: true }
                }
              },
              avg_cost: { type: :string, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          HoldingCollection: {
            type: :object,
            required: %w[holdings pagination],
            properties: {
              holdings: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Holding' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Security: {
            type: :object,
            required: %w[id ticker kind offline created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              ticker: { type: :string },
              name: { type: :string, nullable: true },
              kind: { type: :string, enum: %w[standard cash] },
              country_code: { type: :string, nullable: true },
              exchange_mic: { type: :string, nullable: true },
              exchange_acronym: { type: :string, nullable: true },
              exchange_operating_mic: { type: :string, nullable: true },
              exchange_name: { type: :string, nullable: true },
              offline: { type: :boolean },
              offline_reason: { type: :string, nullable: true },
              website_url: { type: :string, nullable: true },
              logo_url: { type: :string, nullable: true },
              first_provider_price_on: { type: :string, format: :date, nullable: true },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          SecurityCollection: {
            type: :object,
            required: %w[securities pagination],
            properties: {
              securities: {
                type: :array,
                items: { '$ref' => '#/components/schemas/Security' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          SecurityPrice: {
            type: :object,
            required: %w[id date price price_amount currency provisional security created_at updated_at],
            properties: {
              id: { type: :string, format: :uuid },
              date: { type: :string, format: :date },
              price: { type: :string, description: 'Formatted security price' },
              price_amount: { type: :string, description: 'Exact decimal security price' },
              currency: { type: :string },
              provisional: { type: :boolean },
              security: {
                type: :object,
                required: %w[id ticker],
                properties: {
                  id: { type: :string, format: :uuid },
                  ticker: { type: :string },
                  name: { type: :string, nullable: true },
                  exchange_operating_mic: { type: :string, nullable: true }
                }
              },
              created_at: { type: :string, format: :'date-time' },
              updated_at: { type: :string, format: :'date-time' }
            }
          },
          SecurityPriceCollection: {
            type: :object,
            required: %w[security_prices pagination],
            properties: {
              security_prices: {
                type: :array,
                items: { '$ref' => '#/components/schemas/SecurityPrice' }
              },
              pagination: { '$ref' => '#/components/schemas/Pagination' }
            }
          },
          Money: {
            type: :object,
            required: %w[amount currency formatted],
            properties: {
              amount: { type: :string, description: 'Numeric amount as string' },
              currency: { type: :string, description: 'ISO 4217 currency code' },
              formatted: { type: :string, description: 'Locale-formatted money string' }
            }
          },
          Trend: {
            type: :object,
            required: %w[value percent_formatted current previous color icon],
            properties: {
              value: { '$ref' => '#/components/schemas/Money' },
              percent: { type: :number, nullable: true },
              percent_formatted: { type: :string },
              current: { '$ref' => '#/components/schemas/Money' },
              previous: { '$ref' => '#/components/schemas/Money' },
              color: { type: :string },
              icon: { type: :string }
            }
          },
          TimeSeries: {
            type: :object,
            required: %w[start_date end_date interval trend values],
            properties: {
              start_date: { type: :string, format: :date },
              end_date: { type: :string, format: :date },
              interval: { type: :string },
              trend: { '$ref' => '#/components/schemas/Trend', nullable: true },
              values: {
                type: :array,
                items: {
                  type: :object,
                  required: %w[date date_formatted value trend],
                  properties: {
                    date: { type: :string, format: :date },
                    date_formatted: { type: :string },
                    value: { '$ref' => '#/components/schemas/Money' },
                    trend: { '$ref' => '#/components/schemas/Trend', nullable: true }
                  }
                }
              }
            }
          },
          AccountSeriesResponse: {
            type: :object,
            required: %w[account view period series],
            properties: {
              account: {
                type: :object,
                required: %w[id name currency],
                properties: {
                  id: { type: :string, format: :uuid },
                  name: { type: :string },
                  currency: { type: :string }
                }
              },
              view: { type: :string, enum: %w[balance cash_balance holdings_balance] },
              period: {
                type: :object,
                required: %w[start_date end_date interval],
                properties: {
                  start_date: { type: :string, format: :date },
                  end_date: { type: :string, format: :date },
                  interval: { type: :string }
                }
              },
              series: { '$ref' => '#/components/schemas/TimeSeries' }
            }
          },
          AccountTypeSubtype: {
            type: :object,
            required: %w[key short_name name],
            properties: {
              key: { type: :string },
              short_name: { type: :string },
              name: { type: :string },
              region: { type: :string, nullable: true },
              tax_treatment: { type: :string, nullable: true }
            }
          },
          AccountTypeProviderConnection: {
            type: :object,
            required: %w[key name can_connect supports_new_account supports_existing_account],
            properties: {
              key: { type: :string },
              name: { type: :string, nullable: true },
              description: { type: :string, nullable: true },
              can_connect: { type: :boolean },
              supports_new_account: { type: :boolean },
              supports_existing_account: { type: :boolean }
            }
          },
          AccountType: {
            type: :object,
            required: %w[type key name plural_name classification favorable_direction icon color balance_display_name opening_balance_display_name subtypes provider_connections],
            properties: {
              type: { type: :string },
              key: { type: :string },
              name: { type: :string },
              plural_name: { type: :string },
              classification: { type: :string, enum: %w[asset liability] },
              favorable_direction: { type: :string, enum: %w[up down] },
              icon: { type: :string },
              color: { type: :string },
              balance_display_name: { type: :string },
              opening_balance_display_name: { type: :string },
              default_subtype: { type: :string, nullable: true },
              subtypes: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AccountTypeSubtype' }
              },
              provider_connections: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AccountTypeProviderConnection' }
              }
            }
          },
          AccountTypeCollection: {
            type: :object,
            required: %w[data],
            properties: {
              data: {
                type: :array,
                items: { '$ref' => '#/components/schemas/AccountType' }
              }
            }
          },
          AccountableSparklineResponse: {
            type: :object,
            required: %w[accountable_type name period series],
            properties: {
              accountable_type: { type: :string },
              name: { type: :string },
              period: {
                type: :object,
                required: %w[start_date end_date interval],
                properties: {
                  start_date: { type: :string, format: :date },
                  end_date: { type: :string, format: :date },
                  interval: { type: :string }
                }
              },
              series: { '$ref' => '#/components/schemas/TimeSeries' }
            }
          },
          MonthlyDumpResponse: {
            type: :object,
            required: %w[currency period summary activity categories net_worth budget goal investments persona],
            properties: {
              currency: { type: :string },
              period: {
                type: :object,
                required: %w[month label year start_date end_date complete],
                properties: {
                  month: { type: :string, pattern: '^\d{4}-(0[1-9]|1[0-2])$' },
                  label: { type: :string },
                  year: { type: :integer },
                  start_date: { type: :string, format: :date },
                  end_date: { type: :string, format: :date },
                  complete: { type: :boolean, enum: [ true ] }
                }
              },
              summary: {
                type: :object,
                required: %w[income expenses net_savings savings_rate income_change_percent expense_change_percent],
                properties: {
                  income: { '$ref' => '#/components/schemas/Money' },
                  expenses: { '$ref' => '#/components/schemas/Money' },
                  net_savings: { '$ref' => '#/components/schemas/Money' },
                  savings_rate: { type: :number },
                  income_change_percent: { type: :number },
                  expense_change_percent: { type: :number }
                }
              },
              activity: {
                type: :object,
                required: %w[tracked_days transaction_count no_spend_days average_daily_spend busiest_day biggest_expense active_recurring_count],
                properties: {
                  tracked_days: { type: :integer, minimum: 28, maximum: 31 },
                  transaction_count: { type: :integer, minimum: 0 },
                  no_spend_days: { type: :integer, minimum: 0 },
                  average_daily_spend: { '$ref' => '#/components/schemas/Money' },
                  busiest_day: {
                    type: :object,
                    nullable: true,
                    required: %w[date label transaction_count total_spend],
                    properties: {
                      date: { type: :string, format: :date },
                      label: { type: :string },
                      transaction_count: { type: :integer, minimum: 1 },
                      total_spend: { '$ref' => '#/components/schemas/Money' }
                    }
                  },
                  biggest_expense: {
                    type: :object,
                    nullable: true,
                    required: %w[name date amount category_name category_icon],
                    properties: {
                      name: { type: :string },
                      date: { type: :string, format: :date },
                      amount: { '$ref' => '#/components/schemas/Money' },
                      category_name: { type: :string, nullable: true },
                      category_icon: { type: :string, nullable: true }
                    }
                  },
                  active_recurring_count: { type: :integer, minimum: 0 }
                }
              },
              categories: {
                type: :array,
                maxItems: 3,
                items: {
                  type: :object,
                  required: %w[category_name category_color category_icon count total],
                  properties: {
                    category_name: { type: :string },
                    category_color: { type: :string, nullable: true },
                    category_icon: { type: :string, nullable: true },
                    count: { type: :integer, minimum: 1 },
                    total: { '$ref' => '#/components/schemas/Money' }
                  }
                }
              },
              net_worth: {
                type: :object,
                required: %w[current_net_worth total_assets total_liabilities change_percent],
                properties: {
                  current_net_worth: { '$ref' => '#/components/schemas/Money' },
                  total_assets: { '$ref' => '#/components/schemas/Money' },
                  total_liabilities: { '$ref' => '#/components/schemas/Money' },
                  change_percent: { type: :number, nullable: true }
                }
              },
              budget: {
                type: :object,
                nullable: true,
                required: %w[progress progress_text status spent target],
                properties: {
                  progress: { type: :number, minimum: 0 },
                  progress_text: { type: :string },
                  status: { type: :string },
                  spent: { '$ref' => '#/components/schemas/Money' },
                  target: { '$ref' => '#/components/schemas/Money' }
                }
              },
              goal: {
                type: :object,
                nullable: true,
                required: %w[name progress progress_text current_balance target_amount],
                properties: {
                  name: { type: :string },
                  progress: { type: :number, minimum: 0, maximum: 1 },
                  progress_text: { type: :string },
                  current_balance: { '$ref' => '#/components/schemas/Money' },
                  target_amount: { '$ref' => '#/components/schemas/Money' }
                }
              },
              investments: {
                type: :object,
                required: %w[has_investments contributions trades_count],
                properties: {
                  has_investments: { type: :boolean },
                  contributions: { '$ref' => '#/components/schemas/Money' },
                  trades_count: { type: :integer, minimum: 0 }
                }
              },
              persona: {
                type: :object,
                required: %w[key title headline description closing_line symbol source],
                properties: {
                  key: { type: :string, enum: %w[investor achiever planner builder steward explorer] },
                  title: { type: :string },
                  headline: { type: :string, maxLength: 56 },
                  description: { type: :string, maxLength: 130 },
                  closing_line: { type: :string, maxLength: 48 },
                  symbol: { type: :string },
                  source: { type: :string, enum: %w[ai rules] }
                }
              }
            }
          },
          ReportResponse: {
            type: :object,
            required: %w[currency period summary trends net_worth transactions_breakdown investments],
            properties: {
              currency: { type: :string },
              period: {
                type: :object,
                required: %w[type start_date end_date previous_start_date previous_end_date],
                properties: {
                  type: { type: :string, enum: %w[monthly quarterly ytd last_6_months custom] },
                  start_date: { type: :string, format: :date },
                  end_date: { type: :string, format: :date },
                  previous_start_date: { type: :string, format: :date },
                  previous_end_date: { type: :string, format: :date }
                }
              },
              summary: {
                type: :object,
                required: %w[current_income income_change_percent current_expenses expense_change_percent net_savings],
                properties: {
                  current_income: { '$ref' => '#/components/schemas/Money' },
                  income_change_percent: { type: :number },
                  current_expenses: { '$ref' => '#/components/schemas/Money' },
                  expense_change_percent: { type: :number },
                  net_savings: { '$ref' => '#/components/schemas/Money' },
                  budget_percent: { type: :number, nullable: true }
                }
              },
              trends: {
                type: :array,
                items: {
                  type: :object,
                  required: %w[month start_date end_date current_month income expenses net],
                  properties: {
                    month: { type: :string },
                    start_date: { type: :string, format: :date },
                    end_date: { type: :string, format: :date },
                    current_month: { type: :boolean },
                    income: { '$ref' => '#/components/schemas/Money' },
                    expenses: { '$ref' => '#/components/schemas/Money' },
                    net: { '$ref' => '#/components/schemas/Money' }
                  }
                }
              },
              net_worth: {
                type: :object,
                required: %w[current_net_worth total_assets total_liabilities asset_groups liability_groups],
                properties: {
                  current_net_worth: { '$ref' => '#/components/schemas/Money' },
                  total_assets: { '$ref' => '#/components/schemas/Money' },
                  total_liabilities: { '$ref' => '#/components/schemas/Money' },
                  trend: { '$ref' => '#/components/schemas/Trend', nullable: true },
                  asset_groups: {
                    type: :array,
                    items: {
                      type: :object,
                      required: %w[name total],
                      properties: {
                        name: { type: :string },
                        total: { '$ref' => '#/components/schemas/Money' }
                      }
                    }
                  },
                  liability_groups: {
                    type: :array,
                    items: {
                      type: :object,
                      required: %w[name total],
                      properties: {
                        name: { type: :string },
                        total: { '$ref' => '#/components/schemas/Money' }
                      }
                    }
                  }
                }
              },
              transactions_breakdown: {
                type: :array,
                items: {
                  type: :object,
                  required: %w[category_id category_name type total count subcategories],
                  properties: {
                    category_id: { type: :string },
                    category_name: { type: :string },
                    category_color: { type: :string, nullable: true },
                    category_icon: { type: :string, nullable: true },
                    type: { type: :string, enum: %w[income expense] },
                    total: { '$ref' => '#/components/schemas/Money' },
                    count: { type: :integer },
                    subcategories: {
                      type: :array,
                      items: {
                        type: :object,
                        properties: {
                          category_id: { type: :string },
                          category_name: { type: :string },
                          category_color: { type: :string, nullable: true },
                          category_icon: { type: :string, nullable: true },
                          type: { type: :string, enum: %w[income expense] },
                          total: { '$ref' => '#/components/schemas/Money' },
                          count: { type: :integer }
                        }
                      }
                    }
                  }
                }
              },
              investments: {
                type: :object,
                required: %w[has_investments],
                properties: {
                  has_investments: { type: :boolean },
                  portfolio_value: { '$ref' => '#/components/schemas/Money' },
                  unrealized_trend: { '$ref' => '#/components/schemas/Trend', nullable: true },
                  period_return_trend: { '$ref' => '#/components/schemas/Trend', nullable: true },
                  period_totals: { type: :object },
                  flows: { type: :object },
                  top_holdings: { type: :array, items: { type: :object } },
                  accounts: { type: :array, items: { type: :object } },
                  gains_by_tax_treatment: { type: :object }
                }
              }
            }
          },
          BalanceSheet: {
            type: :object,
            required: %w[currency net_worth assets liabilities asset_groups liability_groups],
            properties: {
              currency: { type: :string, description: 'Family primary currency' },
              net_worth: { '$ref' => '#/components/schemas/Money' },
              assets: { '$ref' => '#/components/schemas/Money' },
              liabilities: { '$ref' => '#/components/schemas/Money' },
              asset_groups: {
                type: :array,
                items: { '$ref' => '#/components/schemas/BalanceSheetAccountGroup' }
              },
              liability_groups: {
                type: :array,
                items: { '$ref' => '#/components/schemas/BalanceSheetAccountGroup' }
              }
            }
          },
          BalanceSheetAccountGroup: {
            type: :object,
            required: %w[name account_type classification total weight accounts],
            properties: {
              name: { type: :string },
              color: { type: :string, nullable: true },
              account_type: { type: :string },
              classification: { type: :string, enum: %w[asset liability] },
              total: { '$ref' => '#/components/schemas/Money' },
              weight: { type: :number },
              accounts: {
                type: :array,
                items: { '$ref' => '#/components/schemas/BalanceSheetAccount' }
              }
            }
          },
          BalanceSheetAccount: {
            type: :object,
            required: %w[id name currency balance converted_balance classification account_type weight],
            properties: {
              id: { type: :string, format: :uuid },
              name: { type: :string },
              currency: { type: :string, description: 'Account native currency' },
              balance: { '$ref' => '#/components/schemas/Money' },
              converted_balance: {
                '$ref' => '#/components/schemas/Money',
                description: 'Account balance converted to the family primary currency'
              },
              classification: { type: :string, enum: %w[asset liability] },
              account_type: { type: :string },
              weight: { type: :number }
            }
          },
          SuccessMessage: {
            type: :object,
            required: %w[message],
            properties: {
              message: { type: :string }
            }
          },
          ResetInitiatedResponse: {
            type: :object,
            required: %w[message status job_id family_id sample_data status_url],
            properties: {
              message: { type: :string },
              status: { type: :string, enum: %w[queued] },
              job_id: {
                type: :string,
                description: 'Informational Active Job identifier returned by the queue adapter; reset status is family-scoped, not job-scoped.'
              },
              family_id: { type: :string, format: :uuid, description: 'UUID of the family being reset.' },
              sample_data: {
                type: :boolean,
                description: 'True when the queued reset will load demo sample data after clearing existing financial data.'
              },
              status_url: { type: :string }
            }
          },
          ResetStatusResponse: {
            type: :object,
            required: %w[status family_id reset_complete counts],
            properties: {
              status: {
                type: :string,
                enum: %w[complete data_remaining],
                description: 'Counts-based family reset status at response time.'
              },
              family_id: { type: :string, format: :uuid, description: 'UUID of the family whose reset target counts were checked.' },
              reset_complete: {
                type: :boolean,
                description: 'True when all reset target counts are zero at response time. This is a family data snapshot, not a durable per-job completion record.'
              },
              counts: {
                type: :object,
                required: reset_count_keys,
                additionalProperties: { type: :integer, minimum: 0 },
                properties: reset_count_keys.index_with { { type: :integer, minimum: 0 } }
              }
            }
          }
        }
      }
    }
  }

  config.openapi_format = :yaml
end
