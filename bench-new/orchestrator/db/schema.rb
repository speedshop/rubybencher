# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2025_12_11_005500) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "external_id", null: false
    t.string "gzip_url"
    t.string "ruby_version", null: false
    t.integer "runs_per_instance_type", null: false
    t.string "status", default: "running", null: false
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_runs_on_external_id", unique: true
    t.index ["status"], name: "index_runs_on_status"
  end

  create_table "tasks", force: :cascade do |t|
    t.datetime "claimed_at"
    t.datetime "created_at", null: false
    t.string "current_benchmark"
    t.text "error_message"
    t.string "error_type"
    t.datetime "heartbeat_at"
    t.text "heartbeat_message"
    t.string "heartbeat_status"
    t.string "instance_type", null: false
    t.integer "progress_pct"
    t.string "provider", null: false
    t.bigint "run_id", null: false
    t.integer "run_number", null: false
    t.string "runner_id"
    t.string "s3_error_key"
    t.string "s3_result_key"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["heartbeat_at"], name: "index_tasks_on_heartbeat_at"
    t.index ["provider", "instance_type", "status"], name: "index_tasks_on_provider_and_instance_type_and_status"
    t.index ["run_id", "status"], name: "index_tasks_on_run_id_and_status"
    t.index ["run_id"], name: "index_tasks_on_run_id"
    t.index ["runner_id"], name: "index_tasks_on_runner_id"
  end

  add_foreign_key "tasks", "runs"
end
