import os
import json
from dotenv import load_dotenv
import boto3
from botocore.exceptions import ClientError

load_dotenv()

def get_secret(secret_name):
    region = os.environ.get("AWS_REGION", "us-east-1")
    client = boto3.client("secretsmanager", region_name=region)
    try:
        response = client.get_secret_value(SecretId=secret_name)
        return json.loads(response["SecretString"])
    except (ClientError, Exception):
        return None

class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY", "dev-secret-change-in-prod")
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    WTF_CSRF_ENABLED = True
    VERIFY_SERVICE_URL = os.environ.get("VERIFY_SERVICE_URL", "http://localhost:8000")
    CLAIMS_SERVICE_URL = os.environ.get("CLAIMS_SERVICE_URL", "http://localhost:8001")

    _secret_name = os.environ.get("DB_SECRET_NAME")
    _secrets = get_secret(_secret_name) if _secret_name else None

    if _secrets:
        DB_HOST     = _secrets.get("host", "localhost")
        DB_PORT     = _secrets.get("port", 5432)
        DB_NAME     = _secrets.get("dbname", "lottery")
        DB_USER     = _secrets.get("username", "postgres")
        DB_PASSWORD = _secrets.get("password", "postgres")
    else:
        DB_HOST     = os.environ.get("DB_HOST", "localhost")
        DB_PORT     = os.environ.get("DB_PORT", 5432)
        DB_NAME     = os.environ.get("DB_NAME", "lottery")
        DB_USER     = os.environ.get("DB_USER", "postgres")
        DB_PASSWORD = os.environ.get("DB_PASSWORD", "postgres")

    SQLALCHEMY_DATABASE_URI = (
        f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
    )