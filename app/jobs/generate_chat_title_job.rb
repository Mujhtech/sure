# frozen_string_literal: true

# Replaces a new chat's truncated-prompt placeholder title with a concise
# LLM-generated title. Best-effort: failures leave the placeholder in place.
class GenerateChatTitleJob < ApplicationJob
  queue_as :low_priority

  discard_on ActiveJob::DeserializationError

  def perform(chat)
    chat.auto_generate_title!
  rescue StandardError => e
    Rails.logger.warn("[GenerateChatTitleJob] Failed to auto-title chat #{chat.id}: #{e.message}")
  end
end
