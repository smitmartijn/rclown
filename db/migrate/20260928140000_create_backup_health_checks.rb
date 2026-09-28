class CreateBackupHealthChecks < ActiveRecord::Migration[8.1]
  def change
    create_table :backup_health_checks do |t|
      t.references :backup, null: false, index: { unique: true }, foreign_key: true
      t.datetime :requested_at
      t.datetime :checked_at
      t.string :configuration_digest
      t.json :results, default: {}, null: false
      t.timestamps
    end
  end
end
