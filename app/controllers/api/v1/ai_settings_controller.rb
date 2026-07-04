# frozen_string_literal: true

class Api::V1::AiSettingsController < Api::V1::BaseController
  before_action :ensure_read_scope

  def show
    user = current_resource_owner
    assistant_config = Assistant.config_for(OpenStruct.new(user: user))

    render_json({
      ai: ai_payload(user),
      prompts: prompt_payloads(assistant_config),
      functions: assistant_functions(assistant_config)
    })
  end

  private
    def ai_payload(user)
      {
        enabled: user.ai_enabled?,
        requested_enabled: user.ai_enabled,
        available: user.ai_available?,
        show_sidebar: user.show_ai_sidebar?,
        assistant_type: effective_assistant_type(user),
        available_assistant_types: Assistant.available_types,
        default_model: Chat.default_model,
        rule_prompts_disabled: user.rule_prompts_disabled?,
        rule_prompt_dismissed_at: user.rule_prompt_dismissed_at&.iso8601
      }
    end

    def prompt_payloads(assistant_config)
      [
        {
          key: "main_system_prompt",
          model: Chat.default_model,
          instructions: assistant_config[:instructions]
        },
        {
          key: "transaction_categorizer",
          model: Provider::Openai::DEFAULT_MODEL,
          instructions: Provider::Openai::AutoCategorizer.new(nil).instructions
        },
        {
          key: "merchant_detector",
          model: Provider::Openai::DEFAULT_MODEL,
          instructions: Provider::Openai::AutoMerchantDetector.new(nil, transactions: [], user_merchants: []).instructions
        }
      ]
    end

    def assistant_functions(assistant_config)
      Array(assistant_config[:functions]).map do |function_class|
        {
          key: function_class.name.demodulize.underscore,
          class_name: function_class.name
        }
      end
    end

    def effective_assistant_type(user)
      assistant_type = ENV["ASSISTANT_TYPE"].presence || user.family&.assistant_type.presence || "builtin"
      Assistant.available_types.include?(assistant_type) ? assistant_type : "builtin"
    end
end
