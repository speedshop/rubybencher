json.run_id @run.external_id.to_s
json.tasks_created @tasks.count
json.tasks @tasks do |task|
  json.partial! "runs/task", task: task
end
