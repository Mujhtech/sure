class Assistant::Responder
  MAX_TOOL_CALL_ROUNDS = 6
  EmptyResponseError = Class.new(StandardError)
  ToolCallLimitError = Class.new(StandardError)

  def initialize(message:, instructions:, function_tool_caller:, llm:)
    @message = message
    @instructions = instructions
    @function_tool_caller = function_tool_caller
    @llm = llm
  end

  def on(event_name, &block)
    listeners[event_name.to_sym] << block
  end

  def respond(previous_response_id: nil)
    current_previous_response_id = previous_response_id
    latest_function_results = []
    accumulated_function_results = []
    tool_rounds = 0

    loop do
      emitted_output_text = false
      response = get_llm_response(
        streamer: output_text_streamer { emitted_output_text = true },
        function_results: function_results_for_request(
          latest: latest_function_results,
          accumulated: accumulated_function_results
        ),
        previous_response_id: current_previous_response_id
      )
      raise EmptyResponseError, "LLM returned an empty response" unless response

      if Array(response.function_requests).any?
        if tool_rounds >= MAX_TOOL_CALL_ROUNDS
          raise ToolCallLimitError,
                "Assistant reached the maximum of #{MAX_TOOL_CALL_ROUNDS} tool-call rounds before producing an answer"
        end

        tool_rounds += 1
        function_tool_calls = function_tool_caller.fulfill_requests(response.function_requests)
        latest_function_results = function_tool_calls.map do |tool_call|
          tool_call.to_result.merge(tool_round: tool_rounds)
        end
        accumulated_function_results.concat(latest_function_results)
        current_previous_response_id = response.id

        emit(:response, {
          id: response.id,
          function_tool_calls: function_tool_calls
        })

        next
      end

      unless response_has_text?(response) || emitted_output_text
        raise EmptyResponseError, "LLM returned an empty response"
      end

      emit(:response, { id: response.id })
      break
    end
  end

  private
    attr_reader :message, :instructions, :function_tool_caller, :llm

    def output_text_streamer(&on_output_text)
      proc do |chunk|
        case chunk.type
        when "output_text"
          on_output_text.call if chunk.data.present?
          emit(:output_text, chunk.data)
        end
      end
    end

    def response_has_text?(response)
      Array(response&.messages).any? { |message| message.output_text.to_s.present? }
    end

    def function_results_for_request(latest:, accumulated:)
      uses_responses_endpoint? ? latest : accumulated
    end

    def uses_responses_endpoint?
      llm.respond_to?(:supports_responses_endpoint?) && llm.supports_responses_endpoint?
    end

    def get_llm_response(streamer:, function_results: [], previous_response_id: nil)
      response = llm.chat_response(
        message.content,
        model: message.ai_model,
        instructions: instructions,
        functions: function_tool_caller.function_definitions,
        function_results: function_results,
        messages: openai_messages_payload,
        conversation_history: chat_message_records,
        streamer: streamer,
        previous_response_id: previous_response_id,
        session_id: chat_session_id,
        user_identifier: chat_user_identifier,
        family: message.chat&.user&.family
      )

      unless response.success?
        raise response.error
      end

      response.data
    end

    def emit(event_name, payload = nil)
      listeners[event_name.to_sym].each { |block| block.call(payload) }
    end

    def listeners
      @listeners ||= Hash.new { |h, k| h[k] = [] }
    end

    def chat_session_id
      chat&.id&.to_s
    end

    def chat_user_identifier
      return unless chat&.user_id

      ::Digest::SHA256.hexdigest(chat.user_id.to_s)
    end

    def chat
      @chat ||= message.chat
    end

    # Memoized fetch — both `chat_message_records` and `openai_messages_payload`
    # derive their shape from this one in-memory array so a single chat turn
    # fires one history query instead of two.
    def complete_chat_messages
      return @complete_chat_messages if defined?(@complete_chat_messages)

      @complete_chat_messages =
        if chat&.messages
          chat.messages
              .where(type: [ "UserMessage", "AssistantMessage" ], status: "complete")
              .includes(:tool_calls)
              .ordered
              .to_a
        else
          []
        end
    end

    # Raw Message records preceding the current turn — providers that build
    # their own native message shape (Anthropic) consume this directly so they
    # do not have to round-trip through the OpenAI-shaped payload below.
    def chat_message_records
      complete_chat_messages.reject { |m| m.id == message.id }
    end

    # Builds the OpenAI-shaped messages payload (role: "user" | "assistant" |
    # "tool"; tool_call_id pairing) consumed by Provider::Openai's generic
    # chat path. Anthropic uses chat_message_records instead.
    def openai_messages_payload
      messages = []
      complete_chat_messages.each do |chat_message|
        if chat_message.tool_calls.any?
          valid_tool_calls = ordered_tool_calls(chat_message).select do |tool_call|
            tool_call_identifier(tool_call).present?
          end

          valid_tool_calls.each do |tool_call|
            messages << {
              role: chat_message.role,
              content: "",
              tool_calls: [ tool_call_payload(tool_call) ]
            }
            messages << tool_result_payload(tool_call)
          end

          if chat_message.content.present?
            messages << { role: chat_message.role, content: chat_message.content || "" }
          end
        elsif !chat_message.content.blank?
          messages << { role: chat_message.role, content: chat_message.content || "" }
        end
      end
      messages
    end

    def ordered_tool_calls(chat_message)
      chat_message.tool_calls.sort_by do |tool_call|
        [ tool_call.created_at || Time.zone.at(0), tool_call.id.to_s ]
      end
    end

    def tool_call_identifier(tool_call)
      tool_call.provider_call_id.presence || tool_call.provider_id.presence
    end

    def tool_call_payload(tool_call)
      arguments = tool_call.function_arguments
      arguments_str = if arguments.nil?
        "{}"
      elsif arguments.is_a?(String)
        arguments
      else
        arguments.to_json
      end

      {
        id: tool_call_identifier(tool_call),
        type: "function",
        function: {
          name: tool_call.function_name,
          arguments: arguments_str
        }
      }
    end

    def tool_result_payload(tool_call)
      output = tool_call.function_result
      content = if output.nil?
        ""
      elsif output.is_a?(String)
        output
      else
        output.to_json
      end

      {
        role: "tool",
        tool_call_id: tool_call_identifier(tool_call),
        name: tool_call.function_name,
        content: content
      }
    end
end
