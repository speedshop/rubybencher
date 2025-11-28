# Ruby Benchmark

Benchmarks Ruby across different AWS instance types and publishes results to speedshop.co/rubybench.

## Project Structure

```
├── bench/                    # Benchmark runner
│   ├── bench.rb              # Orchestrates benchmark runs
│   └── terraform/            # AWS infrastructure (EC2 instances)
├── site/                     # Results website
│   ├── generate_report.rb    # Generates HTML from results
│   ├── worker.js             # Cloudflare Worker proxy
│   └── terraform/            # Cloudflare infrastructure (Pages + Worker)
└── results/                  # Benchmark results (by run date)
```

## Setup

### Environment Variables

Create a `.env` file in the project root:

```
# AWS (for running benchmarks)
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=xxx
AWS_REGION=us-east-1

# Cloudflare (for hosting site)
CLOUDFLARE_API_TOKEN=xxx
CLOUDFLARE_ACCOUNT_ID=xxx
CLOUDFLARE_ZONE_ID=xxx
```

### AWS IAM Permissions

The AWS credentials need an IAM policy with the following permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:DescribeKeyPairs",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:DescribeSecurityGroups",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:CreateVpc",
        "ec2:DeleteVpc",
        "ec2:DescribeVpcs",
        "ec2:ModifyVpcAttribute",
        "ec2:CreateSubnet",
        "ec2:DeleteSubnet",
        "ec2:DescribeSubnets",
        "ec2:CreateInternetGateway",
        "ec2:DeleteInternetGateway",
        "ec2:DescribeInternetGateways",
        "ec2:AttachInternetGateway",
        "ec2:DetachInternetGateway",
        "ec2:CreateRouteTable",
        "ec2:DeleteRouteTable",
        "ec2:DescribeRouteTables",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:AssociateRouteTable",
        "ec2:DisassociateRouteTable",
        "ec2:DescribeImages",
        "ec2:CreateTags",
        "ec2:DescribeTags",
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    }
  ]
}
```

### Cloudflare API Token Permissions

Create an API token at https://dash.cloudflare.com/profile/api-tokens with:

**Account permissions:**
- Cloudflare Pages: Edit
- Workers Scripts: Edit

**Zone permissions (speedshop.co):**
- Workers Routes: Edit

## Running Benchmarks

```fish
cd bench
ruby bench.rb
```

This will:
1. Spin up EC2 instances (c8g.medium, c6g.medium, m8a.medium, c8i.large)
2. Run Ruby benchmarks on each instance
3. Collect results to `results/<timestamp>/`
4. Tear down infrastructure

## Generating the Report

```fish
cd site
ruby generate_report.rb
```

Generates `site/public/index.html` from the most recent results.

## Deploying the Site

### First-time setup

```fish
./site/terraform/apply.fish init
./site/terraform/apply.fish apply
```

This creates:
- Cloudflare Pages project (`rubybench.pages.dev`)
- Cloudflare Worker to proxy `speedshop.co/rubybench` → Pages

### Deploying updates

```fish
cd site
ruby generate_report.rb
wrangler pages deploy ./public --project-name=rubybench
```
