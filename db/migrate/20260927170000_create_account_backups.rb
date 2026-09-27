class CreateAccountBackups < ActiveRecord::Migration[8.1]
  def change
    create_table :account_backups do |t|
      t.string :name, null: false
      t.references :source_provider, null: false, foreign_key: { to_table: :providers }, index: { unique: true }
      t.references :destination_storage, null: false, foreign_key: { to_table: :storages }
      t.string :destination_prefix
      t.datetime :activated_at
      t.boolean :discovery_enabled, null: false, default: true
      t.integer :discovery_interval_minutes, null: false, default: 60
      t.datetime :next_discovery_at
      t.string :schedule, null: false, default: "daily"
      t.integer :comparison_mode, null: false, default: 0
      t.integer :retention_days, null: false, default: 30
      t.boolean :verify_enabled, null: false, default: true
      t.decimal :verify_tolerance_percent, null: false, default: "0.1"
      t.boolean :backups_enabled, null: false, default: true
      t.json :excluded_buckets, null: false, default: []
      t.json :excluded_patterns, null: false, default: []
      t.timestamps
    end

    create_table :account_backup_buckets do |t|
      t.references :account_backup, null: false, foreign_key: true
      t.string :bucket_name, null: false
      t.references :backup, foreign_key: true, index: { unique: true }
      t.boolean :available, null: false, default: true
      t.datetime :last_seen_at
      t.string :resolution
      t.string :last_error
      t.timestamps
      t.index [ :account_backup_id, :bucket_name ], unique: true
    end

    create_table :account_backup_discovery_runs do |t|
      t.references :account_backup, null: false, foreign_key: true
      t.boolean :preview, null: false, default: false
      t.string :status, null: false, default: "pending"
      t.datetime :started_at
      t.datetime :finished_at
      t.json :results, null: false, default: []
      t.json :counts, null: false, default: {}
      t.string :error
      t.timestamps
    end
  end
end
