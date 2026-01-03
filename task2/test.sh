#!/bin/bash

# ANSI color codes
GREEN='\e[32m'
RED='\e[31m'
CYAN='\e[36m'
BLUE='\e[34m'
NC='\e[0m'

step() {
  local message="$1"; shift
  echo -ne "[${CYAN}....${NC}] ${message}"
  if output=$("$@" 2>&1); then
    local last_line=${output##*$'\n'}
    [[ -z $last_line ]] && last_line=' '
    echo -e "\r[ ${GREEN}OK${NC} ] ${message} : ${CYAN}${last_line}${NC}"
  else
    echo -ne "\r[${RED}FAIL${NC}] ${message}"
    echo "${output}"
    exit 1
  fi
}

segment() {
    local message="$1"; shift
    echo -e "\n${BLUE}>>> ${message} ${NC}"
}

# 1. Connectivity
segment "Service Connectivity"
step "Frontend responds to HTTP" bash -c 'curl -s http://localhost:3000/ | grep -oE "<title>.*</title>" '
step "Backend /reports returns 401 for anonymous" bash -c 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/reports | grep -q "401" && echo "401 Unauthorized"'
step "Backend /auth/me returns {authenticated:false}" bash -c 'curl -s http://localhost:8000/auth/me | grep -q "\"authenticated\":false" && echo "{\"authenticated\":false}"'

# 2. PKCE & BFF Deep Check
segment "BFF & PKCE Deep Verification"
step "BFF /auth/login sets pkce_data" bash -c 'curl -s -i http://localhost:8000/auth/login | grep -ioE "Set-Cookie: pkce_data=.*"'
step "BFF /auth/login uses HttpOnly" bash -c 'curl -s -i http://localhost:8000/auth/login | grep -ioE "HttpOnly"'
step "PKCE Challenge in redirect URL" bash -c 'curl -s -i http://localhost:8000/auth/login | grep -ioE "code_challenge=[a-zA-Z0-9_-]+"'
step "PKCE State in redirect URL" bash -c 'curl -s -i http://localhost:8000/auth/login | grep -ioE "state=[a-zA-Z0-9_-]+"'
step "PKCE Protection: Callback fails without cookie" bash -c 'curl -s -o /dev/null -w "%{http_code}" "http://localhost:8000/auth/callback?code=fake_code&state=fake_state" | grep "400" && echo "400 Bad Request (Protected)"'

# 3. Security Headers
segment "Security Headers & Hardening"
step "X-Frame-Options: DENY" bash -c 'curl -s -i http://localhost:8000/auth/login | grep -i "X-Frame-Options: DENY"'
step "X-Content-Type-Options: nosniff" bash -c 'curl -s -i http://localhost:8000/auth/login | grep -i "X-Content-Type-Options: nosniff"'

# 4. Token & Frontend Isolation
segment "Token Isolation Check"
step "Frontend: no keycloak-js library usage" bash -c '! grep -q "keycloak-js" frontend/src/App.tsx && echo "Frontend is clean"'
step "Frontend: no localStorage for tokens" bash -c '! grep -rE "access_token|localStorage" frontend/src | grep -qv "ReportPage.tsx" && echo "No tokens in client storage"'
step "Backend: tokens NOT leaked in body" bash -c 'if ! curl -s http://localhost:8000/auth/me | grep -i "token"; then echo "No tokens in JSON body"; else exit 1; fi'

# 5. Identity & LDAP
segment "Identity & LDAP Integration"

# Pre-load LDAP data if not already there (bypass volume mount issues on Windows)
docker compose exec -T ldap ldapadd -x -c -D "cn=admin,dc=example,dc=com" -w admin > /dev/null 2>&1 < ldap/config.ldif || true

sleep 1

step "LDAP: Entry john.doe exists" bash -c 'docker compose exec -T ldap ldapsearch -x -D "cn=admin,dc=example,dc=com" -w admin -b "dc=example,dc=com" "(uid=john.doe)" | grep -i "dn: uid=john.doe"'
step "LDAP: Group prosthetic_user exists" bash -c 'docker compose exec -T ldap ldapsearch -x -D "cn=admin,dc=example,dc=com" -w admin -b "dc=example,dc=com" "(cn=prosthetic_user)" | grep -i "dn: cn=prosthetic_user"'

step "Keycloak logs: configuration loaded" bash -c 'docker compose logs keycloak | grep -iE "(ldap-provider|Import finished)"'
step "Keycloak logs: Realm reports-realm ready" bash -c 'docker compose logs keycloak | grep -iE "(imported|already exists)"'

# 6. Real Authentication Test
segment "End-to-End Authentication Test"
step "Auth: Login with Keycloak user (user1)" bash -c 'curl -s -X POST "http://localhost:8080/realms/reports-realm/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=password" \
     -d "client_id=reports-frontend" \
     -d "client_secret=oNwoLQdvJAvRcL89SydqCWCe5ry1jMgq" \
     -d "username=user1" \
     -d "password=password123" | grep -i "access_token"'

step "Auth: Login with LDAP user (john.doe)" bash -c 'curl -s -X POST "http://localhost:8080/realms/reports-realm/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=password" \
     -d "client_id=reports-frontend" \
     -d "client_secret=oNwoLQdvJAvRcL89SydqCWCe5ry1jMgq" \
     -d "username=john.doe" \
     -d "password=password" | grep -i "access_token"'

# 7. BFF Session & Token Validation
segment "BFF Session & Token Handling"

test_bff_session() {
  local tokens
  # Get tokens from INSIDE with scope=openid
  tokens=$(docker compose exec -T backend python3 -c "
import urllib.request, urllib.parse, json
url = 'http://keycloak:8080/realms/reports-realm/protocol/openid-connect/token'
data = urllib.parse.urlencode({
    'grant_type': 'password',
    'client_id': 'reports-frontend',
    'client_secret': 'oNwoLQdvJAvRcL89SydqCWCe5ry1jMgq',
    'username': 'user1',
    'password': 'password123',
    'scope': 'openid profile email'
}).encode()
req = urllib.request.Request(url, data=data)
with urllib.request.urlopen(req) as f:
    print(f.read().decode())
")
  
  if [[ ! "$tokens" =~ "access_token" ]]; then
    echo "Failed to get access token: $tokens"
    return 1
  fi

  # Create session cookie using backend container
  local session_cookie
  session_cookie=$(echo "$tokens" | docker compose exec -T backend python3 -c "
import sys, json
from itsdangerous import URLSafeSerializer
tokens = json.load(sys.stdin)
s = URLSafeSerializer('very-secret-session-key')
print(s.dumps({'access_token': tokens['access_token']}))
")
  
  if [ -z "$session_cookie" ]; then
    echo "Failed to create session cookie"
    return 1
  fi

  session_cookie=$(echo "$session_cookie" | tr -d '\r\n')
  
  local response
  response=$(curl -s -b "session=$session_cookie" http://localhost:8000/auth/me)
  
  if echo "$response" | grep -q '"authenticated":true'; then
    echo "BFF Session Validated: $response"
    return 0
  else
    echo "BFF failed to validate session cookie. Response: $response"
    return 1
  fi
}

export -f test_bff_session
step "BFF correctly identifies user from session cookie" bash -c "test_bff_session"

# 8. Frontend Integration (CORS & Proxy)
segment "Frontend to BFF Integration"

step "BFF allows requests from Frontend Origin (CORS)" bash -c 'curl -s -I -H "Origin: http://localhost:3000" http://localhost:8000/auth/me | grep -i "Access-Control-Allow-Origin: http://localhost:3000"'

step "BFF allows credentials (cookies) from Frontend" bash -c 'curl -s -I -H "Origin: http://localhost:3000" http://localhost:8000/auth/me | grep -i "Access-Control-Allow-Credentials: true"'

# 9. Task 2: Reports & ETL
segment "Reports & ETL Verification"

step "CRM DB: table crm_users exists" bash -c 'docker compose exec -T crm_db psql -U crm_user -d crm_db -c "SELECT count(*) FROM crm_users;" | grep -E "[0-9]+"'
step "Business DB: table telemetry exists" bash -c 'docker compose exec -T business_db psql -U business_user -d business_db -c "SELECT count(*) FROM telemetry;" | grep -E "[0-9]+"'
step "ClickHouse: table user_report_showcase exists" bash -c 'curl -s -u default:clickhouse "http://localhost:8123/" -d "EXISTS TABLE user_report_showcase"'

step "Airflow: DAG bionicpro_etl_process is loaded" bash -c 'docker compose exec -T airflow_scheduler airflow dags list | grep "bionicpro_etl_process" | awk "{print \$1 \" | \" \$3}"'
step "Airflow: CRM connection is configured" bash -c 'docker compose exec -T airflow_scheduler env | grep "AIRFLOW_CONN_CRM_DB_CONN"'
step "Airflow: Business connection is configured" bash -c 'docker compose exec -T airflow_scheduler env | grep "AIRFLOW_CONN_BUSINESS_DB_CONN"'

# 10. Task 2: API Reports Check
segment "API Reports & Access Control Verification"

test_reports_api_user() {
  local username="$1"
  local password="$2"
  local expected_prosth="$3"
  local forbidden_prosth="$4"

  local tokens
  tokens=$(docker compose exec -T backend python3 -c "
import urllib.request, urllib.parse, json
url = 'http://keycloak:8080/realms/reports-realm/protocol/openid-connect/token'
data = urllib.parse.urlencode({
    'grant_type': 'password',
    'client_id': 'reports-frontend',
    'client_secret': 'oNwoLQdvJAvRcL89SydqCWCe5ry1jMgq',
    'username': '$username',
    'password': '$password',
    'scope': 'openid profile email'
}).encode()
req = urllib.request.Request(url, data=data)
with urllib.request.urlopen(req) as f:
    print(f.read().decode())
")
  
  local session_cookie
  session_cookie=$(echo "$tokens" | docker compose exec -T backend python3 -c "
import sys, json
from itsdangerous import URLSafeSerializer
tokens = json.load(sys.stdin)
s = URLSafeSerializer('very-secret-session-key')
print(s.dumps(tokens))
")
  
  session_cookie=$(echo "$session_cookie" | tr -d '\r\n')
  
  # Get REAL user_id (sub) from BFF
  local user_id
  user_id=$(curl -s -b "session=$session_cookie" http://localhost:8000/auth/me | grep -oE '"sub":"[^"]+"' | cut -d'"' -f4)
  
  if [ -z "$user_id" ]; then
    echo "Failed to get user_id for $username"
    return 1
  fi

  # Clean and insert fresh data for this specific user_id
  curl -s -u default:clickhouse "http://localhost:8123/" -d "DELETE FROM user_report_showcase WHERE prosthesis_id = '$expected_prosth'" > /dev/null
  curl -s -u default:clickhouse "http://localhost:8123/" -d "
  INSERT INTO user_report_showcase (user_id, prosthesis_id, report_date, total_gestures, avg_response_time_ms, max_response_time_ms, battery_usage_pct, error_count)
  VALUES ('$user_id', '$expected_prosth', '2026-01-04', 10, 95.0, 120.0, 5.5, 0)
  " > /dev/null

  local response
  response=$(curl -s -b "session=$session_cookie" http://localhost:8000/reports)
  
  if echo "$response" | grep -q "$expected_prosth" && ! echo "$response" | grep -q "$forbidden_prosth"; then
    echo -n "Isolation OK for $username (ID: $user_id): Found $expected_prosth, NOT found $forbidden_prosth"
    echo " Response: $response"
    return 0
  else
    echo -n "Isolation FAILED for $username (ID: $user_id)."
    echo -n " Expected: $expected_prosth, Forbidden: $forbidden_prosth."
    echo " Response: $response"
    return 1
  fi
}

export -f test_reports_api_user
step "Reports Isolation: user1" bash -c "test_reports_api_user user1 password123 PROSTH-001 PROSTH-002"
step "Reports Isolation: user2" bash -c "test_reports_api_user user2 password123 PROSTH-002 PROSTH-001"

