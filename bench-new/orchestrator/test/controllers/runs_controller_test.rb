require "test_helper"

class RunsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @api_key = ENV.fetch('API_KEY', 'dev_api_key_change_in_production')
  end

  test "POST /run/start creates a new run with tasks" do
    post run_start_path,
      params: {
        ruby_version: "3.4.7",
        runs_per_instance_type: 2,
        aws: ["c8g.medium"],
        azure: ["Standard_D2pls_v6"]
      },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :created
    json = JSON.parse(response.body)

    assert json['run_id'].present?
    assert_equal 4, json['tasks_created']
    assert_equal 4, json['tasks'].length

    run = Run.find_by(external_id: json['run_id'])
    assert run.present?
    assert_equal "3.4.7", run.ruby_version
    assert_equal 2, run.runs_per_instance_type
  end

  test "POST /run/start returns 409 if run already in progress" do
    Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)

    post run_start_path,
      params: { ruby_version: "3.4.8", runs_per_instance_type: 1, aws: ["c8g.medium"] },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :conflict
    json = JSON.parse(response.body)
    assert_equal "A run is already in progress", json['error']
  end

  test "POST /run/start returns 400 if no instance types specified" do
    post run_start_path,
      params: { ruby_version: "3.4.7", runs_per_instance_type: 3 },
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :bad_request
  end

  test "POST /run/start requires authentication" do
    post run_start_path,
      params: { ruby_version: "3.4.7", runs_per_instance_type: 3, aws: ["c8g.medium"] },
      as: :json

    assert_response :unauthorized
  end

  test "GET /run returns current run status" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 2)
    run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 1, status: "completed")
    run.tasks.create!(provider: "aws", instance_type: "c8g.medium", run_number: 2, status: "running")

    get run_path

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal run.external_id, json['run_id']
    assert_equal "running", json['status']
    assert_equal 2, json['tasks']['total']
    assert_equal 1, json['tasks']['completed']
    assert_equal 1, json['tasks']['running']
  end

  test "GET /run returns 404 if no run exists" do
    get run_path

    assert_response :not_found
  end

  test "POST /run/stop cancels the current run" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)

    post run_stop_path,
      headers: { 'Authorization' => "Bearer #{@api_key}" },
      as: :json

    assert_response :success
    run.reload
    assert_equal "cancelled", run.status
  end

  test "POST /run/stop requires authentication" do
    Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)

    post run_stop_path, as: :json

    assert_response :unauthorized
  end
end
