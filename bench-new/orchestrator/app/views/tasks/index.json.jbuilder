json.run_id @run.external_id
json.tasks @tasks do |task|
  json.partial! "tasks/task_detail", task: task
end
