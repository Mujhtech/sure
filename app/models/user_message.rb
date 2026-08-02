class UserMessage < Message
  validates :ai_model, presence: true

  after_create_commit :request_response_later

  # Creates a user message, optionally with a file attachment. The upload is
  # routed into an assistant-readable pipeline (bank statement import or the
  # family document store) BEFORE the message is committed, so the appended
  # context annotation is visible to the assistant when it responds.
  def self.compose!(chat:, content:, ai_model:, upload: nil, user: nil)
    body = content.to_s.strip

    if upload.present?
      context = Chat::UploadRouter.new(user).route(upload)
      body = "I've attached a file: #{upload.original_filename}" if body.blank?
      body = [ body, context ].compact_blank.join("\n\n")
    end

    message = new(chat: chat, content: body, ai_model: ai_model)

    if upload.present?
      upload.rewind if upload.respond_to?(:rewind)
      message.attachment.attach(upload)
    end

    message.save!
    message
  end

  def role
    "user"
  end

  def request_response_later
    chat.ask_assistant_later(self)
  end

  def request_response(assistant_message: nil)
    chat.ask_assistant(self, assistant_message: assistant_message)
  end
end
