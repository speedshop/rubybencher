#!/usr/bin/env fish

set -l dirs \
  bench-new/infrastructure/meta \
  bench-new/infrastructure/aws \
  bench-new/infrastructure/azure \
  bench-new/infrastructure/fargate

for dir in $dirs
  echo "==> Terraform checks: $dir"
  terraform -chdir=$dir fmt -check
  terraform -chdir=$dir init -backend=false
  terraform -chdir=$dir validate
end
