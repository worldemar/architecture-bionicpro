CREATE TABLE IF NOT EXISTS user_report_showcase (
    user_id UUID,
    prosthesis_id String,
    report_date Date,
    total_gestures UInt32,
    avg_response_time_ms Float32,
    max_response_time_ms Float32,
    battery_usage_pct Float32,
    error_count UInt16,
    updated_at DateTime DEFAULT now()
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (user_id, report_date);

