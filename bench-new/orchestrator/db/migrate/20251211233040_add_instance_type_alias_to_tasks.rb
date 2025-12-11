class AddInstanceTypeAliasToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :instance_type_alias, :string
  end
end
