class RenameRunsPerInstanceTypeToTasksPerInstanceType < ActiveRecord::Migration[8.1]
  def change
    rename_column :runs, :runs_per_instance_type, :tasks_per_instance_type
  end
end
