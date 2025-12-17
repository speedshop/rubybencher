The next stage is to implement each provider.

Each provider must:

1. Have a config file in `bench-new/config/` called `<provider>-full.json` which represents a "full" run across all the instance types we care about for that provider. This should be done "by the human" not by the LLM. It is necessary before continuing to the next step.
2. Have infrastructure/terraform in the infrastructure directory capable of creating task runners on that provider for the given instance types.
3. Load credentials from `.env` as environment variables

Providers we will implement (in order):

- [ ] AWS
- [ ] Azure
- [ ] AWS ECS with Fargate
- [ ] Heroku
- [ ] Hetzner
- [ ] Render
- [ ] Fly.io
- [ ] Google Cloud Platform (GCP)
- [ ] Railway

You shall test your new provider by running a full benchmark using the master script. When you do this, only test a single instance type. First, get the mock benchmark to pass, then use the full ruby-bench suite.
