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

You shall test your new provider by running a full benchmark using the master script. When you do this, only test a single instance type.

TODO for each provider:

1. `infrastructure`: Determine what credentials you'll need, tools we need to install, etc.
2. First, get the mock benchmark to work on your provider.
3. Then, use the full ruby-bench suite.
4. `nuke`: Implement your provider extension to the nuke script. See bench-new/nuke/PROVIDER_GUIDE.md.

Create a new TODO in docs/<provider>_TODO.md and get started.
