# Задание 2. Разработка сервиса отчётов

## Задача 1. Создать архитектуру решения для подготовки и получения отчётов

### Обоснование выбора инструментов и архитектуры

- **Apache Airflow**: Выбран как индустриальный стандарт для оркестрации ETL-процессов. Он позволяет гибко настраивать расписание, управлять зависимостями между задачами (извлечение из CRM, извлечение телеметрии, объединение) и обеспечивает механизм повторных попыток при сбоях.
- **ClickHouse (OLAP DB)**:
    - **Соответствие требованиям**: Прямое указание в задании.
    - **Производительность**: Идеально подходит для работы с телеметрией. Колончатое хранение позволяет выполнять аналитические запросы и агрегацию по огромным массивам данных значительно быстрее, чем транзакционные БД (PostgreSQL).
    - **Масштабируемость**: Эффективно справляется с растущим объемом данных от датчиков протезов при выходе компании на новые рынки.
### Схема подключения

- **Airflow** подключается к **БД CRM** и основной БД для извлечения данных, так как он является инициатором ETL-процесса.
    - *Примечание*: Прямое подключение к операционным базам данных (CRM DB) может считаться антипаттерном в крупных системах. В рамках данного проекта это допустимо для упрощения архитектуры. В промышленной эксплуатации рекомендуется использовать промежуточный слой (ODS - Operational Data Store), CDC (Change Data Capture) механизмы или специализированные Read-Only реплики, чтобы исключить влияние аналитических запросов на производительность транзакционных систем.
- **API** обращается напрямую к **ClickHouse**, чтобы возвращать пользователям уже предрассчитанные витрины (отчеты) без нагрузки на транзакционные базы данных и сложных вычислений в реальном времени.

### Итоговая схема контейнеров

![c4/container/to-be.puml](c4/container/to-be.png)

## Задача 2. Разработать Airflow DAG и настроить его на запуск по расписанию

- Создан DAG [`airflow/dags/bionicpro_etl.py`](airflow/dags/bionicpro_etl.py), реализующий процесс Extract-Transform-Load.
- Настроена автоматическая инициализация источников данных и целевого хранилища:
    - [Инициализация CRM DB](init-db/postgres-crm.sql)
    - [Инициализация Telemetry DB](init-db/postgres-business.sql)
    - [Инициализация ClickHouse](init-db/clickhouse-init.sql)
- Подключения к базам данных настроены через переменные окружения в [`docker-compose.yaml`](../docker-compose.yaml) (Infrastructure as Code).

### 2.1. Реализация ETL-процесса с использованием Airflow

Реализовано в DAG: извлечение из `crm_users` и `telemetry`, объединение по `prosthesis_id`, агрегация метрик (количество жестов, среднее время отклика, расход батареи) и загрузка в ClickHouse.

### 2.2. Подготовка витрины 

Витрина создана в ClickHouse (таблица `user_report_showcase`) с оптимизацией по `(user_id, report_date)` для быстрого доступа. Схема описана в [`airflow/table_schema.sql`](airflow/table_schema.sql).

### 2.3. Настройка расписания сбора данных и подготовки витрины

DAG настроен на ежедневный запуск (`schedule_interval='@daily'`).

## Задача 3. Создайте бэкенд-часть приложения для API

- В [`backend/main.py`](../backend/main.py) реализован эндпоинт `/reports`.
- Настроено подключение к ClickHouse через переменные окружения.
- Реализовано получение данных из OLAP-базы в формате JSON.

## Задача 4. Реализация ограничения доступа к эндпоинту отчётности

- Доступ к эндпоинту `/reports` разрешен только аутентифицированным пользователям (проверка сессионной куки).
- Реализована фильтрация данных на уровне SQL-запроса: `WHERE user_id = '{user_id}'`. Пользователь получает данные только по своим протезам, привязанным к его `sub` из Keycloak.

## Задача 5. Добавление в UI кнопки получения отчёта и вызова эндпоинта его генерации.

- Обновлен компонент [`frontend/src/components/ReportPage.tsx`](../frontend/src/components/ReportPage.tsx).
- Добавлена кнопка "Получить актуальные данные".
- Реализована таблица для отображения данных из ClickHouse.
- Использован `credentials: 'include'` для корректной передачи сессионных кук в BFF.
- UI оформлен с использованием Tailwind CSS.

