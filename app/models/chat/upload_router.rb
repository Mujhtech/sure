# frozen_string_literal: true

# Routes a file uploaded with a chat message into the pipeline that makes it
# usable by the assistant, and returns a context annotation appended to the
# user message so the model knows what arrived and which tool can read it.
#
# - PDFs (from statement managers) become a PdfImport with AI extraction, so
#   the assistant can call import_bank_statement with the returned id.
# - Other supported document types go to the family's vector document store,
#   queryable via search_family_files.
# - Everything else is just stored on the message.
class Chat::UploadRouter
  MAX_SIZE = Import::MAX_PDF_SIZE

  def initialize(user)
    @user = user
  end

  def route(upload)
    filename = upload.original_filename.to_s

    if pdf?(upload) && AccountStatement.statement_manager?(user)
      route_pdf(upload, filename)
    elsif document_store_supported?(filename)
      route_document(upload, filename)
    else
      "[Attached file: #{filename} (#{upload.content_type}). It is stored with this message but cannot be analyzed automatically.]"
    end
  end

  private
    attr_reader :user

    def family
      user.family
    end

    def pdf?(upload)
      Import::ALLOWED_PDF_MIME_TYPES.include?(upload.content_type)
    end

    def document_store_supported?(filename)
      FamilyDocument::SUPPORTED_EXTENSIONS.include?(File.extname(filename).downcase)
    end

    def route_pdf(upload, filename)
      pdf_import = PdfImport.create_from_upload!(family: family, file: upload, user: user)
      pdf_import.process_with_ai_later

      "[Attached file: #{filename} — uploaded as a bank statement and queued for AI extraction. " \
        "To import its transactions, call import_bank_statement with pdf_import_id: '#{pdf_import.id}'. " \
        "Extraction can take a minute; the function reports status if it is not ready yet.]"
    rescue AccountStatement::DuplicateUploadError
      "[Attached file: #{filename} — this bank statement was uploaded before by another family member. " \
        "Use get_transactions or ask the user how to proceed.]"
    rescue AccountStatement::InvalidUploadError
      "[Attached file: #{filename} — the PDF could not be processed as a bank statement. It is stored with this message.]"
    ensure
      upload.rewind if upload.respond_to?(:rewind)
    end

    def route_document(upload, filename)
      content = upload.read
      upload.rewind if upload.respond_to?(:rewind)

      document = family.upload_document(
        file_content: content,
        filename: filename,
        metadata: { "source" => "chat" }
      )

      if document
        "[Attached file: #{filename} — added to the family document store. Use search_family_files to answer questions about its contents.]"
      else
        "[Attached file: #{filename} — stored with this message. The document search store is not configured, so its contents cannot be searched.]"
      end
    end
end
