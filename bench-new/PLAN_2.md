The next stage is to implement each provider.

Each provider must:

1. Have a config file in `bench-new/config/` called `<provider>-full.json` which represents a "full" run across all the instance types we care about for that provider. This should be done "by the human" not by the LLM. It is necessary before continuing to the next step.
2. Have infrastructure/terraform in the infrastructure directory capable of creating task runners on that provider for the given instance types.
3. It will create task runners as docker containers. The terraform is responsible for starting docker hosts on each instance type. If the instance type has >1 CPU, start a number of task runner containers = to the number of vCPU.
4. Load credentials from `.env` as environment variables
5. For no-docker providers, we'll need to figure out something else.

Providers we will implement (in order):

- [ ] AWS
- [ ] Azure
- [ ] AWS ECS with Fargate (No docker)
- [ ] Heroku (No docker)
- [ ] Hetzner
- [ ] Render (No docker)
- [ ] Fly.io (No docker)
- [ ] Google Cloud Platform (GCP)
- [ ] Railway

You shall test your new provider by running a full benchmark using the master script. When you do this, only test a single instance type. First, get the mock benchmark to pass, then use the full ruby-bench suite.
