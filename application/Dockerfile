# --- Build stage ---
FROM python:3.12-slim AS builder

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


# --- Runtime stage ---
FROM python:3.12-slim

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /install /usr/local

# Copy application code
COPY main.py .

# Non-root user for security
RUN useradd --no-create-home --shell /bin/false appuser
USER appuser

EXPOSE 8000

ENV TARGET_HOST=10.0.2.133 \
    TCP_PORT=22 \
    MEASURE_INTERVAL=30

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
