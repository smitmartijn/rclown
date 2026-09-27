class AddLocalFilesystemToProviders < ActiveRecord::Migration[8.1]
  def change
    add_column :providers, :base_path, :string
    change_column_null :providers, :access_key_id, true
    change_column_null :providers, :secret_access_key, true
  end
end
