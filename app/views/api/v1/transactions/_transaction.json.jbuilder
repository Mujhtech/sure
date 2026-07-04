# frozen_string_literal: true

json.id transaction.id
json.entry_id transaction.entry.id
json.date transaction.entry.date
json.amount transaction.entry.amount_money.format

# Agent/automation-friendly numeric fields (avoid localized parsing and clarify sign)
# `amount` in v1 is a localized string and may follow an accounting sign convention.
# Expose minor units (cents) as integers to make the API agent-friendly.
# Uses currency.minor_unit_conversion (e.g. 100 for USD/EUR, 1 for JPY, 1000 for KWD).
amount_money = transaction.entry.amount_money
conversion_factor = amount_money.currency.minor_unit_conversion
amount_cents = (amount_money.amount * conversion_factor).round(0).to_i.abs
json.amount_cents amount_cents
json.signed_amount_cents(transaction.entry.classification == "income" ? amount_cents : -amount_cents)

json.currency transaction.entry.currency
json.name transaction.entry.name
json.notes transaction.entry.notes
json.external_id transaction.entry.external_id
json.source transaction.entry.source
json.classification transaction.entry.classification
json.pending transaction.pending?
json.protection do
  json.protected transaction.entry.protected_from_sync?
  json.reason transaction.entry.protection_reason
  json.locked_fields transaction.entry.locked_field_names
  json.user_modified transaction.entry.user_modified?
  json.import_locked transaction.entry.import_locked?
end

if transaction.has_potential_duplicate?
  duplicate_entry = transaction.potential_duplicate_entry
  json.duplicate_suggestion do
    json.posted_entry_id duplicate_entry&.id
    json.posted_transaction_id duplicate_entry&.entryable_id
    json.reason transaction.potential_duplicate_reason
    json.confidence transaction.potential_duplicate_confidence
    json.posted_amount transaction.potential_duplicate_posted_amount&.to_s
  end
else
  json.duplicate_suggestion nil
end

# Account information
json.account do
  json.id transaction.entry.account.id
  json.name transaction.entry.account.name
  json.account_type transaction.entry.account.accountable_type.underscore
end

# Category information
if transaction.category.present?
  json.category do
    json.id transaction.category.id
    json.name transaction.category.name
    json.color transaction.category.color
    json.icon transaction.category.lucide_icon
  end
else
  json.category nil
end

# Merchant information
if transaction.merchant.present?
  json.merchant do
    json.id transaction.merchant.id
    json.name transaction.merchant.name
  end
else
  json.merchant nil
end

# Tags
json.tags transaction.tags do |tag|
  json.id tag.id
  json.name tag.name
  json.color tag.color
end

json.attachments transaction.attachments do |attachment|
  json.partial! "api/v1/transaction_attachments/attachment", transaction: transaction, attachment: attachment
end

# Transfer information (if this transaction is part of a transfer)
transfer = transaction.transfer
if transfer.present?
  json.transfer do
    json.id transfer.id

    # Other transaction in the transfer
    if transfer.inflow_transaction_id == transaction.id
      inflow_transaction = transaction
      other_transaction = transfer.outflow_transaction
    else
      inflow_transaction = transfer.inflow_transaction
      # When rendering the outflow, the inflow is the counterparty transaction.
      other_transaction = inflow_transaction
    end

    json.amount inflow_transaction.entry.amount_money.abs.format
    json.currency inflow_transaction.entry.currency

    if other_transaction.present?
      json.other_account do
        json.id other_transaction.entry.account.id
        json.name other_transaction.entry.account.name
        json.account_type other_transaction.entry.account.accountable_type.underscore
      end
    end
  end
else
  json.transfer nil
end

entry = transaction.entry
json.split do
  json.parent entry.split_parent?
  json.child entry.split_child?
  json.splittable transaction.splittable?

  if entry.split_child?
    parent_entry = entry.parent_entry
    json.parent_entry_id parent_entry.id
    json.parent_transaction_id parent_entry.entryable_id
  else
    json.parent_entry_id nil
    json.parent_transaction_id nil
  end

  if entry.split_parent?
    children = entry.child_entries.includes(entryable: [ :category, :merchant ]).order(:created_at, :id)
    json.lines children do |child|
      child_transaction = child.entryable
      child_money = child.amount_money
      child_conversion_factor = child_money.currency.minor_unit_conversion
      child_amount_cents = (child_money.amount * child_conversion_factor).round(0).to_i.abs

      json.entry_id child.id
      json.transaction_id child_transaction.id
      json.name child.name
      json.date child.date
      json.amount child_money.format
      json.amount_cents child_amount_cents
      json.signed_amount_cents(child.classification == "income" ? child_amount_cents : -child_amount_cents)
      json.currency child.currency
      json.excluded child.excluded?

      if child_transaction.category.present?
        json.category do
          json.id child_transaction.category.id
          json.name child_transaction.category.name
          json.color child_transaction.category.color
          json.icon child_transaction.category.lucide_icon
        end
      else
        json.category nil
      end
    end
  else
    json.lines []
  end
end

# Additional metadata
json.created_at transaction.created_at.iso8601
json.updated_at transaction.updated_at.iso8601