## Тест

Перед тестированием нужно **из корня репозитория** перезапустить стек:

```
docker compose down -v
docker compose up -d --build
```

### Вручную (через браузер)

> **Важно**: Если вы запускали проект ранее, перед тестом очистите куки для `localhost` в браузере (F12 -> Application -> Cookies -> Clear), чтобы избежать конфликтов сессий.

1. **Запуск и наполнение данными**:
    - Убедитесь, что стек запущен (`docker compose up -d`).
    - Откройте **Airflow**: [http://localhost:8081](http://localhost:8081) (логин: `admin`, пароль: `admin`).
    
        <img src="manual-test-screenshots/airflow-login.png" alt="Airflow Login" width="720"/>

    - Включите и запустите (Trigger DAG) процесс `bionicpro_etl_process`. 
    
        <img src="manual-test-screenshots/airflow-dag.png" alt="Airflow DAG List" width="720"/>
    
    - Дождитесь, пока все шаги (Extract, Transform, Load) станут зелеными. 
    
        <img src="manual-test-screenshots/airflow-run.png" alt="Airflow Successful Run" width="720"/>

2. **Фронтенд**: откройте [http://localhost:3000](http://localhost:3000).

    <img src="manual-test-screenshots/bionicpro-login.png" alt="Keycloak Login" width="720"/>

3. **Авторизация**:
    - Нажмите **"Login via SSO"**. Вы попадете на страницу Keycloak.
    - Используйте данные тестового пользователя: `user1` / `password123`.
    
        <img src="manual-test-screenshots/bionicpro-auth.png" alt="Authorized Session" width="720"/>

4. **Просмотр отчетов**:
    - Нажмите кнопку **"Получить актуальные данные"**.

        <img src="manual-test-screenshots/bionicpro-web.png" alt="BionicPRO Home" width="720"/>

    - В таблице появятся данные по протезу `PROSTH-001`.
    
        <img src="manual-test-screenshots/bionicpro-report-user1.png" alt="User1 Report" width="720"/>

5. **Проверка изоляции**:
    - Выйдите из системы и войдите под `user2` / `password123`.
    - Вы увидите отчет только для `PROSTH-002`. Это подтверждает работу ограничений доступа.
    
        <img src="manual-test-screenshots/bionicpro-report-user2.png" alt="User2 Report" width="720"/>



### Пример запуска автоматического теста

Для проверки работы стека написан простой тест [test.sh](test.sh)

```
$ task2/test.sh                                                                                                                                               
                                                                                                                                                              
>>> Service Connectivity                                                                                                                                      
[ OK ] Frontend responds to HTTP : <title>Reports App</title>                                                                                                 
[ OK ] Backend /reports returns 401 for anonymous : 401 Unauthorized                                                                                          
[ OK ] Backend /auth/me returns {authenticated:false} : {"authenticated":false}                                                                               
                                                                                                                                                              
>>> BFF & PKCE Deep Verification                                                                                                                              
[ OK ] BFF /auth/login sets pkce_data : set-cookie: pkce_data=eyJ2ZXJpZmllciI6IkF6Vl9JY0t3T0c0dEFyeVN0M0ViR2NFV0ZPNndMekZ4bGhVcjFJampRbWVjOWFUbFcyeHoxT1p5WHEx
U3NwSmpkWjJNRFFoMzAyM1ZtMWhGRWdCaTdBIiwic3RhdGUiOiJEbHdSQlRuUHZUZG1pUnJtdldwalpJZ1ZJNm4yc0ZETXZmUjhzOE5zdFpNIn0.z0WCr20WLeXXuBXB2kbG1d5nhs8; HttpOnly; Path=/;
 SameSite=Strict                                                                                                                                              
[ OK ] BFF /auth/login uses HttpOnly : HttpOnly                                                                                                               
[ OK ] PKCE Challenge in redirect URL : code_challenge=uRrJcO5NHrJLyWldFTyMblM-1iaBwCFIxFtCCEUWeq0                                                            
[ OK ] PKCE State in redirect URL : state=tvvlPe8iUIl1wLRalcTaUrYxSaDA_OOy3GbXQIDFkgw                                                                         
[ OK ] PKCE Protection: Callback fails without cookie : 400 Bad Request (Protected)                                                                           
                                                                                                                                                              
>>> Security Headers & Hardening                                                                                                                              
[ OK ] X-Frame-Options: DENY : x-frame-options: DENY                                                                                                          
[ OK ] X-Content-Type-Options: nosniff : x-content-type-options: nosniff                                                                                      
                                                                                                                                                              
>>> Token Isolation Check                                                                                                                                     
[ OK ] Frontend: no keycloak-js library usage : Frontend is clean                                                                                             
[ OK ] Frontend: no localStorage for tokens : No tokens in client storage                                                                                     
[ OK ] Backend: tokens NOT leaked in body : No tokens in JSON body                                                                                            
                                                                                                                                                              
>>> Identity & LDAP Integration                                                                                                                               
[ OK ] LDAP: Entry john.doe exists : dn: uid=john.doe,ou=People,dc=example,dc=com                                                                             
[ OK ] LDAP: Group prosthetic_user exists : dn: cn=prosthetic_user,ou=Groups,dc=example,dc=com                                                                
[ OK ] Keycloak logs: configuration loaded : keycloak-1  | 2026-01-04 12:35:59,547 INFO  [org.keycloak.storage.ldap.LDAPIdentityStoreRegistry] (executor-threa
d-0) Creating new LDAP Store for the LDAP storage provider: 'ldap-provider', LDAP Configuration: {fullSyncPeriod=[0], searchScope=[1], usersDn=[ou=People,dc=e
xample,dc=com], priority=[0], userObjectClasses=[inetOrgPerson, top], changedSyncPeriod=[0], usernameLDAPAttribute=[uid], bindDn=[cn=admin,dc=example,dc=com],
 rdnLDAPAttribute=[uid], lastSync=[0], vendor=[other], editMode=[READ_ONLY], uuidLDAPAttribute=[uid], connectionUrl=[ldap://ldap:389], authType=[simple]}, bin
aryAttributes: []                                                                                                                                             
[ OK ] Keycloak logs: Realm reports-realm ready : keycloak-1  | 2026-01-04 12:35:52,334 INFO  [org.keycloak.exportimport.util.ImportUtils] (main) Realm 'repor
ts-realm' imported                                                                                                                                            
                                                                                                                                                              
>>> End-to-End Authentication Test                                                                                                                            
[ OK ] Auth: Login with Keycloak user (user1) : {"access_token":"eyJhbGciOiJSUzI1NiIsInR5cCIgOiAiSldUIiwia2lkIiA6ICJyOVlRZTk4S2lJUFBVYS1Jek8xT0RDaGFSaWpQbEJFa
2xUeEhVTDRfNzA0In0.eyJleHAiOjE3Njc1MzA3NTEsImlhdCI6MTc2NzUzMDQ1MSwianRpIjoiNDJlNjk1ZTQtMDg4NC00ZDE4LTkwZmUtZjMxMmFhYzY4MWYxIiwiaXNzIjoiaHR0cDovL2xvY2FsaG9zdDo
4MDgwL3JlYWxtcy9yZXBvcnRzLXJlYWxtIiwic3ViIjoiMTIzZTQ1NjctZTg5Yi0xMmQzLWE0NTYtNDI2NjE0MTc0MDAwIiwidHlwIjoiQmVhcmVyIiwiYXpwIjoicmVwb3J0cy1mcm9udGVuZCIsInNlc3Npb
25fc3RhdGUiOiI5MjhkYmM2Yy02ZjI0LTRkOWUtYTFjYi03YjRmYjkzM2NiMGMiLCJhY3IiOiIxIiwiYWxsb3dlZC1vcmlnaW5zIjpbIioiXSwicmVhbG1fYWNjZXNzIjp7InJvbGVzIjpbInVzZXIiXX0sInN
jb3BlIjoicHJvZmlsZSBlbWFpbCIsInNpZCI6IjkyOGRiYzZjLTZmMjQtNGQ5ZS1hMWNiLTdiNGZiOTMzY2IwYyIsImVtYWlsX3ZlcmlmaWVkIjpmYWxzZSwibmFtZSI6IlVzZXIgT25lIiwicHJlZmVycmVkX
3VzZXJuYW1lIjoidXNlcjEiLCJnaXZlbl9uYW1lIjoiVXNlciIsImZhbWlseV9uYW1lIjoiT25lIiwiZW1haWwiOiJ1c2VyMUBleGFtcGxlLmNvbSJ9.ZIvV9YikVO0kXmyCElJhd4FVgy7bQYxl0MdJT28SOo
Fqfpw-hhpSpLP-L2VyezZxfPvn-pWW7eLTWcLwmcYsB5QTHXWFbIjH-9A-CPYol17eQLrVnSSmR6_GPJBzwgdGofwgSFPh98L-rQRWHS7jzq6audFcszRlgxS0k7l9jegkOsCm-s63o0X27J5VV9iK6LGFp6v0
zash_A7TDsqAKa8ULFgDwAM5tfc7p20JTHelhZ7QdLyy3FV53zLcWrk7jMkevr8Beu1dzn2-o-mQWdgWAz_FHROKB-h2Ip2-XyO37neywZJiv7hq9xDqpMrXzMU0duNDL9Ud42KNIwQjxA","expires_in":3
00,"refresh_expires_in":1800,"refresh_token":"eyJhbGciOiJIUzI1NiIsInR5cCIgOiAiSldUIiwia2lkIiA6ICJjZjRhNWYxNy1lM2JlLTRjMzgtOTBiNy1lNTI4ZmE0YjJlYWYifQ.eyJleHAiO
jE3Njc1MzIyNTEsImlhdCI6MTc2NzUzMDQ1MSwianRpIjoiNjM5NGU0ZTctMWQxYi00YTA5LTgwZjAtN2I5MzQ0ZDZhZTlkIiwiaXNzIjoiaHR0cDovL2xvY2FsaG9zdDo4MDgwL3JlYWxtcy9yZXBvcnRzLXJ
lYWxtIiwiYXVkIjoiaHR0cDovL2xvY2FsaG9zdDo4MDgwL3JlYWxtcy9yZXBvcnRzLXJlYWxtIiwic3ViIjoiMTIzZTQ1NjctZTg5Yi0xMmQzLWE0NTYtNDI2NjE0MTc0MDAwIiwidHlwIjoiUmVmcmVzaCIsI
mF6cCI6InJlcG9ydHMtZnJvbnRlbmQiLCJzZXNzaW9uX3N0YXRlIjoiOTI4ZGJjNmMtNmYyNC00ZDllLWExY2ItN2I0ZmI5MzNjYjBjIiwic2NvcGUiOiJwcm9maWxlIGVtYWlsIiwic2lkIjoiOTI4ZGJjNmM
tNmYyNC00ZDllLWExY2ItN2I0ZmI5MzNjYjBjIn0.biw1T93N73FxRQH0zQ_PzgmvJrHSGetiq0sS_MOpAPY","token_type":"Bearer","not-before-policy":0,"session_state":"928dbc6c-6f
24-4d9e-a1cb-7b4fb933cb0c","scope":"profile email"}                                                                                                           
[ OK ] Auth: Login with LDAP user (john.doe) : {"access_token":"eyJhbGciOiJSUzI1NiIsInR5cCIgOiAiSldUIiwia2lkIiA6ICJyOVlRZTk4S2lJUFBVYS1Jek8xT0RDaGFSaWpQbEJFa2
xUeEhVTDRfNzA0In0.eyJleHAiOjE3Njc1MzA3NTEsImlhdCI6MTc2NzUzMDQ1MSwianRpIjoiNWY0M2ZhMDMtNDlhYi00NWUyLTg0M2UtY2Q3YjE4YjY2MjhiIiwiaXNzIjoiaHR0cDovL2xvY2FsaG9zdDo4
MDgwL3JlYWxtcy9yZXBvcnRzLXJlYWxtIiwiYXVkIjoiYWNjb3VudCIsInN1YiI6IjQzMWJmY2QwLWI2OGYtNDZhYy05YzZjLWI0ZTRmMzZjYjM2ZSIsInR5cCI6IkJlYXJlciIsImF6cCI6InJlcG9ydHMtZn
JvbnRlbmQiLCJzZXNzaW9uX3N0YXRlIjoiNTY4ODlhZTAtMWM1Mi00YjRmLTg4ODgtZmMyODk5YjEzODEyIiwiYWNyIjoiMSIsImFsbG93ZWQtb3JpZ2lucyI6WyIqIl0sInJlYWxtX2FjY2VzcyI6eyJyb2xl
cyI6WyJvZmZsaW5lX2FjY2VzcyIsImRlZmF1bHQtcm9sZXMtcmVwb3J0cy1yZWFsbSIsInVtYV9hdXRob3JpemF0aW9uIl19LCJyZXNvdXJjZV9hY2Nlc3MiOnsiYWNjb3VudCI6eyJyb2xlcyI6WyJtYW5hZ2
UtYWNjb3VudCIsIm1hbmFnZS1hY2NvdW50LWxpbmtzIiwidmlldy1wcm9maWxlIl19fSwic2NvcGUiOiJwcm9maWxlIGVtYWlsIiwic2lkIjoiNTY4ODlhZTAtMWM1Mi00YjRmLTg4ODgtZmMyODk5YjEzODEy
IiwiZW1haWxfdmVyaWZpZWQiOmZhbHNlLCJuYW1lIjoiSm9obiBEb2UiLCJwcmVmZXJyZWRfdXNlcm5hbWUiOiJqb2huLmRvZSIsImdpdmVuX25hbWUiOiJKb2huIiwiZmFtaWx5X25hbWUiOiJEb2UiLCJlbW
FpbCI6ImpvaG5AZXhhbXBsZS5jb20ifQ.V79xGbicJDwHYG-d1tt02_dJNqucmJBqnl3JfggLwMvGQNsp9gAlaMI-KBbiT_sCbsh-CzcF_l23WDzReEK8FDNp9e7QHZ0kwFZaGXzy4Yz9u-OjzBNa4X0nghCX6
FU0S5QWbzP-lGhRtYqtTxKchHyWxusV550Xo_kPXr1OZtG-AAS4oia-WeyR1DPBvIb3lSvzfhE8RNNJbbohbG5IexgGfRlw01ldIlV3apxBvTbF3JnL11L49s_7jbQJgue9SAFT1fynFFBGhXXSRSdfgi45a9p
HxCAgJWecjHDbjyTC6eVdMcZ8w-vH-F2BjjTE2gYcK323umQ3-u6znYdnHw","expires_in":300,"refresh_expires_in":1800,"refresh_token":"eyJhbGciOiJIUzI1NiIsInR5cCIgOiAiSldUI
iwia2lkIiA6ICJjZjRhNWYxNy1lM2JlLTRjMzgtOTBiNy1lNTI4ZmE0YjJlYWYifQ.eyJleHAiOjE3Njc1MzIyNTEsImlhdCI6MTc2NzUzMDQ1MSwianRpIjoiNTllZmM2YjItOGFjMC00OTY2LTg5ODYtNjBh
MzhjNjU4ZTgzIiwiaXNzIjoiaHR0cDovL2xvY2FsaG9zdDo4MDgwL3JlYWxtcy9yZXBvcnRzLXJlYWxtIiwiYXVkIjoiaHR0cDovL2xvY2FsaG9zdDo4MDgwL3JlYWxtcy9yZXBvcnRzLXJlYWxtIiwic3ViIj
oiNDMxYmZjZDAtYjY4Zi00NmFjLTljNmMtYjRlNGYzNmNiMzZlIiwidHlwIjoiUmVmcmVzaCIsImF6cCI6InJlcG9ydHMtZnJvbnRlbmQiLCJzZXNzaW9uX3N0YXRlIjoiNTY4ODlhZTAtMWM1Mi00YjRmLTg4
ODgtZmMyODk5YjEzODEyIiwic2NvcGUiOiJwcm9maWxlIGVtYWlsIiwic2lkIjoiNTY4ODlhZTAtMWM1Mi00YjRmLTg4ODgtZmMyODk5YjEzODEyIn0.4K7eh0C4tELmN6cF656SVUeSy9XuncAIJCMc0oFpgj
o","token_type":"Bearer","not-before-policy":0,"session_state":"56889ae0-1c52-4b4f-8888-fc2899b13812","scope":"profile email"}                                
                                                                                                                                                              
>>> BFF Session & Token Handling                                                                                                                              
[ OK ] BFF correctly identifies user from session cookie : BFF Session Validated: {"authenticated":true,"user":{"sub":"123e4567-e89b-12d3-a456-426614174000","
preferred_username":"user1","email":"user1@example.com","given_name":"User","family_name":"One"}}                                                             
                                                                                                                                                              
>>> Frontend to BFF Integration                                                                                                                               
[ OK ] BFF allows requests from Frontend Origin (CORS) : access-control-allow-origin: http://localhost:3000                                                   
[ OK ] BFF allows credentials (cookies) from Frontend : access-control-allow-credentials: true                                                                
                                                                                                                                                              
>>> Reports & ETL Verification                                                                                                                                
[ OK ] CRM DB: table crm_users exists : (1 row)                                                                                                               
[ OK ] Business DB: table telemetry exists : (1 row)                                                                                                          
[ OK ] ClickHouse: table user_report_showcase exists : 1                                                                                                      
[ OK ] Airflow: DAG bionicpro_etl_process is loaded : bionicpro_etl_process | bionicpro_etl.py                                                                
[ OK ] Airflow: CRM connection is configured : AIRFLOW_CONN_CRM_DB_CONN=postgresql://crm_user:crm_password@crm_db:5432/crm_db                                 
[ OK ] Airflow: Business connection is configured : AIRFLOW_CONN_BUSINESS_DB_CONN=postgresql://business_user:business_password@business_db:5432/business_db   
                                                                                                                                                              
>>> API Reports & Access Control Verification                                                                                                                 
[ OK ] Reports Isolation: user1 : Isolation OK for user1 (ID: 123e4567-e89b-12d3-a456-426614174000): Found PROSTH-001, NOT found PROSTH-002 Response: {"meta":
[{"name":"user_id","type":"UUID"},{"name":"prosthesis_id","type":"String"},{"name":"report_date","type":"Date"},{"name":"total_gestures","type":"UInt32"},{"na
me":"avg_response_time_ms","type":"Float32"},{"name":"max_response_time_ms","type":"Float32"},{"name":"battery_usage_pct","type":"Float32"},{"name":"error_cou
nt","type":"UInt16"},{"name":"updated_at","type":"DateTime"}],"data":[{"user_id":"123e4567-e89b-12d3-a456-426614174000","prosthesis_id":"PROSTH-001","report_d
ate":"2026-01-04","total_gestures":10,"avg_response_time_ms":95,"max_response_time_ms":120,"battery_usage_pct":5.5,"error_count":0,"updated_at":"2026-01-04 12
:40:58"}],"rows":1,"statistics":{"elapsed":0.003951175,"rows_read":2,"bytes_read":60}}                                                                        
[ OK ] Reports Isolation: user2 : Isolation OK for user2 (ID: 223e4567-e89b-12d3-a456-426614174000): Found PROSTH-002, NOT found PROSTH-001 Response: {"meta":
[{"name":"user_id","type":"UUID"},{"name":"prosthesis_id","type":"String"},{"name":"report_date","type":"Date"},{"name":"total_gestures","type":"UInt32"},{"na
me":"avg_response_time_ms","type":"Float32"},{"name":"max_response_time_ms","type":"Float32"},{"name":"battery_usage_pct","type":"Float32"},{"name":"error_cou
nt","type":"UInt16"},{"name":"updated_at","type":"DateTime"}],"data":[{"user_id":"223e4567-e89b-12d3-a456-426614174000","prosthesis_id":"PROSTH-002","report_d
ate":"2026-01-04","total_gestures":10,"avg_response_time_ms":95,"max_response_time_ms":120,"battery_usage_pct":5.5,"error_count":0,"updated_at":"2026-01-04 12
:40:59"}],"rows":1,"statistics":{"elapsed":0.003105222,"rows_read":2,"bytes_read":60}}                                                                        
```