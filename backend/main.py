import os
import secrets
import hashlib
import base64
import logging
import uuid
from typing import Optional
from fastapi import FastAPI, Request, Response, HTTPException, Query
from fastapi.responses import RedirectResponse
from fastapi.middleware.cors import CORSMiddleware
import httpx
from itsdangerous import URLSafeSerializer

# Настройка логирования
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("bff")

app = FastAPI()

# Настройки из окружения
KC_URL = os.getenv("KC_URL", "http://keycloak:8080")
KC_FRONTEND_URL = os.getenv("KC_FRONTEND_URL", "http://localhost:8080")
REALM = os.getenv("KC_REALM", "reports-realm")
CLIENT_ID = os.getenv("KC_CLIENT_ID", "reports-frontend")
KC_CLIENT_SECRET = os.getenv("KC_CLIENT_SECRET", "your-client-secret-here")
KC_REDIRECT_URI = os.getenv("KC_REDIRECT_URI", "http://localhost:8000/auth/callback")
FRONTEND_URL = os.getenv("FRONTEND_URL", "http://localhost:3000")
SECRET_KEY = os.getenv("SESSION_SECRET", "super-secret-key")
# Флаг для Secure кук (True в продакшене)
SECURE_COOKIES = os.getenv("SECURE_COOKIES", "false").lower() == "true"

# ClickHouse settings
CH_HOST = os.getenv("CLICKHOUSE_HOST", "localhost")
CH_PORT = 8123
CH_USER = os.getenv("CLICKHOUSE_USER", "default")
CH_PASSWORD = os.getenv("CLICKHOUSE_PASSWORD", "clickhouse")

serializer = URLSafeSerializer(SECRET_KEY)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[FRONTEND_URL],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.middleware("http")
async def add_security_headers(request: Request, call_next):
    # Дополнительная защита от CSRF для BFF
    # Для всех запросов (или только мутирующих) проверяем Origin/Referer
    if request.method in ["POST", "PUT", "DELETE", "PATCH"]:
        origin = request.headers.get("Origin")
        if not origin or origin != FRONTEND_URL:
            # Если это запрос с другого домена (не через прокси и не с нашего фронта) - блокируем
            return Response(content="CSRF Protection: Invalid Origin", status_code=403)

    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return response

def generate_pkce():
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).decode().rstrip("=")
    return verifier, challenge

@app.get("/auth/login")
async def login():
    verifier, challenge = generate_pkce()
    state = secrets.token_urlsafe(32)
    
    auth_url = (
        f"{KC_FRONTEND_URL}/realms/{REALM}/protocol/openid-connect/auth"
        f"?response_type=code"
        f"&client_id={CLIENT_ID}"
        f"&redirect_uri={KC_REDIRECT_URI}" 
        f"&scope=openid profile email"
        f"&code_challenge={challenge}"
        f"&code_challenge_method=S256"
        f"&state={state}"
    )
    
    response = RedirectResponse(auth_url)
    # Сохраняем verifier и state в куку (временную)
    pkce_data = {"verifier": verifier, "state": state}
    response.set_cookie(
        "pkce_data", 
        serializer.dumps(pkce_data), 
        httponly=True, 
        secure=SECURE_COOKIES, 
        samesite="Strict",
        path="/"
    )
    return response

@app.get("/auth/callback")
async def callback(request: Request, code: str, state: str):
    pkce_cookie = request.cookies.get("pkce_data")
    if not pkce_cookie:
        raise HTTPException(status_code=400, detail="Missing PKCE data")
    
    try:
        pkce_data = serializer.loads(pkce_cookie)
    except Exception as e:
        logger.error(f"Failed to decode pkce_data cookie: {str(e)}")
        raise HTTPException(status_code=400, detail="Invalid PKCE data")

    if pkce_data.get("state") != state:
        logger.warning(f"State mismatch: expected {pkce_data.get('state')}, got {state}")
        raise HTTPException(status_code=400, detail="State mismatch")
    
    verifier = pkce_data.get("verifier")
    
    # Обмен кода на токен
    async with httpx.AsyncClient() as client:
        data = {
            "grant_type": "authorization_code",
            "client_id": CLIENT_ID,
            "client_secret": KC_CLIENT_SECRET,
            "code": code,
            "redirect_uri": KC_REDIRECT_URI,
            "code_verifier": verifier
        }
        resp = await client.post(
            f"{KC_URL}/realms/{REALM}/protocol/openid-connect/token",
            data=data
        )
        
    if resp.status_code != 200:
        logger.error(f"Token exchange failed: {resp.status_code} {resp.text}")
        # в продакшене наверное лучше сделать редирект на /error?type=auth_failed
        # вместо прямого возврата ошибки Keycloak пользователю.
        # предложить зарегистрироваться или ещё что-то такое.
        return Response(content=resp.text, status_code=resp.status_code)
    
    tokens = resp.json()
    logger.info("Token exchange successful")
    
    # Создаем финальную сессионную куку с токенами
    response = RedirectResponse(url=FRONTEND_URL)
    response.set_cookie(
        "session",
        serializer.dumps(tokens),
        httponly=True,
        secure=SECURE_COOKIES,
        samesite="Strict",
        path="/"
    )
    response.delete_cookie("pkce_data", path="/")
    return response

async def refresh_access_token(refresh_token: str):
    async with httpx.AsyncClient() as client:
        data = {
            "grant_type": "refresh_token",
            "client_id": CLIENT_ID,
            "client_secret": KC_CLIENT_SECRET,
            "refresh_token": refresh_token
        }
        resp = await client.post(
            f"{KC_URL}/realms/{REALM}/protocol/openid-connect/token",
            data=data
        )
        if resp.status_code == 200:
            return resp.json()
    return None

