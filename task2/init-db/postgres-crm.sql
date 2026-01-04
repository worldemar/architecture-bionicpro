CREATE TABLE IF NOT EXISTS crm_users (
    user_id UUID PRIMARY KEY,
    prosthesis_id VARCHAR(50) NOT NULL,
    full_name VARCHAR(255)
);

-- Наполним тестовыми данными (user1 из Keycloak)
-- Нам нужно узнать реальные UUID из Keycloak или использовать те, что мы назначим
-- Для теста мы можем обновить их позже или просто добавить еще одну запись
INSERT INTO crm_users (user_id, prosthesis_id, full_name) 
VALUES 
('123e4567-e89b-12d3-a456-426614174000', 'PROSTH-001', 'User One'),
('223e4567-e89b-12d3-a456-426614174000', 'PROSTH-002', 'User Two')
ON CONFLICT DO NOTHING;

