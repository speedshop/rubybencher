#!/usr/bin/env bash
# Mock benchmark script for testing

OUTPUT_FILE="${1:-/output/output.txt}"
PROGRESS_FILE="${2:-/tmp/progress.json}"

# Simulate benchmark with random duration between 5-10 seconds (quick for testing)
DURATION=$((5 + RANDOM % 6))

# 10% chance of failure (can be disabled with MOCK_ALWAYS_SUCCEED=1)
if [ "${MOCK_ALWAYS_SUCCEED:-0}" = "1" ]; then
    FAIL_CHANCE=1  # Never 0, so never fails
else
    FAIL_CHANCE=$((RANDOM % 10))
fi

echo "Mock Benchmark Starting" | tee "$OUTPUT_FILE"
echo "Ruby Version: $(ruby --version)" | tee -a "$OUTPUT_FILE"
echo "Duration: ${DURATION}s" | tee -a "$OUTPUT_FILE"
echo "---" | tee -a "$OUTPUT_FILE"

START_TIME=$(date +%s)

for i in $(seq 1 $DURATION); do
    ELAPSED=$i
    PROGRESS=$(( (ELAPSED * 100) / DURATION ))

    echo "PROGRESS:$PROGRESS - Iteration $i/$DURATION" | tee -a "$OUTPUT_FILE"

    # Simulate different benchmark phases
    if [ $PROGRESS -lt 33 ]; then
        echo "Phase: Warmup" | tee -a "$OUTPUT_FILE"
    elif [ $PROGRESS -lt 66 ]; then
        echo "Phase: Running" | tee -a "$OUTPUT_FILE"
    else
        echo "Phase: Cooldown" | tee -a "$OUTPUT_FILE"
    fi

    sleep 1

    # Random failure point
    if [ $FAIL_CHANCE -eq 0 ] && [ $i -eq $((DURATION / 2)) ]; then
        echo "ERROR: Simulated benchmark crash!" | tee -a "$OUTPUT_FILE"
        exit 1
    fi
done

END_TIME=$(date +%s)
ACTUAL_DURATION=$((END_TIME - START_TIME))

echo "---" | tee -a "$OUTPUT_FILE"
echo "Benchmark Complete!" | tee -a "$OUTPUT_FILE"
echo "Total Time: ${ACTUAL_DURATION}s" | tee -a "$OUTPUT_FILE"

# Output some fake benchmark results
echo "" | tee -a "$OUTPUT_FILE"
echo "Results:" | tee -a "$OUTPUT_FILE"
echo "  Iterations: 1000" | tee -a "$OUTPUT_FILE"
echo "  Average Time: 1.23ms" | tee -a "$OUTPUT_FILE"
echo "  Min Time: 0.98ms" | tee -a "$OUTPUT_FILE"
echo "  Max Time: 2.45ms" | tee -a "$OUTPUT_FILE"
echo "  Standard Deviation: 0.15ms" | tee -a "$OUTPUT_FILE"

exit 0
