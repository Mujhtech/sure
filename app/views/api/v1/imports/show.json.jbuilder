rows = @import.rows.to_a
valid_rows_count = rows.count(&:valid?)
invalid_rows_count = rows.length - valid_rows_count
cleaned = @import.cleaned_from_validation_stats?(invalid_rows_count: invalid_rows_count)
publishable = @import.publishable_from_validation_stats?(invalid_rows_count: invalid_rows_count)
mapping_counts = @import.mapping_status_counts

json.data do
  json.id @import.id
  json.type @import.type
  json.status @import.status
  json.created_at @import.created_at
  json.updated_at @import.updated_at
  json.account_id @import.account_id
  json.error @import.error if @import.error.present?
  json.status_detail do
    json.partial! "status_detail",
                  import: @import,
                  include_validation_stats: true,
                  valid_rows_count: valid_rows_count,
                  invalid_rows_count: invalid_rows_count,
                  cleaned: cleaned,
                  publishable: publishable
  end

  json.configuration do
    json.date_col_label @import.date_col_label
    json.amount_col_label @import.amount_col_label
    json.name_col_label @import.name_col_label
    json.category_col_label @import.category_col_label
    json.tags_col_label @import.tags_col_label
    json.notes_col_label @import.notes_col_label
    json.account_col_label @import.account_col_label
    json.qty_col_label @import.qty_col_label
    json.ticker_col_label @import.ticker_col_label
    json.price_col_label @import.price_col_label
    json.entity_type_col_label @import.entity_type_col_label
    json.currency_col_label @import.currency_col_label
    json.exchange_operating_mic_col_label @import.exchange_operating_mic_col_label
    json.date_format @import.date_format
    json.number_format @import.number_format
    json.signage_convention @import.signage_convention
    json.col_sep @import.col_sep
    json.amount_type_strategy @import.amount_type_strategy
    json.amount_type_identifier_value @import.amount_type_identifier_value
    json.amount_type_inflow_value @import.amount_type_inflow_value
    json.rows_to_skip @import.rows_to_skip
  end

  if @import.uploaded? && @import.requires_csv_workflow?
    json.csv_headers @import.csv_headers
  end

  json.stats do
    json.rows_count @import.rows_count
    json.valid_rows_count valid_rows_count
    json.invalid_rows_count invalid_rows_count
    json.mappings_count mapping_counts[:mappings_count]
    json.unassigned_mappings_count mapping_counts[:unassigned_mappings_count]
  end

  json.verification @import.verification_payload if @import.is_a?(SureImport)

  if @import.is_a?(PdfImport)
    json.pdf_import do
      json.pdf_uploaded @import.pdf_uploaded?
      json.pdf_filename @import.pdf_filename
      json.ai_processed @import.ai_processed?
      json.document_type @import.document_type
      json.ai_summary @import.ai_summary
      json.statement_with_transactions @import.statement_with_transactions?
      json.has_extracted_transactions @import.has_extracted_transactions?
      json.extracted_transactions_count @import.extracted_transactions.size
      json.rows_ready_for_review @import.pending? && @import.rows_count.positive?

      if @import.account_statement.present?
        json.account_statement do
          json.partial! "api/v1/account_statements/account_statement", account_statement: @import.account_statement
        end
      else
        json.account_statement nil
      end
    end
  end

  # Only show a subset of rows for preview if needed, or link to a separate rows endpoint
  # json.sample_rows @import.rows.limit(5)
end
