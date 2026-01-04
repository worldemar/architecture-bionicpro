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
step "Backend: tokens NOT leaked in body" bash -c 'if ! curl -s http://localhost:8000/auth/me | grep -qi "token"; then echo "No tokens in JSON body"; else exit 1; fi'

# 5. Identity & LDAP
segment "Identity & LDAP Integration"

# Pre-load LDAP data if not already there (bypass volume mount issues on Windows)
docker compose exec -T ldap ldapadd -x -c -D "cn=admin,dc=example,dc=com" -w admin > /dev/null 2>&1 < ldap/config.ldif || true

sleep 1

step "LDAP: Entry john.doe exists" bash -c 'docker compose exec -T ldap ldapsearch -x -D "cn=admin,dc=example,dc=com" -w admin -b "dc=example,dc=com" "(uid=john.doe)" | grep -qi "dn: uid=john.doe" && echo "User Found"'
step "LDAP: Group prosthetic_user exists" bash -c 'docker compose exec -T ldap ldapsearch -x -D "cn=admin,dc=example,dc=com" -w admin -b "dc=example,dc=com" "(cn=prosthetic_user)" | grep -qi "dn: cn=prosthetic_user" && echo "Group Found"'

step "Keycloak logs: configuration loaded" bash -c 'docker compose logs keycloak | grep -qiE "(ldap-provider|Import finished)" && echo "Config Loaded"'
step "Keycloak logs: Realm reports-realm ready" bash -c 'docker compose logs keycloak | grep -qiE "(imported|already exists)" && echo "Realm Ready"'

# 6. Real Authentication Test
segment "End-to-End Authentication Test"
step "Auth: Login with Keycloak user (user1)" bash -c 'curl -s -X POST "http://localhost:8080/realms/reports-realm/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=password" \
     -d "client_id=reports-frontend" \
     -d "client_secret=oNwoLQdvJAvRcL89SydqCWCe5ry1jMgq" \
     -d "username=user1" \
     -d "password=password123" | grep -q "access_token" && echo "Login Success"'

step "Auth: Login with LDAP user (john.doe)" bash -c 'curl -s -X POST "http://localhost:8080/realms/reports-realm/protocol/openid-connect/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=password" \
     -d "client_id=reports-frontend" \
     -d "client_secret=oNwoLQdvJAvRcL89SydqCWCe5ry1jMgq" \
     -d "username=john.doe" \
     -d "password=password" | grep -q "access_token" && echo "LDAP Login Success"'

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
    echo "BFF Session Validated"
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

step "BFF allows requests from Frontend Origin (CORS)" bash -c 'curl -s -I -H "Origin: http://localhost:3000" http://localhost:8000/auth/me | grep -qi "Access-Control-Allow-Origin: http://localhost:3000" && echo "CORS Allowed"'

step "BFF allows credentials (cookies) from Frontend" bash -c 'curl -s -I -H "Origin: http://localhost:3000" http://localhost:8000/auth/me | grep -qi "Access-Control-Allow-Credentials: true" && echo "Credentials Allowed"'
