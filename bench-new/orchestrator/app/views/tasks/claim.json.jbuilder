json.status @status

case @status
when "wait"
  json.retry_after_seconds 30
when "done"
  json.message @message if @message
when "assigned"
  json.task do
    json.id @task.id
    json.provider @task.provider
    json.instance_type @task.instance_type
    json.instance_type_alias @task.instance_type_alias
    json.run_number @task.run_number
    json.ruby_version @run.ruby_version
  end
  json.presigned_urls @presigned_urls
end
