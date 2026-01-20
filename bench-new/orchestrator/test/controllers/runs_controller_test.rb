require "test_helper"

class RunsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @api_key = ENV.fetch("API_KEY", "dev_api_key_change_in_production")
  end

  test "POST /runs creates a new run with tasks" do
    post runs_path,
      params: {
        ruby_version: "3.4.7",
        runs_per_instance_type: 2,
        aws: [ "c8g.medium" ],
        azure: [ "Standard_D2pls_v6" ]
      },
      headers: { "Authorization" => "Bearer #{@api_key}" },
      as: :json

    assert_response :created
    json = JSON.parse(response.body)

    assert json["run_id"].present?
    assert_equal 4, json["tasks_created"]
    assert_equal 4, json["tasks"].length

    run = Run.find_by(external_id: json["run_id"])
    assert run.present?
    assert_equal "3.4.7", run.ruby_version
    assert_equal 2, run.runs_per_instance_type
  end

  test "POST /runs returns 400 if no instance types specified" do
    post runs_path,
      params: { ruby_version: "3.4.7", runs_per_instance_type: 3 },
      headers: { "Authorization" => "Bearer #{@api_key}" },
      as: :json

    assert_response :bad_request
  end

  test "POST /runs requires authentication" do
    post runs_path,
      params: { ruby_version: "3.4.7", runs_per_instance_type: 3, aws: [ "c8g.medium" ] },
      as: :json

    assert_response :unauthorized
  end

  test "POST /runs accepts client-provided run_id" do
    client_run_id = "173500000012345678"

    post runs_path,
      params: {
        ruby_version: "3.4.7",
        runs_per_instance_type: 1,
        run_id: client_run_id,
        aws: [ "c8g.medium" ]
      },
      headers: { "Authorization" => "Bearer #{@api_key}" },
      as: :json

    assert_response :created
    json = JSON.parse(response.body)

    assert_equal client_run_id, json["run_id"]

    run = Run.find_by(external_id: client_run_id)
    assert run.present?
  end

  test "GET /runs/:id returns run status" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)
    run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1, status: "completed")
    run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2, status: "running")

    get run_path(run.external_id)

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal run.external_id, json["run_id"]
    assert_equal "running", json["status"]
    assert_equal 2, json["tasks"]["total"]
    assert_equal 1, json["tasks"]["completed"]
    assert_equal 1, json["tasks"]["running"]
  end

  test "GET /runs/:id fails a stalled run with no claims" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 1)
    task = run.tasks.create!(provider: "azure", instance_type: "Standard_D2pls_v6", run_number: 1)
    run.update_column(:created_at, 11.minutes.ago)

    get run_path(run.external_id)

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "failed", json["status"]
    assert_equal "failed", task.reload.status
  end

  test "GET /runs/:id returns 404 if run not found" do
    get run_path("nonexistent")

    assert_response :not_found
  end

  test "POST /runs/:id/stop cancels the run" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)

    post stop_run_path(run.external_id),
      headers: { "Authorization" => "Bearer #{@api_key}" },
      as: :json

    assert_response :success
    run.reload
    assert_equal "cancelled", run.status
  end

  test "POST /runs/:id/stop cancels pending tasks and enqueues gzip builder" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    pending_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1)
    claimed_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2)
    claimed_task.claim!("runner-1")
    completed_task = run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 3)
    completed_task.claim!("runner-2")
    completed_task.complete!("results/1/task_3.tar.gz")

    assert_enqueued_with(job: GzipBuilderJob, args: [ run.id ]) do
      post stop_run_path(run.external_id),
        headers: { "Authorization" => "Bearer #{@api_key}" },
        as: :json
    end

    assert_response :success
    assert_equal "cancelled", pending_task.reload.status
    assert_equal "cancelled", claimed_task.reload.status
    assert_equal "completed", completed_task.reload.status
  end

  test "POST /runs/:id/stop requires authentication" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)

    post stop_run_path(run.external_id), as: :json

    assert_response :unauthorized
  end
end
