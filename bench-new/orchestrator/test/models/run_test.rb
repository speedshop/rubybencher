require "test_helper"

class RunTest < ActiveSupport::TestCase
  test "creates run with external_id" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)

    assert run.external_id.present?
    assert run.running?
  end

  test "validates presence of required fields" do
    run = Run.new

    assert_not run.valid?
    assert_includes run.errors[:ruby_version], "can't be blank"
    assert_includes run.errors[:runs_per_instance_type], "can't be blank"
  end

  test "validates runs_per_instance_type is positive" do
    run = Run.new(ruby_version: "3.4.7", runs_per_instance_type: 0)

    assert_not run.valid?
    assert_includes run.errors[:runs_per_instance_type], "must be greater than 0"
  end

  test "validates status is valid" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    run.status = "invalid"

    assert_not run.valid?
    assert_includes run.errors[:status], "is not included in the list"
  end

  test "complete! changes status to completed" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    run.complete!

    assert run.completed?
    assert_equal "completed", run.status
  end

  test "cancel! changes status to cancelled" do
    run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    run.cancel!

    assert run.cancelled?
    assert_equal "cancelled", run.status
  end

  test "current scope returns most recent running run" do
    old_run = Run.create!(ruby_version: "3.4.7", runs_per_instance_type: 3)
    old_run.complete!
    sleep 1

    current_run = Run.create!(ruby_version: "3.4.8", runs_per_instance_type: 3)

    assert_equal current_run, Run.current
  end
end
