The next stage is to implement each provider.

See bench-new/PROVIDER_GUIDE.md

Providers we will implement (in order):

- [X] AWS
- [ ] Azure
- [ ] AWS ECS with Fargate (No docker)
- [ ] Heroku (No docker)
- [ ] Hetzner
- [ ] Render (No docker)
- [ ] Fly.io (No docker)
- [ ] Google Cloud Platform (GCP)
- [ ] Railway

You shall test your new provider by running a full benchmark using the master script. When you do this, only test a single instance type. First, get the mock benchmark to pass, then use the full ruby-bench suite.
