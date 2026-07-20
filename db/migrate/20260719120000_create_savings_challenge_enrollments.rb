class CreateSavingsChallengeEnrollments < ActiveRecord::Migration[7.2]
  def change
    create_table :savings_challenge_enrollments, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :goal, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.string :campaign_key, null: false
      t.decimal :target_amount, precision: 19, scale: 4, null: false
      t.decimal :starting_balance, precision: 19, scale: 4, null: false, default: 0
      t.datetime :joined_at, null: false

      t.timestamps
    end

    add_index :savings_challenge_enrollments,
              [ :family_id, :campaign_key ],
              unique: true,
              name: "index_savings_challenge_enrollments_on_family_and_campaign"
    add_check_constraint :savings_challenge_enrollments,
                         "target_amount > 0",
                         name: "chk_savings_challenge_target_amount_positive"
    add_check_constraint :savings_challenge_enrollments,
                         "starting_balance >= 0",
                         name: "chk_savings_challenge_starting_balance_nonnegative"
  end
end
