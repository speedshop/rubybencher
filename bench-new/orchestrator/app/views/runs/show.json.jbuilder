json.run_id @run.external_id
json.status @run.status
json.ruby_version @run.ruby_version
json.per_instance_type do
  json.tasks @run.tasks_per_instance_type
end

json.tasks do
  json.total @run.tasks.count
  json.pending @tasks_by_status['pending'] || 0
  json.claimed @tasks_by_status['claimed'] || 0
  json.running @tasks_by_status['running'] || 0
  json.completed @tasks_by_status['completed'] || 0
  json.failed @tasks_by_status['failed'] || 0
end

json.gzip_url @run.gzip_url
