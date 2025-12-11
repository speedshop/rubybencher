# Results bucket for benchmark uploads
resource "aws_s3_bucket" "results" {
  bucket        = var.results_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id

  versioning_configuration {
    status = "Suspended"
  }
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
