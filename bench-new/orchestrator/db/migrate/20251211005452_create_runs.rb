class CreateRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :runs do |t|
      t.string :ruby_version, null: false
      t.integer :runs_per_instance_type, null: false
      t.string :status, null: false, default: 'running'
      t.bigint :external_id, null: false
      t.string :gzip_url

      t.timestamps
    end

    add_index :runs, :external_id, unique: true
    add_index :runs, :status
  end
end
