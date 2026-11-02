FROM python:3.12-slim
WORKDIR /app
COPY requirements.lock .
RUN pip install --no-cache-dir -r requirements.lock
COPY app.py .
USER 10001:10001
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8448", "--ssl-keyfile", "/tls/key.pem", "--ssl-certfile", "/tls/cert.pem", "--no-access-log"]
