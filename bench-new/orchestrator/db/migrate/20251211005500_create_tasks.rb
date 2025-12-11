class CreateTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :tasks do |t|
      t.references :run, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :instance_type, null: false
      t.integer :run_number, null: false
      t.string :status, null: false, default: 'pending'
      t.string :runner_id
      t.datetime :claimed_at
      t.datetime :heartbeat_at
      t.string :heartbeat_status
      t.text :heartbeat_message
      t.string :current_benchmark
      t.integer :progress_pct
      t.string :s3_result_key
      t.string :s3_error_key
      t.string :error_type
      t.text :error_message

      t.timestamps
    end

    add_index :tasks, [:run_id, :status]
    add_index :tasks, [:provider, :instance_type, :status]
    add_index :tasks, :runner_id
    add_index :tasks, :heartbeat_at
  end
end