@app.get("/auth/me")
async def me(request: Request, response: Response):
    session = request.cookies.get("session")
    if not session:
        return {"authenticated": False}
    
    try:
        tokens = serializer.loads(session)
        
        async with httpx.AsyncClient() as client:
            headers = {"Authorization": f"Bearer {tokens['access_token']}"}
            resp = await client.get(
                f"{KC_URL}/realms/{REALM}/protocol/openid-connect/userinfo",
                headers=headers
            )
            
            # Если токен истек, пробуем обновить
            if resp.status_code == 401 and "refresh_token" in tokens:
                logger.info("Access token expired, attempting refresh")
                new_tokens = await refresh_access_token(tokens["refresh_token"])
                if new_tokens:
                    logger.info("Token refresh successful")
                    # Обновляем куку сессии
                    response.set_cookie(
                        "session",
                        serializer.dumps(new_tokens),
                        httponly=True,
                        secure=SECURE_COOKIES,
                        samesite="Strict",
                        path="/"
                    )
                    # Повторяем запрос UserInfo с новым токеном
                    headers = {"Authorization": f"Bearer {new_tokens['access_token']}"}
                    resp = await client.get(
                        f"{KC_URL}/realms/{REALM}/protocol/openid-connect/userinfo",
                        headers=headers
                    )
                else:
                    logger.warning("Token refresh failed")

        if resp.status_code == 200:
            user_data = resp.json()
            # Фильтруем данные (Claims Validation/Sanitization) перед отправкой на фронтенд.
            # В реальном проекте здесь стоит оставить только необходимые поля (id, name, roles).
            filtered_user = {
                "sub": user_data.get("sub"),
                "preferred_username": user_data.get("preferred_username"),
                "email": user_data.get("email"),
                "given_name": user_data.get("given_name"),
                "family_name": user_data.get("family_name"),
            }
            return {"authenticated": True, "user": filtered_user}
        else:
            logger.warning(f"UserInfo failed: {resp.status_code} {resp.text}")
    except Exception as e:
        # В будущем здесь стоит реализовать редирект на дружелюбную страницу ошибки (Error Page)
        # вместо возврата технического статуса, чтобы не пугать пользователя.
        logger.error(f"Auth check failed: {str(e)}")
    
    return {"authenticated": False}

@app.get("/auth/logout")
async def logout(request: Request):
    session = request.cookies.get("session")
    logout_url = FRONTEND_URL
    
    if session:
        try:
            tokens = serializer.loads(session)
            id_token = tokens.get("id_token")
            if id_token:
                # RP-Initiated Logout: уведомляем Keycloak о завершении сессии
                logout_url = (
                    f"{KC_FRONTEND_URL}/realms/{REALM}/protocol/openid-connect/logout"
                    f"?id_token_hint={id_token}"
                    f"&post_logout_redirect_uri={FRONTEND_URL}"
                )
                logger.info("Initiating RP-Logout from Keycloak")
        except Exception as e:
            logger.error(f"Logout processing error: {str(e)}")

    response = RedirectResponse(url=logout_url)
    response.delete_cookie("session", path="/")
    return response

@app.get("/reports")
async def get_reports(
    request: Request,
    from_date: Optional[str] = Query(None, pattern=r"^\d{4}-\d{2}-\d{2}$"),
    to_date: Optional[str] = Query(None, pattern=r"^\d{4}-\d{2}-\d{2}$")
):
    session = request.cookies.get("session")
    if not session:
        raise HTTPException(status_code=401, detail="Unauthorized")
    
    try:
        tokens = serializer.loads(session)
        
        # Получаем данные пользователя из Keycloak для проверки ID
        async with httpx.AsyncClient() as client:
            headers = {"Authorization": f"Bearer {tokens['access_token']}"}
            resp = await client.get(
                f"{KC_URL}/realms/{REALM}/protocol/openid-connect/userinfo",
                headers=headers
            )
            
            if resp.status_code != 200:
                logger.error(f"UserInfo failed during reports request: {resp.status_code}")
                raise HTTPException(status_code=401, detail="Invalid session")
            
            user_data = resp.json()
            user_id_raw = user_data.get("sub")
            
            # Валидация user_id как UUID для защиты от SQL-инъекций
            try:
                user_id = str(uuid.UUID(user_id_raw))
            except (ValueError, TypeError):
                logger.error(f"Invalid user_id format received: {user_id_raw}")
                raise HTTPException(status_code=403, detail="Invalid user identification")

            # Формирование безопасного запроса к ClickHouse
            query = f"SELECT * FROM user_report_showcase WHERE user_id = '{user_id}'"
            
            if from_date:
                query += f" AND report_date >= '{from_date}'"
            if to_date:
                query += f" AND report_date <= '{to_date}'"
                
            query += " ORDER BY report_date DESC FORMAT JSON"
            
            ch_resp = await client.post(
                f"http://{CH_HOST}:{CH_PORT}/",
                content=query,
                auth=(CH_USER, CH_PASSWORD)
            )
            
            if ch_resp.status_code != 200:
                logger.error(f"ClickHouse query failed: {ch_resp.text}")
                return {"status": "error", "message": "Failed to fetch reports from OLAP"}
            
            return ch_resp.json()
            
    except Exception as e:
        logger.error(f"Error fetching reports: {str(e)}")
        raise HTTPException(status_code=500, detail="Internal Server Error")

