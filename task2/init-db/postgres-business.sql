CREATE TABLE IF NOT EXISTS telemetry (
    id SERIAL PRIMARY KEY,
    prosthesis_id VARCHAR(50) NOT NULL,
    event_time TIMESTAMP NOT NULL,
    gesture_type VARCHAR(50),
    response_time_ms FLOAT,
    battery_level FLOAT
);

-- Наполним тестовыми данными
INSERT INTO telemetry (prosthesis_id, event_time, gesture_type, response_time_ms, battery_level)
VALUES 
('PROSTH-001', NOW() - INTERVAL '1 hour', 'GRAB', 85.5, 98.0),
('PROSTH-001', NOW() - INTERVAL '30 minutes', 'RELEASE', 92.0, 95.0),
('PROSTH-001', NOW() - INTERVAL '5 minutes', 'POINT', 110.0, 92.0),
('PROSTH-002', NOW() - INTERVAL '1 hour', 'WAVE', 75.0, 99.0),
('PROSTH-002', NOW() - INTERVAL '20 minutes', 'CLENCH', 120.0, 94.0)
ON CONFLICT DO NOTHING;

