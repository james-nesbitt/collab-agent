FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY session_operator.py .

# Run as non-root
RUN useradd -u 1000 -m operator
USER operator

ENTRYPOINT ["python", "-u", "session_operator.py"]
